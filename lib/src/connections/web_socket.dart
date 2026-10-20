import 'dart:async';
import 'dart:convert';

import 'cancellation.dart';
import 'connection_adapter.dart';
import 'errors.dart';
import 'fetch_connections.dart';
import 'hydration.dart';
import 'reconnect.dart';
import 'resumable_stream.dart';
import 'types.dart';
import 'web_socket_connection.dart';
import 'wire.dart';

/// Options for [webSocket].
class WebSocketConnectionOptions {
  final List<String>? protocols;
  final Map<String, dynamic>? body;
  final ReconnectOptions? reconnect;

  /// Injectable socket factory. Required: this package does not assume
  /// `dart:io`, `dart:html`, or a browser global is available.
  final WebSocketFactory? socketFactory;

  const WebSocketConnectionOptions({
    this.protocols,
    this.body,
    this.reconnect,
    this.socketFactory,
  });
}

class _ChunkSink {
  final void Function(StreamChunk chunk) push;
  final void Function(Object error) fail;

  const _ChunkSink(this.push, this.fail);
}

class _RunSession {
  String? runId;
  final ReconnectTracker tracker;
  bool sawTerminal = false;
  bool progressed = false;
  CancellationSignal? signal;

  _RunSession(this.tracker, this.signal);
}

class _ChunkPipe {
  final List<StreamChunk> _queue = <StreamChunk>[];
  final List<Completer<StreamChunk?>> _waiters = <Completer<StreamChunk?>>[];
  Object? _failure;
  bool _ended = false;

  _ChunkPipe(CancellationSignal? signal, void Function() onFinally) {
    void wake() {
      if (_waiters.isNotEmpty) _waiters.removeAt(0).complete(null);
    }

    signal?.addListener(wake);
    final iterable = (() async* {
      try {
        while (!(signal?.isCancelled ?? false)) {
          if (_queue.isNotEmpty) {
            yield _queue.removeAt(0);
            continue;
          }
          if (_failure != null) throw _failure!;
          if (_ended) return;
          final waiter = Completer<StreamChunk?>();
          _waiters.add(waiter);
          final chunk = await waiter.future;
          if (_failure != null) throw _failure!;
          if (chunk == null) return;
          yield chunk;
        }
      } finally {
        signal?.removeListener(wake);
        onFinally();
      }
    })();
    stream = iterable;
  }

  late final Stream<StreamChunk> stream;

  void push(StreamChunk chunk) {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete(chunk);
    } else {
      _queue.add(chunk);
    }
  }

  void fail(Object error) {
    _failure = error;
    if (_waiters.isNotEmpty) _waiters.removeAt(0).complete(null);
  }

  void end() {
    _ended = true;
    if (_waiters.isNotEmpty) _waiters.removeAt(0).complete(null);
  }
}

/// Full-duplex, conversation-scoped WebSocket connection adapter.
///
/// `send()` writes a RunAgentInput frame; `subscribe()` yields inbound chunks.
/// A durable (`{ id, chunk }`-tagged) run reopens at
/// `?runId=&offset=<lastEventId>` after a drop, de-duping the replay boundary.
/// A non-durable drop surfaces [StreamReadError] instead of reconnecting.
ConnectionAdapter webSocket(
  Object url, [
  WebSocketConnectionOptions options = const WebSocketConnectionOptions(),
]) {
  WebSocketConnection? socket;
  String? socketMode;
  Future<void>? openPromise;
  final listeners = <_ChunkSink>{};
  _RunSession? currentSession;

  late final void Function(WebSocketConnection ws, String frame) onFrame;
  late final void Function(WebSocketConnection ws, SocketCloseInfo info)
      onClose;
  late final Future<void> Function(_RunSession session, String offset)
      reconnect;

  void failAll(Object error) {
    for (final listener in listeners) {
      listener.fail(error);
    }
  }

  WebSocketConnection openOnce(String target, String mode) {
    final existing = socket;
    if (existing != null &&
        existing.readyState <= 1 &&
        mode == 'run' &&
        socketMode == 'run') {
      return existing;
    }
    final factory = options.socketFactory;
    if (factory == null) {
      throw StateError(
        'webSocket() requires WebSocketConnectionOptions.socketFactory',
      );
    }
    final prior = existing;
    final ws = options.protocols == null
        ? factory(Uri.parse(target))
        : factory(Uri.parse(target), protocols: options.protocols);
    socket = ws;
    socketMode = mode;
    openPromise = ws.opened;
    unawaited(
      openPromise!.then<void>(
        (_) {},
        onError: (Object error, StackTrace _) {
          if (ws == socket) failAll(StreamReadError(error));
        },
      ),
    );
    ws.messages.listen(
      (frame) => onFrame(ws, frame),
      onError: (Object error, StackTrace _) {
        if (ws == socket) failAll(StreamReadError(error));
      },
    );
    unawaited(
      ws.closed.then<void>(
        (info) => onClose(ws, info),
        onError: (Object error, StackTrace _) {
          onClose(ws, SocketCloseInfo(1006, '$error'));
        },
      ),
    );
    if (prior != null && prior.readyState <= 1) prior.close();
    return ws;
  }

  onFrame = (WebSocketConnection ws, String frame) {
    if (ws != socket) return;
    Object? parsed;
    try {
      parsed = jsonDecode(frame);
    } catch (error) {
      failAll(StreamReadError(error));
      return;
    }
    if (parsed is Map && parsed['type'] == 'ping') return;
    final envelope = isNdjsonEnvelope(parsed);
    final rawChunk = envelope ? (parsed as Map)['chunk'] : parsed;
    if (rawChunk is! Map) {
      failAll(StreamReadError(FormatException('Invalid WebSocket frame')));
      return;
    }
    final chunk = restoreInboundChunk(
      rawChunk.map((key, value) => MapEntry('$key', value)),
    );
    final envelopeId = envelope ? (parsed as Map)['id'] as String : null;

    final session = currentSession;
    if (session != null) {
      if (session.tracker.note(envelopeId) == ReconnectNote.duplicate) return;
      session.progressed = true;
      if (session.runId == null && chunk['runId'] is String) {
        session.runId = chunk['runId'] as String;
      }
      final type = chunk['type'];
      if (type == 'RUN_FINISHED' || type == 'RUN_ERROR') {
        session.sawTerminal = true;
      }
    }
    for (final listener in listeners) {
      listener.push(chunk);
    }
  };

  onClose = (WebSocketConnection ws, SocketCloseInfo info) {
    if (ws != socket) return;
    final session = currentSession;
    if (session == null) {
      failAll(
        StreamReadError(
          StateError('WebSocket connection closed (${info.code})'),
        ),
      );
      return;
    }
    if ((session.signal?.isCancelled ?? false) || session.sawTerminal) return;
    final lastEventId = session.tracker.lastEventId;
    if (lastEventId == null) {
      currentSession = null;
      failAll(StreamReadError(StateError('WebSocket connection closed')));
      return;
    }
    unawaited(reconnect(session, lastEventId));
  };

  reconnect = (_RunSession session, String offset) async {
    try {
      await session.tracker.waitBeforeReconnect(
        session.progressed,
        session.signal,
      );
    } catch (error) {
      if (identical(currentSession, session)) currentSession = null;
      failAll(error);
      return;
    }
    if (session.signal?.isCancelled ?? false) return;
    if (!identical(currentSession, session)) return;
    final live = socket;
    if (live != null && live.readyState <= 1) return;
    session.progressed = false;
    final base = await resolveConnectionUrl(url);
    final target = withSearchParams(base, {
      if (session.runId != null) 'runId': session.runId!,
      'offset': offset,
    });
    try {
      openOnce(target, 'resume');
    } catch (error) {
      failAll(error);
    }
  };

  Future<void> waitOpen(WebSocketConnection ws) {
    if (ws.readyState == 1) return Future<void>.value();
    return openPromise ?? Future<void>.value();
  }

  Stream<StreamChunk> joinRunStream(
    String runId,
    CancellationSignal? signal,
  ) async* {
    final base = await resolveConnectionUrl(url);
    final target = withSearchParams(base, {'offset': '-1', 'runId': runId});
    final factory = options.socketFactory;
    if (factory == null) {
      throw StateError(
        'webSocket() requires WebSocketConnectionOptions.socketFactory',
      );
    }
    final ws = options.protocols == null
        ? factory(Uri.parse(target))
        : factory(Uri.parse(target), protocols: options.protocols);
    final pipe = _ChunkPipe(signal, () {
      if (ws.readyState <= 1) ws.close();
    });
    ws.messages.listen(
      (frame) {
        Object? parsed;
        try {
          parsed = jsonDecode(frame);
        } catch (error) {
          pipe.fail(StreamReadError(error));
          return;
        }
        if (parsed is Map && parsed['type'] == 'ping') return;
        final envelope = isNdjsonEnvelope(parsed);
        final rawChunk = envelope ? (parsed as Map)['chunk'] : parsed;
        if (rawChunk is! Map) {
          pipe.fail(StreamReadError(FormatException('Invalid frame')));
          return;
        }
        pipe.push(
          restoreInboundChunk(
            rawChunk.map((key, value) => MapEntry('$key', value)),
          ),
        );
      },
      onError: (Object error, StackTrace _) {
        pipe.fail(StreamReadError(error));
      },
    );
    unawaited(
      ws.closed.then<void>(
        (info) {
          if (info.code == 1000) {
            pipe.end();
          } else {
            pipe.fail(
              StreamReadError(
                StateError('WebSocket connection closed ($info)'),
              ),
            );
          }
        },
        onError: (Object error, StackTrace _) {
          pipe.fail(StreamReadError(error));
        },
      ),
    );
    yield* pipe.stream;
  }

  return ConnectionAdapter(
    subscribe: ({signal}) {
      late final _ChunkSink sink;
      final pipe = _ChunkPipe(signal, () => listeners.remove(sink));
      sink = _ChunkSink(pipe.push, pipe.fail);
      listeners.add(sink);
      return pipe.stream;
    },
    send: (messages, {data, signal, runContext}) async {
      final base = await resolveConnectionUrl(url);
      final target = runContext?.runId == null
          ? base
          : withSearchParams(base, {'runId': runContext!.runId});
      final ws = openOnce(target, 'run');
      await waitOpen(ws);

      final session = currentSession;
      if (session == null || session.runId != runContext?.runId) {
        currentSession = _RunSession(
          ReconnectTracker(options.reconnect),
          signal,
        )..runId = runContext?.runId;
      } else {
        session.signal = signal;
        session.sawTerminal = false;
        session.progressed = false;
      }
      final activeSession = currentSession!;

      signal?.addListener(() {
        final abortRunId = activeSession.runId;
        final live = socket;
        if (abortRunId == null ||
            activeSession.sawTerminal ||
            socketMode != 'run' ||
            live == null ||
            live.readyState != 1) {
          return;
        }
        try {
          live.send(
            jsonEncode({'type': 'abort', 'runId': abortRunId}),
          );
        } catch (_) {
          // Socket is closing; the server aborts the turn on close.
        }
      });

      ws.send(
        jsonEncode(
          buildRunAgentInputBody(
            messages,
            data,
            runContext,
            body: options.body,
          ),
        ),
      );
    },
    joinRun: (runId, {signal}) {
      final controller = StreamController<StreamChunk>();
      final subscription = joinRunStream(runId, signal).listen(
        controller.add,
        onError: controller.addError,
        onDone: controller.close,
      );
      controller.onCancel = subscription.cancel;
      return controller.stream;
    },
  );
}
