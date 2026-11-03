import 'dart:async';

import 'cancellation.dart';
import 'hydration.dart';
import 'types.dart';
import 'wire.dart';

/// Open a stream of chunks from serialized messages.
typedef ConnectFunction = Stream<StreamChunk> Function(
  List<WireMessage> messages, {
  Map<String, dynamic>? data,
  CancellationSignal? signal,
  RunAgentInputContext? runContext,
});

/// Subscribe to chunks pushed by [SendFunction].
typedef SubscribeFunction = Stream<StreamChunk> Function({
  CancellationSignal? signal,
});

/// Send a request; chunks arrive through [SubscribeFunction].
typedef SendFunction = Future<void> Function(
  List<WireMessage> messages, {
  Map<String, dynamic>? data,
  CancellationSignal? signal,
  RunAgentInputContext? runContext,
});

/// Re-attach to an existing run and replay it from the start.
typedef JoinRunFunction = Stream<StreamChunk> Function(
  String runId, {
  CancellationSignal? signal,
});

/// Fetch server-authoritative chat hydration for a thread.
typedef HydrateFunction = Future<ChatHydrationResult> Function(
  String threadId, {
  ChatHydrateOptions? options,
});

/// Fetch server-authoritative generation hydration for a thread.
typedef HydrateGenerationFunction = Future<GenerationHydrationResult> Function(
  String threadId,
);

/// A connection adapter in exactly one of two modes.
///
/// Construct with [ConnectionAdapter.connect] for a request-scoped adapter,
/// or [ConnectionAdapter.subscription] for a push adapter. There is no public
/// constructor that can represent a partial or mixed configuration.
///
/// The nullable getters expose the selected mode to clients that consume
/// adapters. New callers should prefer the named constructors and the
/// non-nullable functions on [SubscribeConnectionAdapter].
class ConnectionAdapter {
  final ConnectFunction? _connect;
  final SubscribeFunction? _subscribe;
  final SendFunction? _send;
  final JoinRunFunction? _joinRun;
  final HydrateFunction? _hydrate;
  final HydrateGenerationFunction? _hydrateGeneration;

  const ConnectionAdapter.connect({
    required ConnectFunction connect,
    JoinRunFunction? joinRun,
    HydrateFunction? hydrate,
    HydrateGenerationFunction? hydrateGeneration,
  })  : _connect = connect,
        _subscribe = null,
        _send = null,
        _joinRun = joinRun,
        _hydrate = hydrate,
        _hydrateGeneration = hydrateGeneration;

  const ConnectionAdapter.subscription({
    required SubscribeFunction subscribe,
    required SendFunction send,
    JoinRunFunction? joinRun,
    HydrateFunction? hydrate,
    HydrateGenerationFunction? hydrateGeneration,
  })  : _connect = null,
        _subscribe = subscribe,
        _send = send,
        _joinRun = joinRun,
        _hydrate = hydrate,
        _hydrateGeneration = hydrateGeneration;

  ConnectFunction? get connect => _connect;

  SubscribeFunction? get subscribe => _subscribe;

  SendFunction? get send => _send;

  JoinRunFunction? get joinRun => _joinRun;

  HydrateFunction? get hydrate => _hydrate;

  HydrateGenerationFunction? get hydrateGeneration => _hydrateGeneration;
}

/// Normalized subscribe/send view of a [ConnectionAdapter].
class SubscribeConnectionAdapter {
  final SubscribeFunction subscribe;
  final SendFunction send;
  final JoinRunFunction? joinRun;
  final HydrateFunction? hydrate;

  const SubscribeConnectionAdapter({
    required this.subscribe,
    required this.send,
    this.joinRun,
    this.hydrate,
  });
}

/// Normalize a [ConnectionAdapter] to subscribe/send operations.
///
/// If the connection provides native subscribe/send, that mode is used.
/// Otherwise `connect()` is wrapped with an async queue.
SubscribeConnectionAdapter normalizeConnectionAdapter(
  ConnectionAdapter? connection,
) {
  if (connection == null) {
    throw ArgumentError('Connection adapter is required');
  }

  final subscribe = connection.subscribe;
  final send = connection.send;
  if (subscribe != null && send != null) {
    return SubscribeConnectionAdapter(
      subscribe: subscribe,
      send: send,
      joinRun: connection.joinRun,
      hydrate: connection.hydrate,
    );
  }

  final connect = connection.connect;
  if (connect == null) {
    throw ArgumentError(
      'Connection adapter must provide either connect or both subscribe and '
      'send',
    );
  }

  final queue = _ConnectQueue();

  Future<void> sendWithConnect(
    List<WireMessage> messages, {
    Map<String, dynamic>? data,
    CancellationSignal? signal,
    RunAgentInputContext? runContext,
  }) async {
    var hasTerminalEvent = false;
    String? upstreamThreadId;
    String? upstreamRunId;
    try {
      final stream = connect(
        messages,
        data: data,
        signal: signal,
        runContext: runContext,
      );
      await for (final chunk in stream) {
        if (chunk['threadId'] is String) {
          upstreamThreadId = chunk['threadId'] as String;
        }
        if (chunk['runId'] is String) {
          upstreamRunId = chunk['runId'] as String;
        }
        final type = chunk['type'];
        if (type == 'RUN_FINISHED' || type == 'RUN_ERROR') {
          hasTerminalEvent = true;
        }
        queue.push(chunk);
      }

      if (!(signal?.isCancelled ?? false) && !hasTerminalEvent) {
        queue.push(
          withTanstackMetadata(
            {
              'type': 'RUN_FINISHED',
              'threadId': _requireSyntheticId(
                upstreamThreadId ?? runContext?.threadId,
                'threadId',
              ),
              'runId': _requireSyntheticId(
                upstreamRunId ?? runContext?.runId,
                'runId',
              ),
              'timestamp': DateTime.now().millisecondsSinceEpoch,
            },
            {'finishReason': 'stop', 'model': 'connect-wrapper'},
          ),
        );
      }
    } catch (error) {
      if (!(signal?.isCancelled ?? false) && !hasTerminalEvent) {
        try {
          final message = error is Error ? error.toString() : '$error';
          queue.push({
            'type': 'RUN_ERROR',
            'threadId': _requireSyntheticId(
              upstreamThreadId ?? runContext?.threadId,
              'threadId',
            ),
            'runId': _requireSyntheticId(
              upstreamRunId ?? runContext?.runId,
              'runId',
            ),
            'timestamp': DateTime.now().millisecondsSinceEpoch,
            'message': message,
          });
        } catch (_) {
          // Preserve the original failure when ids are missing.
        }
      }
      rethrow;
    }
    await queue.waitUntilIdle(signal);
  }

  return SubscribeConnectionAdapter(
    subscribe: ({CancellationSignal? signal}) =>
        queue.subscribe(signal: signal),
    send: sendWithConnect,
    joinRun: connection.joinRun,
    hydrate: connection.hydrate,
  );
}

String _requireSyntheticId(String? value, String field) {
  if (value == null || value.isEmpty) {
    throw StateError(
      'Cannot synthesize terminal event: $field not supplied via runContext '
      'and not observed in the upstream stream.',
    );
  }
  return value;
}

class _ConnectQueue {
  final List<StreamChunk> _buffer = <StreamChunk>[];
  final List<Completer<StreamChunk?>> _waiters = <Completer<StreamChunk?>>[];
  bool _hasSubscriber = false;
  Completer<void>? _idle;

  void push(StreamChunk chunk) {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete(chunk);
    } else {
      _buffer.add(chunk);
    }
  }

  Stream<StreamChunk> subscribe({CancellationSignal? signal}) async* {
    _hasSubscriber = true;
    try {
      while (!(signal?.isCancelled ?? false)) {
        if (_buffer.isNotEmpty) {
          yield _buffer.removeAt(0);
          continue;
        }
        final waiter = Completer<StreamChunk?>();
        _waiters.add(waiter);
        _signalIdle();
        void onCancel() {
          if (!waiter.isCompleted) waiter.complete(null);
        }

        signal?.addListener(onCancel);
        final chunk = await waiter.future;
        signal?.removeListener(onCancel);
        if (chunk == null) break;
        yield chunk;
      }
    } finally {
      _hasSubscriber = false;
      _signalIdle();
    }
  }

  Future<void> waitUntilIdle(CancellationSignal? signal) async {
    while (true) {
      if (signal?.isCancelled ?? false) return;
      if (!_hasSubscriber) return;
      if (_buffer.isEmpty && _waiters.isNotEmpty) return;
      final idle = _idle ??= Completer<void>();
      if (signal == null) {
        await idle.future;
      } else {
        await Future.any<void>([idle.future, signal.whenCancelled]);
      }
    }
  }

  void _signalIdle() {
    final idle = _idle;
    _idle = null;
    if (idle != null && !idle.isCompleted) idle.complete();
  }
}
