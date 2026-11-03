// Faithful runtime ports of the remaining client-boundary upstream cases:
//
// - packages/ai-client/tests/chat-client-abort.test.ts        (8 cases)
// - packages/ai-client/tests/sse-parser-cleanup.test.ts      (7 cases)
// - packages/ai-client/tests/chat-client.test.ts             (activity, multimodal, append)
//
// Abort cases use a real `ConnectionAdapter` (never `FakeChatTransport`).
// SSE cleanup cases drive the actual `GenerationClient` with a fetcher that
// returns `http.StreamedResponse`, not `parseSseResponse` directly.
//
// No placeholder assertions: every expectation below mirrors a named upstream
// assertion, adapted only where the Dart API shape differs.
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:tanstack_ai_dart/tanstack_ai_dart.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

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

Map<String, dynamic> runFinished([String runId = 'run-1']) => <String, dynamic>{
      'type': 'RUN_FINISHED',
      'runId': runId,
      'threadId': 'thread-1',
      'timestamp': 1,
      'metadata': <String, dynamic>{
        'tanstack': <String, dynamic>{'finishReason': 'stop'},
      },
    };

List<Map<String, dynamic>> textRun(
  String text, {
  String messageId = 'msg-1',
  String runId = 'run-1',
}) =>
    <Map<String, dynamic>>[
      <String, dynamic>{
        'type': 'RUN_STARTED',
        'runId': runId,
        'threadId': 'thread-1',
        'timestamp': 1,
      },
      <String, dynamic>{
        'type': 'TEXT_MESSAGE_START',
        'messageId': messageId,
        'role': 'assistant',
        'timestamp': 1,
      },
      for (final char in text.split(''))
        <String, dynamic>{
          'type': 'TEXT_MESSAGE_CONTENT',
          'messageId': messageId,
          'delta': char,
          'timestamp': 1,
        },
      <String, dynamic>{
        'type': 'TEXT_MESSAGE_END',
        'messageId': messageId,
        'timestamp': 1,
      },
      runFinished(runId),
    ];

AssistantTurn userTurn(String id, String text) => AssistantTurn(
      id: id,
      role: 'user',
      parts: <AssistantPart>[AssistantPart.text(text)],
      createdAt: DateTime.utc(2024, 1, 1),
    );

/// Canonical persistence adapter (combined messages + resume), used where
/// upstream passes a `ChatClientPersistence`.
class MemoryPersistence implements ChatClientPersistence {
  ChatPersistedState? state;
  int setCalls = 0;
  int removeCalls = 0;

  MemoryPersistence([this.state]);

  @override
  FutureOr<Object?> getItem(String id) => state;

  @override
  FutureOr<void> setItem(String id, ChatPersistedState value) {
    state = value;
    setCalls++;
  }

  @override
  FutureOr<void> removeItem(String id) {
    state = null;
    removeCalls++;
  }
}

// ---------------------------------------------------------------------------
// (1) chat-client-abort.test.ts
// ---------------------------------------------------------------------------

void main() {
  group('ChatClient abort signal handling', () {
    test('should create AbortController and pass signal to adapter', () async {
      CancellationSignal? receivedSignal;
      final client = ChatClient(
        connection: ConnectionAdapter(
          connect: (messages, {data, signal, runContext}) async* {
            receivedSignal = signal;
            yield <String, dynamic>{
              'type': 'TEXT_MESSAGE_CONTENT',
              'messageId': '1',
              'timestamp': 1,
              'delta': 'Hello',
            };
            yield <String, dynamic>{
              'type': 'TEXT_MESSAGE_CONTENT',
              'messageId': '1',
              'timestamp': 1,
              'delta': ' World',
            };
            yield runFinished();
          },
        ),
      );

      await client.append(userTurn('user-1', 'Hello'));

      expect(receivedSignal, isNotNull);
      expect(receivedSignal!.isCancelled, isFalse);
      expect(receivedSignal!.isAborted, isFalse);
      await client.dispose();
    });

    test('should abort request when stop() is called', () async {
      final controller = StreamController<Map<String, dynamic>>();
      CancellationSignal? receivedSignal;
      final client = ChatClient(
        connection: ConnectionAdapter(
          connect: (messages, {data, signal, runContext}) {
            receivedSignal = signal;
            return controller.stream;
          },
        ),
      );

      final append = client.append(userTurn('user-1', 'Hello'));
      await waitFor(() => receivedSignal != null);
      controller.add(<String, dynamic>{
        'type': 'TEXT_MESSAGE_CONTENT',
        'messageId': '1',
        'timestamp': 1,
        'delta': 'Hello',
      });
      await Future<void>.delayed(Duration.zero);

      await client.stop();
      await append;

      expect(receivedSignal!.isCancelled, isTrue);
      expect(client.getIsLoading(), isFalse);
      await controller.close();
      await client.dispose();
    });

    test('should preserve partial content when aborted', () async {
      final controller = StreamController<Map<String, dynamic>>();
      CancellationSignal? receivedSignal;
      final chunks = <Map<String, dynamic>>[];
      final client = ChatClient(
        connection: ConnectionAdapter(
          connect: (messages, {data, signal, runContext}) {
            receivedSignal = signal;
            return controller.stream;
          },
        ),
        onChunk: chunks.add,
      );

      final append = client.append(userTurn('user-1', 'Hello'));
      await waitFor(() => receivedSignal != null);
      controller.add(<String, dynamic>{
        'type': 'TEXT_MESSAGE_CONTENT',
        'messageId': '1',
        'timestamp': 1,
        'delta': 'Hello',
      });
      await waitFor(() => chunks.isNotEmpty);

      await client.stop();
      await append;

      expect(chunks, isNotEmpty);
      expect(client.getMessages(), isNotEmpty);
      expect(client.getIsLoading(), isFalse);
      await controller.close();
      await client.dispose();
    });

    test('should handle abort gracefully without throwing error', () async {
      final controller = StreamController<Map<String, dynamic>>();
      CancellationSignal? receivedSignal;
      final errors = <Object>[];
      final client = ChatClient(
        connection: ConnectionAdapter(
          connect: (messages, {data, signal, runContext}) {
            receivedSignal = signal;
            return controller.stream;
          },
        ),
        onError: (error, _) => errors.add(error),
      );

      final append = client.append(userTurn('user-1', 'Hello'));
      await waitFor(() => receivedSignal != null);
      controller.add(<String, dynamic>{
        'type': 'TEXT_MESSAGE_CONTENT',
        'messageId': '1',
        'timestamp': 1,
        'delta': 'Hello',
      });
      await Future<void>.delayed(Duration.zero);

      await client.stop();
      await append;

      expect(errors, isEmpty);
      expect(client.getError(), isNull);
      await controller.close();
      await client.dispose();
    });

    test('should set isLoading to false after abort', () async {
      final controller = StreamController<Map<String, dynamic>>();
      CancellationSignal? receivedSignal;
      final client = ChatClient(
        connection: ConnectionAdapter(
          connect: (messages, {data, signal, runContext}) {
            receivedSignal = signal;
            return controller.stream;
          },
        ),
      );

      final append = client.append(userTurn('user-1', 'Hello'));
      expect(client.getIsLoading(), isTrue);
      await waitFor(() => receivedSignal != null);
      controller.add(<String, dynamic>{
        'type': 'TEXT_MESSAGE_CONTENT',
        'messageId': '1',
        'timestamp': 1,
        'delta': 'Hello',
      });
      await Future<void>.delayed(Duration.zero);

      await client.stop();
      await append;

      expect(client.getIsLoading(), isFalse);
      await controller.close();
      await client.dispose();
    });

    test('should create new AbortController for each request', () async {
      final signals = <CancellationSignal?>[];
      final client = ChatClient(
        connection: ConnectionAdapter(
          connect: (messages, {data, signal, runContext}) async* {
            signals.add(signal);
            yield runFinished();
          },
        ),
      );

      await client.append(userTurn('user-1', 'Hello 1'));
      await client.append(userTurn('user-2', 'Hello 2'));

      expect(signals, hasLength(2));
      expect(identical(signals[0], signals[1]), isFalse);
      expect(signals[0]!.isCancelled, isFalse);
      expect(signals[1]!.isCancelled, isFalse);
      await client.dispose();
    });

    test('should resolve cleanly when stop() is called during onResponse',
        () async {
      var connectCalled = false;
      final errors = <Object>[];
      late ChatClient client;
      client = ChatClient(
        connection: ConnectionAdapter(
          connect: (messages, {data, signal, runContext}) async* {
            connectCalled = true;
            yield runFinished();
          },
        ),
        onError: (error, _) => errors.add(error),
        onResponse: () {
          unawaited(client.stop());
        },
      );

      await client.append(userTurn('user-1', 'Hello'));

      expect(connectCalled, isFalse);
      expect(errors, isEmpty);
      expect(client.getError(), isNull);
      expect(client.getIsLoading(), isFalse);
      await client.dispose();
    });

    test(
        'should resolve cleanly when reload() supersedes the stream during '
        'onResponse', () async {
      final signals = <CancellationSignal?>[];
      final errors = <Object>[];
      Future<void>? reloadPromise;
      var firstCall = true;
      late ChatClient client;
      client = ChatClient(
        connection: ConnectionAdapter(
          connect: (messages, {data, signal, runContext}) async* {
            signals.add(signal);
            yield runFinished();
          },
        ),
        onError: (error, _) => errors.add(error),
        onResponse: () {
          if (firstCall) {
            firstCall = false;
            reloadPromise = client.reload();
          }
        },
      );

      await client.append(userTurn('user-1', 'Hello'));
      await reloadPromise;

      expect(signals, hasLength(1));
      expect(signals.single, isNotNull);
      expect(signals.single!.isCancelled, isFalse);
      expect(errors, isEmpty);
      expect(client.getError(), isNull);
      await client.dispose();
    });
  });

  // -------------------------------------------------------------------------
  // (2) sse-parser-cleanup.test.ts through GenerationClient
  // -------------------------------------------------------------------------

  group('GenerationClient SSE response cleanup', () {
    for (final behavior in <String>[
      'resolves',
      'throws',
      'rejects',
      'never settles',
    ]) {
      test(
          'cancels a generation response on early return when cancellation '
          '$behavior', () async {
        final body = CancelableResponseBody(
          'data: ${jsonEncode(<String, dynamic>{
                'type': 'RUN_STARTED',
                'threadId': 'thread',
                'runId': 'run',
              })}\n\n',
          behavior,
        );
        final client = GenerationClient<Map<String, dynamic>, Object?, Object?>(
          fetcher: (input, options) async =>
              http.StreamedResponse(body.stream, 200),
        );

        final generate = client.generate(<String, dynamic>{});
        await waitFor(() => body.listenCalls > 0);
        await Future<void>.delayed(Duration.zero);
        client.stop();
        await generate.timeout(const Duration(seconds: 2));

        expect(body.cancelCalls, 1);
        expect(body.hasListener, isFalse);
        expect(client.getIsLoading(), isFalse);
        client.dispose();
        unawaited(body.close());
      });
    }

    test('reports a generation error without waiting for custom cancellation',
        () async {
      final body = CancelableResponseBody(
        'data: {"type":"RUN_ERROR","message":"generation failed"}\n\n',
        'never settles',
      );
      final client = GenerationClient<Map<String, dynamic>, Object?, Object?>(
        fetcher: (input, options) async =>
            http.StreamedResponse(body.stream, 200),
      );

      await client.generate(<String, dynamic>{}).timeout(
        const Duration(seconds: 2),
      );

      expect(generationErrorMessage(client.getError()),
          contains('generation failed'));
      expect(client.getIsLoading(), isFalse);
      expect(body.cancelCalls, 1);
      expect(body.hasListener, isFalse);
      client.dispose();
      unawaited(body.close());
    });

    test('preserves generation reader errors and releases the lock', () async {
      final body = CancelableResponseBody.error(
        StateError('response reader failed'),
      );
      final client = GenerationClient<Map<String, dynamic>, Object?, Object?>(
        fetcher: (input, options) async =>
            http.StreamedResponse(body.stream, 200),
      );

      await client.generate(<String, dynamic>{}).timeout(
        const Duration(seconds: 2),
      );

      expect(generationErrorMessage(client.getError()),
          contains('response reader failed'));
      expect(client.getIsLoading(), isFalse);
      expect(body.hasListener, isFalse);
      client.dispose();
      unawaited(body.close());
    });

    test(
        'drains generation EOF and keeps ignoring malformed JSON and DONE '
        'markers', () async {
      final body = CancelableResponseBody(
        'data: {invalid json}\n\ndata: [DONE]\n\n'
            'data: ${jsonEncode(<String, dynamic>{
              'type': 'RUN_FINISHED',
              'runId': 'run',
              'threadId': 'thread',
              'timestamp': 1,
              'metadata': <String, dynamic>{
                'tanstack': <String, dynamic>{'finishReason': 'stop'},
              },
            })}\n\n',
        'resolves',
        closeAfterWrite: true,
      );
      final chunks = <Map<String, dynamic>>[];
      final client = GenerationClient<Map<String, dynamic>, Object?, Object?>(
        fetcher: (input, options) async =>
            http.StreamedResponse(body.stream, 200),
        onChunk: chunks.add,
      );

      await client.generate(<String, dynamic>{}).timeout(
        const Duration(seconds: 2),
      );

      expect(body.listenCalls, 1);
      expect(chunks.map((chunk) => chunk['type']), contains('RUN_FINISHED'));
      expect(client.getStatus(), GenerationClientState.success);
      expect(client.getError(), isNull);
      expect(client.getIsLoading(), isFalse);
      // Dart invokes StreamController.onCancel on natural completion too.
      // Unlike a JS reader.cancel call, this alone does not mean early abort.
      expect(body.cancelCalls, 1);
      expect(body.hasListener, isFalse);
      client.dispose();
      unawaited(body.close());
    });
  });

  // -------------------------------------------------------------------------
  // (3) activity messages from chat-client.test.ts
  // -------------------------------------------------------------------------

  group('ChatClient activity messages', () {
    test('surfaces ACTIVITY_SNAPSHOT and ACTIVITY_DELTA through getMessages',
        () async {
      final onMessagesChange = <List<AssistantTurn>>[];
      final client = ChatClient(
        connection: ConnectionAdapter(
          connect: (messages, {data, signal, runContext}) async* {
            yield <String, dynamic>{
              'type': 'ACTIVITY_SNAPSHOT',
              'messageId': 'act-1',
              'activityType': 'SEARCH',
              'content': <String, dynamic>{'query': 'tanstack'},
              'timestamp': 1,
            };
            yield <String, dynamic>{
              'type': 'ACTIVITY_DELTA',
              'messageId': 'act-1',
              'activityType': 'SEARCH',
              'patch': <Map<String, dynamic>>[
                <String, dynamic>{
                  'op': 'add',
                  'path': '/hits',
                  'value': 3,
                },
              ],
              'timestamp': 1,
            };
            for (final chunk in textRun('done', messageId: 'asst-1')) {
              yield chunk;
            }
          },
        ),
        onMessagesChange: onMessagesChange.add,
      );

      await client.sendMessage('search');

      final activity =
          client.getMessages().firstWhere((m) => m.role == 'activity');
      expect(activity.id, 'act-1');
      expect(activity.parts.first.type, 'activity');
      expect(activity.parts.first.activityType, 'SEARCH');
      expect(activity.parts.first.activityContent,
          <String, dynamic>{'query': 'tanstack', 'hits': 3});
      expect(
        client.getMessages().any((m) => m.role == 'assistant'),
        isTrue,
      );
      expect(
        onMessagesChange.any(
          (batch) => batch.any((m) => m.role == 'activity'),
        ),
        isTrue,
      );
      await client.dispose();
    });

    test('does not send activity messages as model input on the next turn',
        () async {
      final sent = <List<Map<String, dynamic>>>[];
      final client = ChatClient(
        connection: ConnectionAdapter(
          connect: (messages, {data, signal, runContext}) async* {
            sent.add(messages);
            yield <String, dynamic>{
              'type': 'ACTIVITY_SNAPSHOT',
              'messageId': 'act-1',
              'activityType': 'SEARCH',
              'content': <String, dynamic>{'query': 'x'},
              'timestamp': 1,
            };
            for (final chunk in textRun('ok', messageId: 'asst-1')) {
              yield chunk;
            }
          },
        ),
      );

      await client.sendMessage('one');
      await client.sendMessage('two');

      expect(
        client.getMessages().any((m) => m.role == 'activity'),
        isTrue,
      );
      expect(sent.length, greaterThanOrEqualTo(2));
      expect(
        sent[1].any((message) => message['role'] == 'activity'),
        isFalse,
      );
      await client.dispose();
    });

    test('keeps an appended activity message without starting a run', () async {
      var connectCalls = 0;
      final client = ChatClient(
        connection: ConnectionAdapter(
          connect: (messages, {data, signal, runContext}) async* {
            connectCalls++;
            yield runFinished();
          },
        ),
      );

      await client.append(<String, dynamic>{
        'id': 'act-1',
        'role': 'activity',
        'parts': <Map<String, dynamic>>[
          <String, dynamic>{
            'type': 'activity',
            'activityType': 'PLAN',
            'content': <String, dynamic>{'steps': <Object?>[]},
          },
        ],
      });

      expect(connectCalls, 0);
      expect(client.getMessages().first.role, 'activity');
      expect(client.getMessages().first.id, 'act-1');
      expect(client.getMessages().first.parts.first.toJson(), {
        'type': 'activity',
        'activityType': 'PLAN',
        'content': <String, dynamic>{'steps': <Object?>[]},
      });
      await client.dispose();
    });

    test('exposes initial activity messages', () async {
      final client = ChatClient(
        connection: ConnectionAdapter(
          connect: (messages, {data, signal, runContext}) async* {
            yield runFinished();
          },
        ),
        initialMessages: <AssistantTurn>[
          AssistantTurn.activity(
            id: 'act-1',
            parts: <AssistantPart>[
              AssistantPart(
                type: 'activity',
                activityType: 'STATUS',
                activityContent: <String, dynamic>{'ok': true},
              ),
            ],
          ),
        ],
      );

      expect(client.getMessages().first.role, 'activity');
      expect(client.getMessages().first.id, 'act-1');
      await client.dispose();
    });

    test(
        'hydrates a mixed transcript from persistence and omits activity on '
        'send', () async {
      final sent = <List<Map<String, dynamic>>>[];
      final persistence = MemoryPersistence(
        ChatPersistedState(
          messages: <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'u1',
              'role': 'user',
              'parts': <Map<String, dynamic>>[
                <String, dynamic>{'type': 'text', 'content': 'hi'},
              ],
            },
            <String, dynamic>{
              'id': 'act-1',
              'role': 'activity',
              'parts': <Map<String, dynamic>>[
                <String, dynamic>{
                  'type': 'activity',
                  'activityType': 'SEARCH',
                  'content': <String, dynamic>{'query': 'tanstack'},
                },
              ],
            },
            <String, dynamic>{
              'id': 'a1',
              'role': 'assistant',
              'parts': <Map<String, dynamic>>[
                <String, dynamic>{'type': 'text', 'content': 'ok'},
              ],
            },
          ],
        ),
      );
      final client = ChatClient(
        connection: ConnectionAdapter(
          connect: (messages, {data, signal, runContext}) async* {
            sent.add(messages);
            for (final chunk in textRun('next answer')) {
              yield chunk;
            }
          },
        ),
        threadId: 'chat-1',
        persistence: persistence,
      );

      expect(
        client.getMessages().map((m) => m.role).toList(),
        <String>['user', 'activity', 'assistant'],
      );
      final activity = client.getMessages()[1];
      expect(activity.id, 'act-1');
      expect(activity.parts.first.toJson(), {
        'type': 'activity',
        'activityType': 'SEARCH',
        'content': <String, dynamic>{'query': 'tanstack'},
      });

      await client.sendMessage('next');
      expect(sent, hasLength(1));
      expect(
        sent.first.any((message) => message['role'] == 'activity'),
        isFalse,
      );
      await client.dispose();
    });

    test('keeps persisted activity when a later MESSAGES_SNAPSHOT omits it',
        () async {
      final persistence = MemoryPersistence(
        ChatPersistedState(
          messages: <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'u1',
              'role': 'user',
              'parts': <Map<String, dynamic>>[
                <String, dynamic>{'type': 'text', 'content': 'hi'},
              ],
            },
            <String, dynamic>{
              'id': 'act-1',
              'role': 'activity',
              'parts': <Map<String, dynamic>>[
                <String, dynamic>{
                  'type': 'activity',
                  'activityType': 'SEARCH',
                  'content': <String, dynamic>{'query': 'keep-me'},
                },
              ],
            },
            <String, dynamic>{
              'id': 'a1',
              'role': 'assistant',
              'parts': <Map<String, dynamic>>[
                <String, dynamic>{'type': 'text', 'content': 'ok'},
              ],
            },
          ],
        ),
      );
      final client = ChatClient(
        connection: ConnectionAdapter(
          connect: (messages, {data, signal, runContext}) async* {
            yield <String, dynamic>{
              'type': 'MESSAGES_SNAPSHOT',
              'messages': <Map<String, dynamic>>[
                <String, dynamic>{
                  'id': 'u1',
                  'role': 'user',
                  'content': 'hi',
                },
                <String, dynamic>{
                  'id': 'a1',
                  'role': 'assistant',
                  'content': 'ok',
                },
              ],
              'timestamp': 1,
            };
            for (final chunk in textRun('done', messageId: 'asst-1')) {
              yield chunk;
            }
          },
        ),
        threadId: 'chat-1',
        persistence: persistence,
      );

      await client.sendMessage('next');

      final activity =
          client.getMessages().firstWhere((m) => m.role == 'activity');
      expect(activity.id, 'act-1');
      expect(activity.parts.first.type, 'activity');
      expect(activity.parts.first.activityContent,
          <String, dynamic>{'query': 'keep-me'});
      await client.dispose();
    });

    test('hydrates activity from an inbound MESSAGES_SNAPSHOT ActivityMessage',
        () async {
      final client = ChatClient(
        connection: ConnectionAdapter(
          connect: (messages, {data, signal, runContext}) async* {
            yield <String, dynamic>{
              'type': 'MESSAGES_SNAPSHOT',
              'messages': <Map<String, dynamic>>[
                <String, dynamic>{
                  'id': 'u1',
                  'role': 'user',
                  'content': 'hi',
                },
                <String, dynamic>{
                  'id': 'act-1',
                  'role': 'activity',
                  'activityType': 'SEARCH',
                  'content': <String, dynamic>{'query': 'tanstack'},
                },
                <String, dynamic>{
                  'id': 'a1',
                  'role': 'assistant',
                  'content': 'done',
                },
              ],
              'timestamp': 1,
            };
            for (final chunk in textRun('done', messageId: 'asst-1')) {
              yield chunk;
            }
          },
        ),
      );

      await client.sendMessage('hi');

      final activity =
          client.getMessages().firstWhere((m) => m.role == 'activity');
      expect(activity.id, 'act-1');
      expect(activity.parts.first.type, 'activity');
      expect(activity.parts.first.activityType, 'SEARCH');
      expect(activity.parts.first.activityContent,
          <String, dynamic>{'query': 'tanstack'});
      await client.dispose();
    });
  });

  // -------------------------------------------------------------------------
  // (4) multimodal source shapes from chat-client.test.ts
  // -------------------------------------------------------------------------

  group('ChatClient multimodal sendMessage', () {
    Future<List<Map<String, dynamic>>> captureParts(
      List<Map<String, dynamic>> parts,
    ) async {
      final sent = <List<Map<String, dynamic>>>[];
      final client = ChatClient(
        connection: ConnectionAdapter(
          connect: (messages, {data, signal, runContext}) async* {
            sent.add(messages);
            for (final chunk in textRun('response')) {
              yield chunk;
            }
          },
        ),
      );

      await client.sendMessage(<String, dynamic>{'content': parts});
      expect(sent, hasLength(1));
      final user = sent.single.firstWhere(
        (message) => message['role'] == 'user',
      );
      final wireParts = (user['parts'] as List)
          .whereType<Map>()
          .map((part) => Map<String, dynamic>.from(part))
          .toList();
      await client.dispose();
      return wireParts;
    }

    test('should send a multimodal message with image content', () async {
      final wireParts = await captureParts(<Map<String, dynamic>>[
        <String, dynamic>{'type': 'text', 'content': 'What is in this image?'},
        <String, dynamic>{
          'type': 'image',
          'source': <String, dynamic>{
            'type': 'url',
            'value': 'https://example.com/cat.jpg',
          },
        },
      ]);

      expect(wireParts, <Map<String, dynamic>>[
        <String, dynamic>{'type': 'text', 'content': 'What is in this image?'},
        <String, dynamic>{
          'type': 'image',
          'source': <String, dynamic>{
            'type': 'url',
            'value': 'https://example.com/cat.jpg',
          },
        },
      ]);
    });

    test('should send a multimodal message with audio content', () async {
      final wireParts = await captureParts(<Map<String, dynamic>>[
        <String, dynamic>{'type': 'text', 'content': 'Transcribe this audio'},
        <String, dynamic>{
          'type': 'audio',
          'source': <String, dynamic>{
            'type': 'data',
            'value': 'base64AudioData',
            'mimeType': 'audio/mp3',
          },
        },
      ]);

      expect(wireParts, <Map<String, dynamic>>[
        <String, dynamic>{'type': 'text', 'content': 'Transcribe this audio'},
        <String, dynamic>{
          'type': 'audio',
          'source': <String, dynamic>{
            'type': 'data',
            'value': 'base64AudioData',
            'mimeType': 'audio/mp3',
          },
        },
      ]);
    });

    test('should send a multimodal message with video content', () async {
      final wireParts = await captureParts(<Map<String, dynamic>>[
        <String, dynamic>{'type': 'text', 'content': 'Describe this video'},
        <String, dynamic>{
          'type': 'video',
          'source': <String, dynamic>{
            'type': 'url',
            'value': 'https://example.com/video.mp4',
          },
        },
      ]);

      expect(wireParts, <Map<String, dynamic>>[
        <String, dynamic>{'type': 'text', 'content': 'Describe this video'},
        <String, dynamic>{
          'type': 'video',
          'source': <String, dynamic>{
            'type': 'url',
            'value': 'https://example.com/video.mp4',
          },
        },
      ]);
    });

    test('should send a multimodal message with document content', () async {
      final wireParts = await captureParts(<Map<String, dynamic>>[
        <String, dynamic>{'type': 'text', 'content': 'Summarize this PDF'},
        <String, dynamic>{
          'type': 'document',
          'source': <String, dynamic>{
            'type': 'data',
            'value': 'base64PdfData',
            'mimeType': 'application/pdf',
          },
        },
      ]);

      expect(wireParts, <Map<String, dynamic>>[
        <String, dynamic>{'type': 'text', 'content': 'Summarize this PDF'},
        <String, dynamic>{
          'type': 'document',
          'source': <String, dynamic>{
            'type': 'data',
            'value': 'base64PdfData',
            'mimeType': 'application/pdf',
          },
        },
      ]);
    });
  });

  // -------------------------------------------------------------------------
  // (5) append from chat-client.test.ts
  // -------------------------------------------------------------------------

  group('ChatClient append', () {
    test('should append a UIMessage', () async {
      final client = ChatClient(
        connection: ConnectionAdapter(
          connect: (messages, {data, signal, runContext}) async* {
            for (final chunk in textRun('Response')) {
              yield chunk;
            }
          },
        ),
      );
      final createdAt = DateTime.utc(2024, 5, 1);

      await client.append(<String, dynamic>{
        'id': 'user-1',
        'role': 'user',
        'parts': <Map<String, dynamic>>[
          <String, dynamic>{'type': 'text', 'content': 'Hello'},
        ],
        'createdAt': createdAt.toIso8601String(),
      });

      expect(client.getMessages(), isNotEmpty);
      expect(client.getMessages().first.id, 'user-1');
      expect(client.getMessages().first.createdAt, createdAt);
      await client.dispose();
    });

    test('should convert and append a ModelMessage', () async {
      final client = ChatClient(
        connection: ConnectionAdapter(
          connect: (messages, {data, signal, runContext}) async* {
            for (final chunk in textRun('Response')) {
              yield chunk;
            }
          },
        ),
      );

      await client.append(<String, dynamic>{
        'role': 'user',
        'content': 'Hello from model',
      });

      final user = client.getMessages().first;
      expect(user.role, 'user');
      expect(user.parts.first.toJson(), {
        'type': 'text',
        'content': 'Hello from model',
      });
      expect(user.id, isNotEmpty);
      expect(user.createdAt, isNotNull);
      await client.dispose();
    });

    test('should generate id and createdAt if missing', () async {
      final client = ChatClient(
        connection: ConnectionAdapter(
          connect: (messages, {data, signal, runContext}) async* {
            for (final chunk in textRun('Response')) {
              yield chunk;
            }
          },
        ),
      );

      await client.append(<String, dynamic>{
        'id': '',
        'role': 'user',
        'parts': <Map<String, dynamic>>[
          <String, dynamic>{'type': 'text', 'content': 'Hello'},
        ],
      });

      final user = client.getMessages().first;
      expect(user.id, isNotEmpty);
      expect(user.createdAt, isNotNull);
      await client.dispose();
    });
  });
}

/// `http.StreamedResponse` body whose `onCancel` behaves like the upstream
/// `ReadableStream.cancel` variants.
class CancelableResponseBody {
  final String payload;
  final String behavior;
  final bool closeAfterWrite;
  late final StreamController<List<int>> _controller;
  int listenCalls = 0;
  int cancelCalls = 0;

  CancelableResponseBody(
    this.payload,
    this.behavior, {
    this.closeAfterWrite = false,
  }) {
    _controller = StreamController<List<int>>(
      onListen: () {
        listenCalls++;
        _controller.add(utf8.encode(payload));
        if (closeAfterWrite) {
          unawaited(_controller.close());
        }
      },
      onCancel: () {
        cancelCalls++;
        switch (behavior) {
          case 'throws':
            throw StateError('cleanup failed');
          case 'rejects':
            return Future<void>.error(StateError('cleanup failed'));
          case 'never settles':
            return Completer<void>().future;
          default:
            return null;
        }
      },
    );
  }

  CancelableResponseBody.error(Object error)
      : payload = '',
        behavior = 'error',
        closeAfterWrite = false {
    _controller = StreamController<List<int>>(
      onListen: () {
        listenCalls++;
        _controller.addError(error);
        _controller.close();
      },
    );
  }

  Stream<List<int>> get stream => _controller.stream;
  bool get hasListener => _controller.hasListener;
  Future<void> close() async {
    if (!_controller.isClosed) await _controller.close();
  }
}
