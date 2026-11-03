// Faithful runtime port of the upstream `chat-client.test.ts` cases that
// `test/chat/upstream_mapping.json` marked `not-implemented` after the native
// subscribe/send loop landed.
//
// Upstream reference:
//   packages/ai-client/tests/chat-client.test.ts (commit 7095ebbf)
//
// Every test below is a behavior test. Tests for API surfaces the Dart client
// does not expose yet use a dynamic call and fail with an explicit
// `MISSING API EVIDENCE:` message instead of silently weakening the assertion.
import 'dart:async';

import 'package:tanstack_ai_dart/chat.dart';
import 'package:tanstack_ai_dart/connections.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Upstream helpers, adapted to the Dart types.
// ---------------------------------------------------------------------------

Map<String, dynamic> runStarted(String runId, [String threadId = 'thread-1']) =>
    <String, dynamic>{
      'type': 'RUN_STARTED',
      'runId': runId,
      'threadId': threadId,
      'timestamp': 1,
    };

Map<String, dynamic> runFinished(
  String runId, [
  String threadId = 'thread-1',
  String? finishReason = 'stop',
]) =>
    <String, dynamic>{
      'type': 'RUN_FINISHED',
      'runId': runId,
      'threadId': threadId,
      'timestamp': 1,
      'metadata': <String, dynamic>{
        if (finishReason != null)
          'tanstack': <String, dynamic>{
            'finishReason': finishReason,
          },
      },
    };

Map<String, dynamic> textDelta(String messageId, String delta) =>
    <String, dynamic>{
      'type': 'TEXT_MESSAGE_CONTENT',
      'messageId': messageId,
      'delta': delta,
      'timestamp': 1,
    };

/// Upstream `createTextChunks`: per-character content + a run-finished chunk.
List<Map<String, dynamic>> textChunks(
  String text, {
  String messageId = 'msg-1',
  String? runId,
  String? threadId,
  String? finishReason = 'stop',
}) {
  final effectiveRunId = runId ?? 'run-$messageId';
  final effectiveThreadId = threadId ?? 'thread-$messageId';
  return <Map<String, dynamic>>[
    for (final char in text.split('')) textDelta(messageId, char),
    runFinished(effectiveRunId, effectiveThreadId, finishReason),
  ];
}

List<Map<String, dynamic>> runChunks(
  String runId,
  String answer, {
  String threadId = 'thread-1',
}) {
  final messageId = '$runId-answer';
  return <Map<String, dynamic>>[
    runStarted(runId, threadId),
    <String, dynamic>{
      'type': 'TEXT_MESSAGE_START',
      'messageId': messageId,
      'role': 'assistant',
      'timestamp': 1,
    },
    textDelta(messageId, answer),
    <String, dynamic>{
      'type': 'TEXT_MESSAGE_END',
      'messageId': messageId,
      'timestamp': 1,
    },
    runFinished(runId, threadId),
  ];
}

List<Map<String, dynamic>> customChunks(
  List<({String name, Object? value})> events,
) =>
    <Map<String, dynamic>>[
      for (final event in events)
        <String, dynamic>{
          'type': 'CUSTOM',
          'timestamp': 1,
          'name': event.name,
          'value': event.value,
        },
      runFinished('run-1', 'thread-1'),
    ];

/// A real native `ConnectionAdapter(subscribe + send)` with a pushable
/// broadcast stream, mirroring upstream `createPushableSubscribeConnection`.
class PushConnection {
  final StreamController<Map<String, dynamic>> _controller =
      StreamController<Map<String, dynamic>>.broadcast(sync: true);
  final List<List<Map<String, dynamic>>> sent = <List<Map<String, dynamic>>>[];
  final List<RunAgentInputContext?> contexts = <RunAgentInputContext?>[];

  late final ConnectionAdapter adapter = ConnectionAdapter(
    subscribe: ({signal}) => _controller.stream,
    send: (messages, {data, signal, runContext}) async {
      sent.add(messages);
      contexts.add(runContext);
    },
  );

  void push(Map<String, dynamic> chunk) => _controller.add(chunk);
  void pushAll(Iterable<Map<String, dynamic>> chunks) {
    for (final chunk in chunks) {
      _controller.add(chunk);
    }
  }

  Future<void> close() => _controller.close();
}

/// A connect adapter whose yields are gated by the test.
class GatedConnect {
  final Completer<void> release = Completer<void>();
  final List<List<Map<String, dynamic>>> requests =
      <List<Map<String, dynamic>>>[];
  late final ConnectionAdapter adapter = ConnectionAdapter(
    connect: (messages, {data, signal, runContext}) async* {
      requests.add(messages);
      await release.future;
      for (final chunk in textChunks('Delayed')) {
        yield chunk;
      }
    },
  );
}

/// Persistence recorder. `stored` mirrors what a durable store would hold.
class RecordingPersistence {
  List<Map<String, dynamic>>? stored;
  final List<List<Map<String, dynamic>>> writes =
      <List<Map<String, dynamic>>>[];
  final List<String> events = <String>[];
  int getCalls = 0;
  int setCalls = 0;
  int removeCalls = 0;

  ChatPersistence get adapter => ChatPersistence(
        getItem: () {
          getCalls++;
          return stored == null ? null : _restore(stored!);
        },
        setItem: (messages) {
          setCalls++;
          final snapshot = transcript(messages);
          writes.add(snapshot);
          stored = snapshot;
          events.add('set');
        },
        removeItem: () {
          removeCalls++;
          stored = null;
          events.add('remove');
        },
      );
}

List<Map<String, dynamic>> transcript(Iterable<AssistantTurn> messages) =>
    <Map<String, dynamic>>[
      for (final message in messages)
        <String, dynamic>{
          'id': message.id,
          'role': message.role,
          'text': message.parts
              .where((part) => part.type == 'text')
              .map((part) => part.content)
              .join(),
        },
    ];

List<AssistantTurn> _restore(List<Map<String, dynamic>> rows) =>
    <AssistantTurn>[
      for (final row in rows)
        AssistantTurn(
          id: '${row['id']}',
          role: '${row['role']}',
          parts: <AssistantPart>[
            if ('${row['text']}'.isNotEmpty)
              AssistantPart.text('${row['text']}'),
          ],
        ),
    ];

String finalText(ChatClient client) => client
    .getMessages()
    .expand((message) => message.parts)
    .where((part) => part.type == 'text')
    .map((part) => part.content)
    .join();

Map<String, dynamic>? messageById(ChatClient client, String id) {
  for (final message in client.getMessages()) {
    if (message.id == id) {
      return message.toRow();
    }
  }
  return null;
}

Future<void> waitFor(
  bool Function() condition, {
  int tries = 300,
  String? reason,
}) async {
  for (var attempt = 0; attempt < tries; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(Duration.zero);
  }
  throw StateError(reason ?? 'condition was not met');
}

AssistantTurn initialMessage() => AssistantTurn(
      id: 'initial-1',
      role: 'user',
      parts: <AssistantPart>[AssistantPart.text('Initial hello')],
      createdAt: DateTime.utc(2024, 1, 2),
    );

/// Explicit evidence for an upstream assertion whose Dart API does not exist.
Never missingApi(String detail) => fail('MISSING API EVIDENCE: $detail');

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('ChatClient subscribe/send connection mode', () {
    test('returns a client that only watches to ready after each run ends',
        () async {
      const threadId = 'thread-watch';
      var fedAll = false;
      final controller = StreamController<Map<String, dynamic>>.broadcast(
        sync: true,
      );
      final client = ChatClient(
        threadId: threadId,
        connection: ConnectionAdapter(
          subscribe: ({signal}) => controller.stream,
          send: (messages, {data, signal, runContext}) async {},
        ),
      );

      client.subscribe();
      controller
          .addStream(
              Stream<Map<String, dynamic>>.fromIterable(<Map<String, dynamic>>[
        ...runChunks('run-1', 'First answer.', threadId: threadId),
        ...runChunks('run-2', 'Second answer.', threadId: threadId),
      ]))
          .whenComplete(() {
        fedAll = true;
      });

      await waitFor(() => fedAll);
      await waitFor(() => finalText(client).contains('Second answer.'));
      expect(finalText(client), contains('Second answer.'));
      expect(client.getSessionGenerating(), isFalse);
      expect(client.getStatus(), 'ready');
      await client.unsubscribe();
      await controller.close();
      await client.dispose();
    });

    test(
        'should ignore native subscribe/send chunks from a cleared persisted '
        'request without runId', () async {
      final push = PushConnection();
      final persistence = RecordingPersistence();
      final client = ChatClient(
        connection: push.adapter,
        threadId: 'chat-1',
        persistence: persistence.adapter,
      );

      final firstSend = client.sendMessage('A');
      await waitFor(() => client.getIsLoading());
      await client.clear();
      final secondSend = client.sendMessage('B');
      await waitFor(() => push.sent.length >= 2);
      final firstContext = push.contexts[0]!;
      final secondContext = push.contexts[1]!;

      push.pushAll(<Map<String, dynamic>>[
        runStarted(secondContext.runId, secondContext.threadId),
        textDelta('msg-b', 'fresh B'),
        runFinished(secondContext.runId, secondContext.threadId),
      ]);
      await secondSend;

      // Release the stale request after the fresh one has completed.
      push.pushAll(<Map<String, dynamic>>[
        runStarted(firstContext.runId, firstContext.threadId),
        textDelta('msg-a', 'stale A'),
        runFinished(firstContext.runId, firstContext.threadId),
      ]);
      await firstSend;

      final text = finalText(client);
      expect(text, contains('B'));
      expect(text, contains('fresh B'));
      expect(text, isNot(contains('A')));
      expect(text, isNot(contains('stale A')));
      expect(persistence.stored, transcript(client.getMessages()));
      expect(
        persistence.stored!.map((row) => '${row['text']}').join(),
        isNot(contains('stale A')),
      );

      await push.close();
      await client.dispose();
    });

    test(
        'should ignore already-started runless chunks from a cleared persisted '
        'request', () async {
      final push = PushConnection();
      final persistence = RecordingPersistence();
      final client = ChatClient(
        connection: push.adapter,
        threadId: 'chat-1',
        persistence: persistence.adapter,
      );

      final send = client.sendMessage('A');
      await waitFor(() => push.sent.isNotEmpty);
      push.push(runStarted('run-cleared'));
      await waitFor(() => client.getSessionGenerating());

      await client.clear();
      push.push(textDelta('stale-message', 'stale content'));
      push.push(runFinished('run-cleared'));
      await send;

      expect(client.getMessages(), isEmpty);
      expect(persistence.stored, isNull);
      expect(client.getSessionGenerating(), isFalse);
      expect(client.getError(), isNull);

      await push.close();
      await client.dispose();
    });

    test(
        'should keep fresh runless chunks after a clear when a fresh run starts '
        'before stale chunks drain', () async {
      final push = PushConnection();
      final persistence = RecordingPersistence();
      final client = ChatClient(
        connection: push.adapter,
        threadId: 'chat-1',
        persistence: persistence.adapter,
      );

      final firstSend = client.sendMessage('A');
      await waitFor(() => push.sent.isNotEmpty);
      push.push(runStarted('run-cleared'));
      await waitFor(() => client.getSessionGenerating());

      await client.clear();
      final secondSend = client.sendMessage('B');
      await waitFor(() => push.sent.length >= 2);
      final secondContext = push.contexts[1]!;

      push.pushAll(<Map<String, dynamic>>[
        runStarted(secondContext.runId, secondContext.threadId),
        textDelta('fresh-message', 'fresh content'),
        runFinished(secondContext.runId, secondContext.threadId),
      ]);
      await secondSend;

      push.push(textDelta('stale-message', 'stale content'));
      push.push(runFinished('run-cleared'));
      await firstSend;

      final text = finalText(client);
      expect(text, contains('B'));
      expect(text, contains('fresh content'));
      expect(text, isNot(contains('A')));
      expect(text, isNot(contains('stale content')));
      expect(persistence.stored, transcript(client.getMessages()));

      await push.close();
      await client.dispose();
    });

    test(
        'should keep fresh runless chunks after server-only clear drains an '
        'ignored terminal chunk', () async {
      final push = PushConnection();
      final persistence = RecordingPersistence();
      final client = ChatClient(
        connection: push.adapter,
        threadId: 'chat-1',
        persistence: persistence.adapter,
      );

      final firstSend = client.sendMessage('A');
      await waitFor(() => push.sent.isNotEmpty);
      final firstContext = push.contexts[0]!;
      push.push(runStarted(firstContext.runId, firstContext.threadId));
      await waitFor(() => client.getSessionGenerating());

      await client.clear();
      push.push(runFinished(firstContext.runId, firstContext.threadId));
      await firstSend;

      final secondSend = client.sendMessage('B');
      await waitFor(() => push.sent.length >= 2);
      // Upstream strips runId from this run's RUN_FINISHED chunk.
      push.pushAll(<Map<String, dynamic>>[
        ...textChunks('fresh server-only response', messageId: 'fresh-msg').map(
            (chunk) => chunk['type'] == 'RUN_FINISHED'
                ? (Map<String, dynamic>.of(chunk)..remove('runId'))
                : chunk),
      ]);

      await waitFor(
        () => finalText(client).contains('fresh server-only response'),
        reason: 'fresh runless chunks were dropped after the cleared terminal',
      );
      await secondSend;

      final text = finalText(client);
      expect(text, contains('B'));
      expect(text, isNot(contains('A')));

      await push.close();
      await client.dispose();
    });

    test('should ignore stale messages snapshot after persisted clear',
        () async {
      final push = PushConnection();
      final persistence = RecordingPersistence();
      final client = ChatClient(
        connection: push.adapter,
        threadId: 'chat-1',
        persistence: persistence.adapter,
      );

      final send = client.sendMessage('A');
      await waitFor(() => push.sent.isNotEmpty);
      push.push(runStarted('run-1'));
      await waitFor(() => client.getSessionGenerating());

      await client.clear();
      push.push(<String, dynamic>{
        'type': 'MESSAGES_SNAPSHOT',
        'messages': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'stale-assistant',
            'role': 'assistant',
            'content': 'stale snapshot',
          },
        ],
      });
      push.push(runFinished('run-1'));
      await send;

      expect(client.getMessages(), isEmpty);
      expect(persistence.stored, isNull);

      await push.close();
      await client.dispose();
    });

    test('should ignore stale runless run error after persisted clear',
        () async {
      final push = PushConnection();
      final persistence = RecordingPersistence();
      final errors = <Object>[];
      final client = ChatClient(
        connection: push.adapter,
        threadId: 'chat-1',
        persistence: persistence.adapter,
        onError: (error, _) => errors.add(error),
      );

      final send = client.sendMessage('A');
      await waitFor(() => push.sent.isNotEmpty);
      push.push(runStarted('run-1'));
      await waitFor(() => client.getSessionGenerating());

      await client.clear();
      push.push(<String, dynamic>{
        'type': 'RUN_ERROR',
        'threadId': 'thread-1',
        'message': 'stale failure',
        'error': <String, dynamic>{'message': 'stale failure'},
        'timestamp': 1,
      });
      await send;

      expect(client.getMessages(), isEmpty);
      expect(client.getError(), isNull);
      expect(client.getStatus(), 'ready');
      expect(errors, isEmpty);
      expect(persistence.stored, isNull);

      await push.close();
      await client.dispose();
    });

    test(
        'should keep fresh native subscribe/send chunks when they arrive '
        'before stale cleared chunks', () async {
      final push = PushConnection();
      final persistence = RecordingPersistence();
      final client = ChatClient(
        connection: push.adapter,
        threadId: 'chat-1',
        persistence: persistence.adapter,
      );

      final firstSend = client.sendMessage('A');
      await waitFor(() => push.sent.isNotEmpty);
      await waitFor(() => client.getIsLoading());

      await client.clear();
      final secondSend = client.sendMessage('B');
      await waitFor(() => push.sent.length >= 2);
      final firstContext = push.contexts[0]!;
      final secondContext = push.contexts[1]!;

      push.pushAll(<Map<String, dynamic>>[
        runStarted(secondContext.runId, secondContext.threadId),
        textDelta('msg-b', 'fresh B'),
        runFinished(secondContext.runId, secondContext.threadId),
      ]);
      await secondSend;

      push.pushAll(<Map<String, dynamic>>[
        runStarted(firstContext.runId, firstContext.threadId),
        textDelta('msg-a', 'stale A'),
        runFinished(firstContext.runId, firstContext.threadId),
      ]);
      await firstSend;

      final text = finalText(client);
      expect(text, contains('B'));
      expect(text, contains('fresh B'));
      expect(text, isNot(contains('A')));
      expect(text, isNot(contains('stale A')));
      expect(persistence.stored, transcript(client.getMessages()));
      final storedText =
          persistence.stored!.map((row) => '${row['text']}').join();
      expect(storedText, contains('fresh B'));
      expect(storedText, isNot(contains('stale A')));

      await push.close();
      await client.dispose();
    });

    test(
        'should ignore stale tool chunks by cleared parentMessageId after '
        'persisted clear', () async {
      final push = PushConnection();
      final persistence = RecordingPersistence();
      final client = ChatClient(
        connection: push.adapter,
        threadId: 'chat-1',
        persistence: persistence.adapter,
      );

      final send = client.sendMessage('A');
      await waitFor(() => push.sent.isNotEmpty);
      push.push(runStarted('run-1'));
      push.push(textDelta('assistant-a', ''));
      await waitFor(
        () => client.getMessages().any((m) => m.id == 'assistant-a'),
      );

      await client.clear();
      push.push(<String, dynamic>{
        'type': 'TOOL_CALL_START',
        'toolCallId': 'stale-tool',
        'toolCallName': 'staleTool',
        'parentMessageId': 'assistant-a',
        'timestamp': 1,
        'index': 0,
      });
      push.push(<String, dynamic>{
        'type': 'TOOL_CALL_ARGS',
        'toolCallId': 'stale-tool',
        'delta': '{"stale":true}',
        'timestamp': 1,
      });
      await send;

      expect(client.getMessages(), isEmpty);
      final storedHasTool = persistence.writes.any((write) => write.any(
            (row) =>
                row['id'] == 'assistant-a' &&
                '${row['text']}'.contains('stale'),
          ));
      expect(storedHasTool, isFalse);

      await push.close();
      await client.dispose();
    });

    test(
        'should remember ignored stale runless message ids so child tool chunks '
        'are ignored after persisted clear', () async {
      final push = PushConnection();
      final persistence = RecordingPersistence();
      final client = ChatClient(
        connection: push.adapter,
        threadId: 'chat-1',
        persistence: persistence.adapter,
      );

      final send = client.sendMessage('A');
      await waitFor(() => push.sent.isNotEmpty);
      push.push(runStarted('run-1'));
      await waitFor(() => client.getSessionGenerating());

      await client.clear();
      push.push(textDelta('stale-runless-message', 'stale text'));
      push.push(<String, dynamic>{
        'type': 'TOOL_CALL_START',
        'toolCallId': 'stale-child-tool',
        'toolCallName': 'staleTool',
        'parentMessageId': 'stale-runless-message',
        'timestamp': 1,
        'index': 0,
      });
      push.push(<String, dynamic>{
        'type': 'TOOL_CALL_ARGS',
        'toolCallId': 'stale-child-tool',
        'delta': '{"stale":true}',
        'timestamp': 1,
      });
      await send;

      expect(client.getMessages(), isEmpty);
      expect(
        persistence.writes.any(
          (write) => write.any((row) => row['id'] == 'stale-runless-message'),
        ),
        isFalse,
      );

      await push.close();
      await client.dispose();
    });

    test(
        'should ignore stale runless tool starts without parentMessageId after '
        'persisted clear', () async {
      final push = PushConnection();
      final persistence = RecordingPersistence();
      final client = ChatClient(
        connection: push.adapter,
        threadId: 'chat-1',
        persistence: persistence.adapter,
      );

      final send = client.sendMessage('A');
      await waitFor(() => push.sent.isNotEmpty);
      push.push(runStarted('run-1'));
      await waitFor(() => client.getSessionGenerating());

      await client.clear();
      push.push(<String, dynamic>{
        'type': 'TOOL_CALL_START',
        'toolCallId': 'stale-parentless-tool',
        'toolCallName': 'staleTool',
        'timestamp': 1,
        'index': 0,
      });
      push.push(<String, dynamic>{
        'type': 'TOOL_CALL_ARGS',
        'toolCallId': 'stale-parentless-tool',
        'delta': '{"stale":true}',
        'timestamp': 1,
      });
      await send;

      expect(client.getMessages(), isEmpty);
      expect(
        persistence.writes.any(
          (write) => write.any(
            (row) => '${row['text']}'.contains('stale'),
          ),
        ),
        isFalse,
      );

      await push.close();
      await client.dispose();
    });

    test(
        'should reset session generation when a persisted clear ignores '
        'terminal chunks', () async {
      final push = PushConnection();
      final client = ChatClient(
        connection: push.adapter,
        threadId: 'chat-1',
        persistence: RecordingPersistence().adapter,
      );

      final send = client.sendMessage('A');
      await waitFor(() => push.sent.isNotEmpty);
      push.push(runStarted('run-1'));
      await waitFor(() => client.getSessionGenerating());

      await client.clear();
      push.push(runFinished('run-1'));
      await send;

      expect(client.getSessionGenerating(), isFalse);

      await push.close();
      await client.dispose();
    });

    test(
        'should ignore live-only active run chunks after persisted clear and '
        'clean up session generation', () async {
      final push = PushConnection();
      final persistence = RecordingPersistence();
      final client = ChatClient(
        connection: push.adapter,
        threadId: 'chat-1',
        persistence: persistence.adapter,
      );

      client.subscribe();
      await waitFor(() => client.getIsSubscribed());
      push.push(runStarted('live-run-1'));
      await waitFor(() => client.getSessionGenerating());

      await client.clear();
      push.push(<String, dynamic>{
        'type': 'TEXT_MESSAGE_START',
        'messageId': 'live-message-1',
        'role': 'assistant',
      });
      push.push(textDelta('live-message-1', 'stale live content'));
      push.push(runFinished('live-run-1'));

      await waitFor(() => client.getSessionGenerating() == false);
      expect(client.getMessages(), isEmpty);
      expect(persistence.stored, isNull);

      await push.close();
      await client.dispose();
    });

    test(
        'should not expose request generation metadata on public chunks or run '
        'context', () async {
      final onChunk = <Map<String, dynamic>>[];
      final runContexts = <RunAgentInputContext?>[];
      final client = ChatClient(
        connection: ConnectionAdapter(
          connect: (messages, {data, signal, runContext}) async* {
            runContexts.add(runContext);
            for (final chunk in textChunks('Hello')) {
              yield chunk;
            }
          },
        ),
        onChunk: onChunk.add,
      );

      await client.sendMessage('Hello');

      expect(runContexts, isNotEmpty);
      final context = runContexts.first as dynamic;
      expect(() => context.requestGeneration, throwsNoSuchMethodError);
      expect(onChunk, isNotEmpty);
      for (final chunk in onChunk) {
        expect(chunk.containsKey('requestGeneration'), isFalse);
      }

      await client.dispose();
    });

    test('should not add internal threadId or runId to public connect chunks',
        () async {
      final onChunk = <Map<String, dynamic>>[];
      final client = ChatClient(
        connection: ConnectionAdapter(
          connect: (messages, {data, signal, runContext}) async* {
            yield <String, dynamic>{
              'type': 'TEXT_MESSAGE_CONTENT',
              'messageId': 'public-message',
              'timestamp': 1,
              'delta': 'Hello',
            };
          },
        ),
        onChunk: onChunk.add,
      );

      await client.sendMessage('Hello');

      expect(
        onChunk.any(
          (chunk) =>
              chunk['type'] == 'TEXT_MESSAGE_CONTENT' &&
              chunk['messageId'] == 'public-message',
        ),
        isTrue,
      );
      for (final chunk in onChunk) {
        if (chunk['type'] == 'TEXT_MESSAGE_CONTENT') {
          expect(chunk.containsKey('threadId'), isFalse);
          expect(chunk.containsKey('runId'), isFalse);
        }
      }

      await client.dispose();
    });

    test('should emit subscription and connection lifecycle callbacks',
        () async {
      final adapter = PushConnection();
      final subscriptionChanges = <bool>[];
      final connectionStatuses = <String>[];
      final client = ChatClient(
        connection: adapter.adapter,
        onSubscriptionChange: subscriptionChanges.add,
        onConnectionStatusChange: connectionStatuses.add,
      );

      client.subscribe();
      final send = client.sendMessage('Hello');
      await waitFor(() => adapter.sent.isNotEmpty);
      adapter.pushAll(textChunks('callback flow'));
      await send;
      await client.unsubscribe();

      expect(subscriptionChanges, <bool>[true, false]);
      expect(connectionStatuses.first, 'connecting');
      expect(connectionStatuses, contains('connected'));
      expect(connectionStatuses.last, 'disconnected');
      await adapter.close();
      await client.dispose();
    });

    test('unsubscribe should abort in-flight requests and disconnect',
        () async {
      final push = PushConnection();
      final client = ChatClient(connection: push.adapter);

      client.subscribe();
      final send = client.sendMessage('Hello');
      await waitFor(() => push.sent.isNotEmpty);
      await client.unsubscribe();

      await send.timeout(const Duration(seconds: 2));
      expect(client.getIsLoading(), isFalse);
      expect(client.getIsSubscribed(), isFalse);
      expect(client.getConnectionStatus(), 'disconnected');

      await push.close();
      await client.dispose();
    });

    test('should expose connectionStatus error for subscription loop failures',
        () async {
      final client = ChatClient(
        connection: ConnectionAdapter(
          subscribe: ({signal}) => failingSubscription('subscription failed'),
          send: (messages, {data, signal, runContext}) async {},
        ),
      );

      client.subscribe();
      await waitFor(() => client.getIsSubscribed() == false);
      expect(client.getIsSubscribed(), isFalse);
      expect(client.getStatus(), 'error');
      expect(client.getConnectionStatus(), 'error');

      await client.dispose();
    });

    test('should expose connectionStatus error when subscribe throws',
        () async {
      final client = ChatClient(
        connection: ConnectionAdapter(
          subscribe: ({signal}) => throw StateError('subscription failed'),
          send: (messages, {data, signal, runContext}) async {},
        ),
      );

      try {
        client.subscribe();
      } on Object catch (error) {
        missingApi(
          'ChatClient.subscribe() rethrows a synchronous subscribe() failure; '
          'upstream expects it not to throw and to report connectionStatus '
          'error instead. Thrown: $error',
        );
      }
      await waitFor(() => client.getIsSubscribed() == false);
      expect(client.getIsSubscribed(), isFalse);
      expect(client.getConnectionStatus(), 'error');

      await client.dispose();
    });
  });

  group('ChatClient subscribe/send sessionGenerating', () {
    test('should remain correct through subscribe/unsubscribe cycles',
        () async {
      final push = PushConnection();
      final client = ChatClient(connection: push.adapter);

      final send = client.sendMessage('Hello');
      await waitFor(() => push.sent.isNotEmpty);
      push.pushAll(textChunks('Hi'));
      await send;
      expect(client.getSessionGenerating(), isFalse);

      await client.unsubscribe();
      expect(client.getSessionGenerating(), isFalse);

      await push.close();
      await client.dispose();
    });

    test('should reset on unsubscribe while generating', () async {
      final controller = StreamController<Map<String, dynamic>>.broadcast(
        sync: true,
      );
      final generatingChanges = <bool>[];
      final client = ChatClient(
        connection: ConnectionAdapter(
          subscribe: ({signal}) => controller.stream,
          send: (messages, {data, signal, runContext}) async {},
        ),
        onSessionGeneratingChange: generatingChanges.add,
      );

      client.subscribe();
      await waitFor(() => client.getIsSubscribed());
      controller.add(runStarted('run-1'));
      await waitFor(() => client.getSessionGenerating());

      expect(client.getSessionGenerating(), isTrue);
      await client.unsubscribe();
      expect(client.getSessionGenerating(), isFalse);
      expect(generatingChanges, <bool>[true, false]);

      await controller.close();
      await client.dispose();
    });

    test('should reset on connection adapter replacement', () async {
      final first = PushConnection();
      final second = PushConnection();
      final generatingChanges = <bool>[];
      final client = ChatClient(
        connection: first.adapter,
        onSessionGeneratingChange: generatingChanges.add,
      );

      client.subscribe();
      await waitFor(() => client.getIsSubscribed());
      first.push(runStarted('run-1'));
      await waitFor(() => client.getSessionGenerating());
      expect(client.getSessionGenerating(), isTrue);

      client.updateOptions(connection: second.adapter);

      expect(client.getSessionGenerating(), isFalse);
      expect(generatingChanges, <bool>[true, false]);
      await client.unsubscribe();
      await first.close();
      await second.close();
      await client.dispose();
    });

    test('should not emit duplicate callbacks on repeated same-state events',
        () async {
      final push = PushConnection();
      final generatingChanges = <bool>[];
      final client = ChatClient(
        connection: push.adapter,
        onSessionGeneratingChange: generatingChanges.add,
      );

      final send = client.sendMessage('Hello');
      await waitFor(() => push.sent.isNotEmpty);
      push.pushAll(<Map<String, dynamic>>[
        runStarted('run-1'),
        runStarted('run-1'),
        textDelta('msg-1', 'Hi'),
        runFinished('run-1'),
        runFinished('run-1'),
      ]);
      await send;

      expect(generatingChanges, <bool>[true, false]);

      await push.close();
      await client.dispose();
    });

    test('should handle interleaved multi-run events from durable subscription',
        () async {
      final push = PushConnection();
      final generatingChanges = <bool>[];
      final client = ChatClient(
        connection: push.adapter,
        onSessionGeneratingChange: generatingChanges.add,
      );

      final first = client.sendMessage('First');
      await waitFor(() => push.sent.isNotEmpty);
      push.pushAll(<Map<String, dynamic>>[
        runStarted('run-first'),
        textDelta('msg-first', 'A'),
        runFinished('run-first'),
      ]);
      await first;
      expect(generatingChanges, <bool>[true, false]);

      final second = client.sendMessage('Second');
      await waitFor(() => push.sent.length >= 2);
      push.pushAll(<Map<String, dynamic>>[
        runStarted('run-second'),
        textDelta('msg-second', 'B'),
        runFinished('run-second'),
      ]);
      await second;
      expect(generatingChanges, <bool>[true, false, true, false]);

      await push.close();
      await client.dispose();
    });

    test('should stay true during concurrent runs until all finish', () async {
      final push = PushConnection();
      final generatingChanges = <bool>[];
      final finishedRunIds = <String>[];
      final client = ChatClient(
        connection: push.adapter,
        onChunk: (chunk) {
          if (chunk['type'] == 'RUN_FINISHED' && chunk['runId'] is String) {
            finishedRunIds.add(chunk['runId'] as String);
          }
        },
        onSessionGeneratingChange: generatingChanges.add,
      );

      client.subscribe();
      await waitFor(() => client.getIsSubscribed());

      push.pushAll(<Map<String, dynamic>>[
        runStarted('run-1'),
        runStarted('run-2'),
      ]);
      await waitFor(() => client.getSessionGenerating());
      expect(client.getSessionGenerating(), isTrue);

      push.push(runFinished('run-1'));
      await waitFor(() => finishedRunIds.contains('run-1'));
      expect(client.getSessionGenerating(), isTrue);

      push.push(runFinished('run-2'));
      await waitFor(() => client.getSessionGenerating() == false);
      expect(client.getSessionGenerating(), isFalse);
      expect(generatingChanges, <bool>[true, false]);

      await client.unsubscribe();
      await push.close();
      await client.dispose();
    });

    test(
        'should process future live subscription chunks after persistence '
        'clear', () async {
      final push = PushConnection();
      final persistence = RecordingPersistence();
      final client = ChatClient(
        connection: push.adapter,
        threadId: 'chat-1',
        persistence: persistence.adapter,
      );

      client.subscribe();
      await waitFor(() => client.getIsSubscribed());
      await client.clear();

      push.pushAll(textChunks('future live', messageId: 'future-live'));
      await waitFor(
        () => client.getMessages().any(
              (message) => message.parts.any(
                (part) =>
                    part.type == 'text' && part.content.contains('future live'),
              ),
            ),
        reason: 'future live chunks were dropped after clear',
      );

      await client.unsubscribe();
      await push.close();
      await client.dispose();
    });

    test('should clear all runs on RUN_ERROR without runId', () async {
      final push = PushConnection();
      final generatingChanges = <bool>[];
      final client = ChatClient(
        connection: push.adapter,
        onSessionGeneratingChange: generatingChanges.add,
      );

      client.subscribe();
      await waitFor(() => client.getIsSubscribed());
      push.pushAll(<Map<String, dynamic>>[
        runStarted('run-1'),
        runStarted('run-2'),
      ]);
      await waitFor(() => client.getSessionGenerating());

      push.push(<String, dynamic>{
        'type': 'RUN_ERROR',
        'message': 'session crashed',
        'timestamp': 1,
        'error': <String, dynamic>{'message': 'session crashed'},
      });
      await waitFor(() => client.getSessionGenerating() == false);
      expect(client.getSessionGenerating(), isFalse);
      expect(generatingChanges, <bool>[true, false]);

      await client.unsubscribe();
      await push.close();
      await client.dispose();
    });

    test('should reset on fatal subscription loop teardown', () async {
      final generatingChanges = <bool>[];
      var yieldedStart = false;
      final client = ChatClient(
        connection: ConnectionAdapter(
          subscribe: ({signal}) => (() async* {
            if (!yieldedStart) {
              yieldedStart = true;
              yield runStarted('run-1');
              await Future<void>.delayed(const Duration(milliseconds: 10));
            }
            throw StateError('subscription failed');
          })(),
          send: (messages, {data, signal, runContext}) async {},
        ),
        onSessionGeneratingChange: generatingChanges.add,
      );

      client.subscribe();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(yieldedStart, isTrue);
      expect(
        client.getSessionGenerating(),
        isFalse,
        reason: 'fatal teardown did not reset session generating',
      );
      expect(generatingChanges, contains(true));
      expect(generatingChanges.last, isFalse);

      await client.dispose();
    });
  });

  group('ChatClient clear', () {
    test('should remove persisted messages without saving an empty snapshot',
        () async {
      final push = PushConnection();
      final persistence = RecordingPersistence();
      final client = ChatClient(
        connection: push.adapter,
        threadId: 'chat-1',
        persistence: persistence.adapter,
      );

      final send = client.sendMessage('Hello');
      await waitFor(() => push.sent.isNotEmpty);
      push.pushAll(textChunks('Response'));
      await send;

      final writesBeforeClear = persistence.setCalls;
      await client.clear();

      expect(persistence.removeCalls, greaterThanOrEqualTo(1));
      expect(persistence.setCalls, writesBeforeClear);

      await push.close();
      await client.dispose();
    });

    test(
        'should not persist non-cooperative delayed chunks after clear removes '
        'storage', () async {
      final persistence = RecordingPersistence();
      final client = ChatClient(
        connection: ConnectionAdapter(
          connect: (messages, {data, signal, runContext}) async* {
            await Future<void>.delayed(const Duration(milliseconds: 10));
            for (final chunk in textChunks('Delayed')) {
              yield chunk;
            }
          },
        ),
        threadId: 'chat-1',
        persistence: persistence.adapter,
      );

      final send = client.sendMessage('Hello');
      await Future<void>.delayed(Duration.zero);
      await client.clear();
      await send;

      final removeIndex = persistence.events.indexOf('remove');
      expect(removeIndex, greaterThanOrEqualTo(0));
      expect(persistence.events.skip(removeIndex + 1), isNot(contains('set')));
      expect(client.getMessages(), isEmpty);
      expect(persistence.removeCalls, greaterThanOrEqualTo(1));

      await client.dispose();
    });

    test(
        'should ignore cleared request chunks after persistence resumes for a '
        'new send', () async {
      final releaseFirst = Completer<void>();
      final persistence = RecordingPersistence();
      final connection = ConnectionAdapter(
        connect: (messages, {data, signal, runContext}) async* {
          final text = messages
              .expand((message) => message['parts'] is List
                  ? (message['parts'] as List)
                  : const <Object?>[])
              .whereType<Map>()
              .where((part) => part['type'] == 'text')
              .map((part) => '${part['content']}')
              .join();
          if (text == 'A') {
            await releaseFirst.future;
            for (final chunk in textChunks('stale A', messageId: 'msg-a')) {
              yield chunk;
            }
            return;
          }
          for (final chunk in textChunks('fresh B', messageId: 'msg-b')) {
            yield chunk;
          }
        },
      );
      final client = ChatClient(
        connection: connection,
        threadId: 'chat-1',
        persistence: persistence.adapter,
      );

      final firstSend = client.sendMessage('A');
      await waitFor(() => client.getIsLoading());

      await client.clear();
      await client.sendMessage('B');
      releaseFirst.complete();
      await firstSend;

      final text = finalText(client);
      expect(text, contains('B'));
      expect(text, contains('fresh B'));
      expect(text, isNot(contains('A')));
      expect(text, isNot(contains('stale A')));
      expect(persistence.stored, transcript(client.getMessages()));
      expect(
        persistence.stored!.map((row) => '${row['text']}').join(),
        isNot(contains('stale A')),
      );

      await client.dispose();
    });

    test(
        'should ensure async setItem scheduled before clear cannot win after '
        'removeItem', () async {
      final releaseSet = Completer<void>();
      List<Map<String, dynamic>>? stored;
      var setCalls = 0;
      var removeCalls = 0;
      final persistence = ChatPersistence(
        getItem: () => null,
        setItem: (messages) async {
          setCalls++;
          final snapshot = transcript(messages);
          await releaseSet.future;
          stored = snapshot;
        },
        removeItem: () {
          removeCalls++;
          stored = null;
        },
      );
      final push = PushConnection();
      final client = ChatClient(
        connection: push.adapter,
        threadId: 'chat-1',
        persistence: persistence,
      );

      final send = client.sendMessage('Hello');
      await waitFor(() => push.sent.isNotEmpty);
      push.pushAll(textChunks('Response'));
      await send;
      await waitFor(() => setCalls > 0, reason: 'setItem was never scheduled');

      await client.clear();
      releaseSet.complete();
      await Future<void>.delayed(Duration.zero);

      expect(removeCalls, greaterThanOrEqualTo(1));
      expect(stored, isNull);

      await push.close();
      await client.dispose();
    });

    test(
        'should preserve state updates and onMessagesChange when persistence '
        'throws', () async {
      final onMessagesChange = <List<AssistantTurn>>[];
      final persistence = ChatPersistence(
        getItem: () => throw StateError('get failed'),
        setItem: (_) => throw StateError('set failed'),
        removeItem: () => throw StateError('remove failed'),
      );
      final push = PushConnection();
      final client = ChatClient(
        connection: push.adapter,
        threadId: 'chat-1',
        messages: <AssistantTurn>[initialMessage()],
        persistence: persistence,
        onMessagesChange: onMessagesChange.add,
      );

      expect(client.getMessages(), hasLength(1));
      expect(client.getMessages().first.id, 'initial-1');

      final send = client.sendMessage('Hello');
      await waitFor(() => push.sent.isNotEmpty);
      push.pushAll(textChunks('Response'));
      await send;

      expect(client.getMessages().length, greaterThan(1));
      expect(onMessagesChange, isNotEmpty);

      await client.clear();
      expect(client.getMessages(), isEmpty);

      await push.close();
      await client.dispose();
    });
  });

  group('ChatClient drain re-entrancy guard (fix #302)', () {
    test(
        'should continue after multiple client tools complete in the same '
        'round', () async {
      final roundOne = <Map<String, dynamic>>[
        <String, dynamic>{
          'type': 'TOOL_CALL_START',
          'toolCallId': 'tc-1',
          'toolCallName': 'tool_one',
          'timestamp': 1,
        },
        <String, dynamic>{
          'type': 'TOOL_CALL_ARGS',
          'toolCallId': 'tc-1',
          'delta': '{}',
          'timestamp': 1,
        },
        <String, dynamic>{
          'type': 'CUSTOM',
          'name': 'tool-input-available',
          'value': <String, dynamic>{
            'toolCallId': 'tc-1',
            'toolName': 'tool_one',
            'input': <String, dynamic>{},
          },
          'timestamp': 1,
        },
        <String, dynamic>{
          'type': 'TOOL_CALL_START',
          'toolCallId': 'tc-2',
          'toolCallName': 'tool_two',
          'timestamp': 1,
        },
        <String, dynamic>{
          'type': 'TOOL_CALL_ARGS',
          'toolCallId': 'tc-2',
          'delta': '{}',
          'timestamp': 1,
        },
        <String, dynamic>{
          'type': 'CUSTOM',
          'name': 'tool-input-available',
          'value': <String, dynamic>{
            'toolCallId': 'tc-2',
            'toolName': 'tool_two',
            'input': <String, dynamic>{},
          },
          'timestamp': 1,
        },
        runFinished('run-round-1', 'thread-msg-1', 'tool_calls'),
      ];
      final roundTwo = textChunks('Done!', messageId: 'msg-2');
      var callIndex = 0;
      final client = ChatClient(
        connection: ConnectionAdapter(
          connect: (messages, {data, signal, runContext}) async* {
            callIndex++;
            final chunks = callIndex == 1 ? roundOne : roundTwo;
            for (final chunk in chunks) {
              if (signal?.isCancelled ?? false) return;
              yield chunk;
            }
          },
        ),
        tools: <ChatClientTool>[
          ChatClientTool(
            name: 'tool_one',
            description: 'Tool one',
            execute: (input, context) async =>
                <String, dynamic>{'result': 'one'},
          ),
          ChatClientTool(
            name: 'tool_two',
            description: 'Tool two',
            execute: (input, context) async =>
                <String, dynamic>{'result': 'two'},
          ),
        ],
      );

      await client.sendMessage('Run both tools');
      await waitFor(
        () => !client.getIsLoading() && callIndex >= 2,
        reason: 'continuation round never started after simultaneous tools',
      );

      final assistants = client
          .getMessages()
          .where((message) => message.role == 'assistant')
          .toList();
      final lastAssistant = assistants.last;
      final textPart = lastAssistant.parts
          .firstWhere((part) => part.type == 'text', orElse: () {
        throw StateError('last assistant has no text part');
      });
      expect(textPart.content, 'Done!');

      await client.dispose();
    });
  });

  group('ChatClient concurrent runs and reconnect correctness', () {
    test(
        'concurrent runs should not produce duplicate messages or corrupt '
        'content', () async {
      final push = PushConnection();
      final finishedRunIds = <String>[];
      final client = ChatClient(
        connection: push.adapter,
        onChunk: (chunk) {
          if (chunk['type'] == 'RUN_FINISHED' && chunk['runId'] is String) {
            finishedRunIds.add(chunk['runId'] as String);
          }
        },
      );

      client.subscribe();
      await waitFor(() => client.getIsSubscribed());

      push.pushAll(<Map<String, dynamic>>[
        runStarted('run-a'),
        <String, dynamic>{
          'type': 'TEXT_MESSAGE_START',
          'messageId': 'msg-a',
          'role': 'assistant',
          'timestamp': 1,
        },
        textDelta('msg-a', 'Story: '),
      ]);
      await waitFor(
        () => client.getMessages().any((message) => message.id == 'msg-a'),
      );

      push.pushAll(<Map<String, dynamic>>[
        runStarted('run-b'),
        <String, dynamic>{
          'type': 'TEXT_MESSAGE_START',
          'messageId': 'msg-b',
          'role': 'assistant',
          'timestamp': 1,
        },
        textDelta('msg-b', 'Hi!'),
      ]);
      await waitFor(
        () => client.getMessages().any((message) => message.id == 'msg-b'),
      );

      push.push(runFinished('run-b'));
      await waitFor(() => finishedRunIds.contains('run-b'));

      push.push(textDelta('msg-a', 'once upon a time'));
      await waitFor(() {
        final row = messageById(client, 'msg-a');
        final parts = row?['parts'];
        return parts is List &&
            parts.isNotEmpty &&
            (parts.first as Map)['content'] == 'Story: once upon a time';
      }, reason: 'msg-a content was not appended exactly once');

      final messages = client.getMessages();
      final msgB = messages.firstWhere((message) => message.id == 'msg-b');
      expect(msgB.parts.first.content, 'Hi!');
      expect(messages.where((message) => message.id == 'msg-a'), hasLength(1));
      expect(messages.where((message) => message.id == 'msg-b'), hasLength(1));

      push.push(runFinished('run-a'));
      await waitFor(() => client.getSessionGenerating() == false);
      await client.unsubscribe();
      await push.close();
      await client.dispose();
    });
  });

  group('ChatClient error handling', () {
    test('should surface subscription loop failures without hanging', () async {
      final errors = <Object>[];
      final client = ChatClient(
        connection: ConnectionAdapter(
          subscribe: ({signal}) => failingSubscription('subscription exploded'),
          send: (messages, {data, signal, runContext}) async {},
        ),
        onError: (error, _) => errors.add(error),
      );

      await client.sendMessage('Hello').timeout(const Duration(seconds: 2));

      expect(errors, hasLength(1));
      expect(generatorsError(errors.first), contains('subscription exploded'));
      expect(client.getStatus(), 'error');

      await client.dispose();
    });
  });

  group('ChatClient custom events', () {
    test('should allow updating onCustomEvent via updateOptions', () async {
      final seen = <Map<String, dynamic>>[];
      Object? seenContext = 'unset';
      final client = ChatClient(
        connection: ConnectionAdapter(
          connect: (messages, {data, signal, runContext}) async* {
            for (final chunk in customChunks(<({String name, Object? value})>[
              (name: 'test-event', value: <String, dynamic>{'value': 42}),
            ])) {
              yield chunk;
            }
          },
        ),
      );

      client.updateOptions(
        onCustomEvent: (event, context) {
          seen.add(event);
          seenContext = context;
        },
      );

      await client.sendMessage('Test');

      expect(seen, hasLength(1));
      expect(seen.single['name'], 'test-event');
      expect(seen.single['value'], <String, dynamic>{'value': 42});
      expect(seenContext, isNull);

      await client.dispose();
    });
  });
}

Stream<StreamChunk> failingSubscription(String message) async* {
  throw StateError(message);
}

/// Upstream asserts the subscription error is an `Error` with its message.
String generatorsError(Object error) =>
    error is Error ? error.toString() : '$error';
