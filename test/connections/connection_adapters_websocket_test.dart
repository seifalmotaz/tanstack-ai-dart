// Ported from packages/ai-client/tests/connection-adapters-websocket.test.ts
// Test names and groups intentionally mirror the upstream file.
import 'dart:async';
import 'dart:convert';

import 'package:tanstack_ai_dart/connections.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

Future<void> drain(
  Stream<StreamChunk> stream,
  List<StreamChunk> sink,
  CancellationSignal signal,
) async {
  await for (final chunk in stream) {
    if (signal.isCancelled) break;
    sink.add(chunk);
  }
}

Future<List<StreamChunk>> drainToEnd(
  StreamIterator<StreamChunk> iterator,
) async {
  final received = <StreamChunk>[];
  for (;;) {
    final hasNext = await iterator.moveNext();
    if (!hasNext) return received;
    received.add(iterator.current);
  }
}

Future<T> withTimeout<T>(Future<T> future, String message) {
  return future.timeout(
    const Duration(seconds: 1),
    onTimeout: () => throw StateError(message),
  );
}

Future<({List<StreamChunk>? received, Object? error})> captureSocketFailure(
  StreamIterator<StreamChunk> iterator,
  String message,
) async {
  try {
    return (
      received: await withTimeout(drainToEnd(iterator), message),
      error: null
    );
  } catch (error) {
    return (received: null, error: error);
  }
}

void main() {
  group('webSocket() subscribe/send', () {
    test('sends a RunAgentInput frame and yields inbound chunks', () async {
      FakeWebSocket.instances.clear();
      final conn = webSocket(
        'wss://x/api/chat',
        const WebSocketConnectionOptions(socketFactory: fakeSocketFactory),
      );
      final controller = CancellationController();
      final received = <StreamChunk>[];
      final subscription = drain(
        conn.subscribe!(signal: controller.signal),
        received,
        controller.signal,
      );
      await conn.send!(
        [
          {'role': 'user', 'content': 'hi'},
        ],
        signal: controller.signal,
        runContext: const RunAgentInputContext(threadId: 't', runId: 'r'),
      );
      final ws = FakeWebSocket.instances.single;
      await tick();
      expect(ws.sent, hasLength(1));
      expect(jsonDecodeMap(ws.sent.single)['runId'], 'r');

      ws.emit({'type': 'TEXT_MESSAGE_CONTENT', 'delta': 'a'}, id: 'off-1');
      ws.emit({'type': 'ping'});
      await tick();
      controller.cancel();
      await subscription;
      expect(received.map((chunk) => chunk['type']), ['TEXT_MESSAGE_CONTENT']);
    });

    test('delivers a bare chunk (no id envelope) as-is to subscribe()',
        () async {
      FakeWebSocket.instances.clear();
      final conn = webSocket(
        'wss://x/api/chat',
        const WebSocketConnectionOptions(socketFactory: fakeSocketFactory),
      );
      final controller = CancellationController();
      final received = <StreamChunk>[];
      final subscription = drain(
        conn.subscribe!(signal: controller.signal),
        received,
        controller.signal,
      );
      await conn.send!(
        [
          {'role': 'user', 'content': 'hi'},
        ],
        signal: controller.signal,
        runContext: const RunAgentInputContext(threadId: 't', runId: 'r'),
      );
      final ws = FakeWebSocket.instances.single;
      await tick();

      ws.emit({'type': 'TEXT_MESSAGE_CONTENT', 'delta': 'x'});
      await tick();
      controller.cancel();
      await subscription;
      expect(received.map((chunk) => chunk['type']), ['TEXT_MESSAGE_CONTENT']);
      expect(received.single['delta'], 'x');
    });

    test(
        'joinRun opens a socket with offset=-1 and runId, and yields emitted '
        'chunks', () async {
      FakeWebSocket.instances.clear();
      final conn = webSocket(
        'wss://x/api/chat',
        const WebSocketConnectionOptions(socketFactory: fakeSocketFactory),
      );
      final controller = CancellationController();
      final received = <StreamChunk>[];
      final subscription = drain(
        conn.joinRun!('run-j', signal: controller.signal),
        received,
        controller.signal,
      );
      await tick();

      final ws = FakeWebSocket.instances.single;
      expect(ws.url.queryParameters['offset'], '-1');
      expect(ws.url.queryParameters['runId'], 'run-j');

      ws.emit({'type': 'TEXT_MESSAGE_CONTENT', 'delta': 'joined'}, id: 'off-1');
      await tick();
      controller.cancel();
      await subscription;
      expect(received.map((chunk) => chunk['type']), ['TEXT_MESSAGE_CONTENT']);
      expect(received.single['delta'], 'joined');
    });

    test(
        'does not hang when two send()s race the handshake (waitOpen '
        'memoization)', () async {
      FakeWebSocket.instances.clear();
      final conn = webSocket(
        'wss://x/api/chat',
        const WebSocketConnectionOptions(socketFactory: fakeSocketFactory),
      );
      final controller = CancellationController();

      final send1 = conn.send!(
        [
          {'role': 'user', 'content': 'first'},
        ],
        signal: controller.signal,
        runContext: const RunAgentInputContext(threadId: 't1', runId: 'r1'),
      );
      final send2 = conn.send!(
        [
          {'role': 'user', 'content': 'second'},
        ],
        signal: controller.signal,
        runContext: const RunAgentInputContext(threadId: 't2', runId: 'r2'),
      );

      await withTimeout(
        Future.wait([send1, send2]),
        'send() calls hung',
      );

      expect(FakeWebSocket.instances, hasLength(1));
      final ws = FakeWebSocket.instances.single;
      expect(ws.sent, hasLength(2));
      expect(jsonDecodeMap(ws.sent[0])['runId'], 'r1');
      expect(jsonDecodeMap(ws.sent[1])['runId'], 'r2');
    });
  });

  group('webSocket() reconnect', () {
    test('reopens with ?runId&offset after a drop and de-dupes the overlap',
        () async {
      FakeWebSocket.instances.clear();
      final conn = webSocket(
        'wss://x/api/chat',
        const WebSocketConnectionOptions(
          socketFactory: fakeSocketFactory,
          reconnect: ReconnectOptions(delay: Duration.zero, maxAttempts: 5),
        ),
      );
      final controller = CancellationController();
      final received = <StreamChunk>[];
      final subscription = drain(
        conn.subscribe!(signal: controller.signal),
        received,
        controller.signal,
      );
      await conn.send!(
        [
          {'role': 'user', 'content': 'hi'},
        ],
        signal: controller.signal,
        runContext: const RunAgentInputContext(threadId: 't', runId: 'run-x'),
      );
      final ws1 = FakeWebSocket.instances[0];
      await tick();
      ws1.emit(
        {'type': 'TEXT_MESSAGE_CONTENT', 'delta': 'a'},
        id: 'off-1',
      );
      await tick();
      ws1.close();

      await Future<void>.delayed(const Duration(milliseconds: 5));
      final ws2 = FakeWebSocket.instances[1];
      expect(ws2.url.queryParameters['runId'], 'run-x');
      expect(ws2.url.queryParameters['offset'], 'off-1');

      ws2.emit(
        {'type': 'TEXT_MESSAGE_CONTENT', 'delta': 'a'},
        id: 'off-1',
      );
      ws2.emit(
        {'type': 'TEXT_MESSAGE_CONTENT', 'delta': 'b'},
        id: 'off-2',
      );
      ws2.emit(finishedChunk(threadId: 't', runId: 'run-x'), id: 'off-3');
      await tick();
      controller.cancel();
      await subscription;
      expect(
        received.map((chunk) => chunk['delta'] ?? chunk['type']),
        ['a', 'b', 'RUN_FINISHED'],
      );
    });

    test(
        'a second send() with a new runId resets the run session (fresh '
        'offsets, reconnect re-armed)', () async {
      FakeWebSocket.instances.clear();
      final conn = webSocket(
        'wss://x/api/chat',
        const WebSocketConnectionOptions(
          socketFactory: fakeSocketFactory,
          reconnect: ReconnectOptions(delay: Duration.zero, maxAttempts: 5),
        ),
      );
      final controller = CancellationController();
      final received = <StreamChunk>[];
      final subscription = drain(
        conn.subscribe!(signal: controller.signal),
        received,
        controller.signal,
      );

      await conn.send!(
        [
          {'role': 'user', 'content': 'hi'},
        ],
        runContext: const RunAgentInputContext(threadId: 't', runId: 'run-1'),
      );
      final ws1 = FakeWebSocket.instances[0];
      await tick();
      ws1.emit(
        {'type': 'TEXT_MESSAGE_CONTENT', 'delta': 'a'},
        id: 'r1-off-1',
      );
      ws1.emit(finishedChunk(threadId: 't', runId: 'run-1'), id: 'r1-off-2');
      await tick();

      await conn.send!(
        [
          {'role': 'user', 'content': 'again'},
        ],
        runContext: const RunAgentInputContext(threadId: 't', runId: 'run-2'),
      );
      await tick();
      expect(FakeWebSocket.instances, hasLength(1));
      ws1.emit(
        {'type': 'TEXT_MESSAGE_CONTENT', 'delta': 'b'},
        id: 'r2-off-1',
      );
      await tick();
      ws1.close();

      await Future<void>.delayed(const Duration(milliseconds: 5));
      final ws2 = FakeWebSocket.instances[1];
      expect(ws2.url.queryParameters['runId'], 'run-2');
      expect(ws2.url.queryParameters['offset'], 'r2-off-1');

      ws2.emit(finishedChunk(threadId: 't', runId: 'run-2'), id: 'r2-off-2');
      await tick();
      controller.cancel();
      await subscription;
      expect(
        received.map((chunk) => chunk['delta'] ?? chunk['type']),
        ['a', 'RUN_FINISHED', 'b', 'RUN_FINISHED'],
      );
    });

    test(
        'a same-runId resubmit clears sawTerminal so a drop during the new '
        'turn still reconnects', () async {
      FakeWebSocket.instances.clear();
      final conn = webSocket(
        'wss://x/api/chat',
        const WebSocketConnectionOptions(
          socketFactory: fakeSocketFactory,
          reconnect: ReconnectOptions(delay: Duration.zero, maxAttempts: 5),
        ),
      );
      final controller = CancellationController();
      final received = <StreamChunk>[];
      final subscription = drain(
        conn.subscribe!(signal: controller.signal),
        received,
        controller.signal,
      );

      await conn.send!(
        [
          {'role': 'user', 'content': 'hi'},
        ],
        runContext: const RunAgentInputContext(threadId: 't', runId: 'run-x'),
      );
      final ws1 = FakeWebSocket.instances[0];
      await tick();
      ws1.emit(
        {
          ...finishedChunk(threadId: 't', runId: 'run-x'),
          'metadata': {
            'tanstack': {'finishReason': 'tool_calls'},
          },
        },
        id: 'off-1',
      );
      await tick();

      await conn.send!(
        [
          {'role': 'user', 'content': 'tool result'},
        ],
        runContext: const RunAgentInputContext(threadId: 't', runId: 'run-x'),
      );
      await tick();
      ws1.emit(
        {'type': 'TEXT_MESSAGE_CONTENT', 'delta': 'more'},
        id: 'off-2',
      );
      await tick();
      ws1.close();

      await Future<void>.delayed(const Duration(milliseconds: 5));
      final ws2 = FakeWebSocket.instances[1];
      expect(ws2.url.queryParameters['offset'], 'off-2');
      controller.cancel();
      await subscription;
    });

    test(
        'aborting a send() emits an { type: "abort", runId } frame on the '
        'conversation socket', () async {
      FakeWebSocket.instances.clear();
      final conn = webSocket(
        'wss://x/api/chat',
        const WebSocketConnectionOptions(socketFactory: fakeSocketFactory),
      );
      final controller = CancellationController();
      await conn.send!(
        [
          {'role': 'user', 'content': 'hi'},
        ],
        signal: controller.signal,
        runContext: const RunAgentInputContext(
          threadId: 't',
          runId: 'run-stop',
        ),
      );
      final ws = FakeWebSocket.instances.single;
      await tick();
      expect(ws.sent, hasLength(1));

      controller.cancel();
      expect(ws.sent, hasLength(2));
      expect(jsonDecodeMap(ws.sent[1]), {
        'type': 'abort',
        'runId': 'run-stop',
      });
    });
  });

  group('webSocket() fatal drop surfacing', () {
    test(
        'a non-durable drop (no offset ever seen) rejects subscribe() with '
        'StreamReadError and does not reconnect', () async {
      FakeWebSocket.instances.clear();
      final conn = webSocket(
        'wss://x/api/chat',
        const WebSocketConnectionOptions(socketFactory: fakeSocketFactory),
      );
      final controller = CancellationController();
      final iterator = StreamIterator<StreamChunk>(
        conn.subscribe!(signal: controller.signal),
      );

      await conn.send!(
        [
          {'role': 'user', 'content': 'hi'},
        ],
        signal: controller.signal,
        runContext: const RunAgentInputContext(threadId: 't', runId: 'r'),
      );
      final ws = FakeWebSocket.instances.single;
      await tick();

      ws.emit({'type': 'TEXT_MESSAGE_CONTENT', 'delta': 'a'});
      await tick();
      ws.close();

      final result = await captureSocketFailure(
        iterator,
        'subscribe() hung instead of rejecting after a non-durable drop',
      );

      expect(result.error, isA<StreamReadError>());
      expect(FakeWebSocket.instances, hasLength(1));
    });

    test(
        'exceeding the reconnect ceiling on a durable run with no forward '
        'progress rejects subscribe() with StreamReconnectLimitError',
        () async {
      FakeWebSocket.instances.clear();
      final conn = webSocket(
        'wss://x/api/chat',
        const WebSocketConnectionOptions(
          socketFactory: fakeSocketFactory,
          reconnect: ReconnectOptions(delay: Duration.zero, maxAttempts: 2),
        ),
      );
      final controller = CancellationController();
      final iterator = StreamIterator<StreamChunk>(
        conn.subscribe!(signal: controller.signal),
      );

      await conn.send!(
        [
          {'role': 'user', 'content': 'hi'},
        ],
        signal: controller.signal,
        runContext: const RunAgentInputContext(
          threadId: 't',
          runId: 'run-stuck',
        ),
      );
      final ws1 = FakeWebSocket.instances[0];
      await tick();
      ws1.emit(
        {'type': 'TEXT_MESSAGE_CONTENT', 'delta': 'a'},
        id: 'off-1',
      );
      await tick();
      ws1.close();
      await tick();

      FakeWebSocket.instances[1].close();
      await tick();
      FakeWebSocket.instances[2].close();
      await tick();
      FakeWebSocket.instances[3].close();
      await tick();

      final result = await captureSocketFailure(
        iterator,
        'subscribe() hung instead of rejecting after the ceiling',
      );

      expect(result.error, isA<StreamReconnectLimitError>());
      expect(FakeWebSocket.instances, hasLength(4));
    });

    test('a malformed inbound frame rejects subscribe() with StreamReadError',
        () async {
      FakeWebSocket.instances.clear();
      final conn = webSocket(
        'wss://x/api/chat',
        const WebSocketConnectionOptions(socketFactory: fakeSocketFactory),
      );
      final controller = CancellationController();
      final iterator = StreamIterator<StreamChunk>(
        conn.subscribe!(signal: controller.signal),
      );

      await conn.send!(
        [
          {'role': 'user', 'content': 'hi'},
        ],
        signal: controller.signal,
        runContext: const RunAgentInputContext(threadId: 't', runId: 'r'),
      );
      final ws = FakeWebSocket.instances.single;
      await tick();
      ws.emitRaw('{');

      final result = await captureSocketFailure(
        iterator,
        'subscribe() hung instead of rejecting after a malformed frame',
      );

      expect(result.error, isA<StreamReadError>());
    });

    test('a joinRun-only socket drop rejects the iterator instead of hanging',
        () async {
      FakeWebSocket.instances.clear();
      final conn = webSocket(
        'wss://x/api/chat',
        const WebSocketConnectionOptions(socketFactory: fakeSocketFactory),
      );
      final controller = CancellationController();
      final iterator = StreamIterator<StreamChunk>(
        conn.joinRun!('run-j', signal: controller.signal),
      );
      await tick();

      final ws = FakeWebSocket.instances.single;
      ws.serverClose(1006);

      final result = await captureSocketFailure(
        iterator,
        'joinRun() hung instead of rejecting after the socket closed',
      );

      expect(result.error, isA<StreamReadError>());
      expect(FakeWebSocket.instances, hasLength(1));
    });

    test(
        'a joinRun socket the server closes cleanly (1000, replay complete) '
        'ends the iterator without error', () async {
      FakeWebSocket.instances.clear();
      final conn = webSocket(
        'wss://x/api/chat',
        const WebSocketConnectionOptions(socketFactory: fakeSocketFactory),
      );
      final iterator = StreamIterator<StreamChunk>(
        conn.joinRun!('run-j'),
      );
      await tick();

      final ws = FakeWebSocket.instances.single;
      ws.emit({'type': 'TEXT_MESSAGE_CONTENT', 'delta': 'replayed'},
          id: 'off-1');
      ws.serverClose(1000);

      final received = await withTimeout(
        drainToEnd(iterator),
        'joinRun() hung instead of ending after the replay',
      );
      expect(received.map((chunk) => chunk['delta']), ['replayed']);
    });
  });

  group('webSocket() run/resume socket isolation', () {
    test(
        'joinRun during an open conversation socket opens its own replay '
        'socket, leaving the conversation socket intact', () async {
      FakeWebSocket.instances.clear();
      final conn = webSocket(
        'wss://x/api/chat',
        const WebSocketConnectionOptions(socketFactory: fakeSocketFactory),
      );
      final controller = CancellationController();
      await conn.send!(
        [
          {'role': 'user', 'content': 'hi'},
        ],
        signal: controller.signal,
        runContext: const RunAgentInputContext(
          threadId: 't',
          runId: 'run-live',
        ),
      );
      final conversation = FakeWebSocket.instances[0];
      await tick();

      final joinController = CancellationController();
      unawaited(
        conn.joinRun!('run-old', signal: joinController.signal).drain<void>(),
      );
      await tick();

      expect(FakeWebSocket.instances, hasLength(2));
      final join = FakeWebSocket.instances[1];
      expect(join.url.queryParameters['offset'], '-1');
      expect(join.url.queryParameters['runId'], 'run-old');
      expect(conversation.readyState, 1);
      joinController.cancel();
      controller.cancel();
    });

    test(
        'send() after joinRun opens a conversation socket instead of writing '
        'the run frame onto the replay socket', () async {
      FakeWebSocket.instances.clear();
      final conn = webSocket(
        'wss://x/api/chat',
        const WebSocketConnectionOptions(socketFactory: fakeSocketFactory),
      );
      final joinController = CancellationController();
      unawaited(
        conn.joinRun!('run-old', signal: joinController.signal).drain<void>(),
      );
      await tick();
      final join = FakeWebSocket.instances[0];

      await conn.send!(
        [
          {'role': 'user', 'content': 'next'},
        ],
        runContext: const RunAgentInputContext(threadId: 't', runId: 'run-new'),
      );
      await tick();
      expect(FakeWebSocket.instances, hasLength(2));
      final conversation = FakeWebSocket.instances[1];
      expect(join.sent, isEmpty);
      expect(conversation.sent, hasLength(1));
      expect(jsonDecodeMap(conversation.sent.single)['runId'], 'run-new');
      expect(conversation.url.queryParameters['offset'], isNull);
      joinController.cancel();
    });
  });
}

Map<String, dynamic> jsonDecodeMap(String raw) =>
    Map<String, dynamic>.from(jsonDecode(raw) as Map);
