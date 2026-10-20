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

/// Either a [ConnectFunction] adapter or a subscribe/send adapter.
///
/// Keeping both modes on one class mirrors the upstream structural union and
/// lets [normalizeConnectionAdapter] reject partial or mixed configurations.
class ConnectionAdapter {
  final ConnectFunction? connect;
  final SubscribeFunction? subscribe;
  final SendFunction? send;
  final JoinRunFunction? joinRun;
  final HydrateFunction? hydrate;
  final HydrateGenerationFunction? hydrateGeneration;

  const ConnectionAdapter({
    this.connect,
    this.subscribe,
    this.send,
    this.joinRun,
    this.hydrate,
    this.hydrateGeneration,
  });
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

  final hasConnect = connection.connect != null;
  final hasSubscribe = connection.subscribe != null;
  final hasSend = connection.send != null;

  if (hasConnect && (hasSubscribe || hasSend)) {
    throw ArgumentError(
      'Connection adapter must provide either connect or both subscribe and '
      'send, not both modes',
    );
  }

  if (hasSubscribe && hasSend) {
    return SubscribeConnectionAdapter(
      subscribe: connection.subscribe!,
      send: connection.send!,
      joinRun: connection.joinRun,
      hydrate: connection.hydrate,
    );
  }

  if (!hasConnect) {
    throw ArgumentError(
      'Connection adapter must provide either connect or both subscribe and '
      'send',
    );
  }

  final queue = _ConnectQueue();

  Future<void> send(
    List<WireMessage> messages, {
    Map<String, dynamic>? data,
    CancellationSignal? signal,
    RunAgentInputContext? runContext,
  }) async {
    var hasTerminalEvent = false;
    String? upstreamThreadId;
    String? upstreamRunId;
    try {
      final stream = connection.connect!(
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
    send: send,
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
