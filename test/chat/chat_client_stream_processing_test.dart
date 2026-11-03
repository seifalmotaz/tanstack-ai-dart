// Upstream reference: packages/ai-client/tests/chat-client-stream-processing.test.ts
import 'dart:async';

import 'package:tanstack_ai_dart/chat.dart';
import 'package:tanstack_ai_dart/connections.dart' as conn;
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('ChatClient stream processing', () {
    test('text and thinking stay separate; thinking never enters the answer',
        () async {
      final transport = FakeChatTransport();
      final client = ChatClient(transport: transport);
      await client.sendText('hi');
      await emitAll(transport, <Map<String, dynamic>>[
        <String, dynamic>{'type': 'RUN_STARTED', 'runId': 'run-1'},
        <String, dynamic>{'type': 'THINKING_TEXT_MESSAGE_START'},
        <String, dynamic>{
          'type': 'THINKING_TEXT_MESSAGE_CONTENT',
          'delta': 'secret plan',
        },
        <String, dynamic>{'type': 'TEXT_MESSAGE_START'},
        <String, dynamic>{'type': 'TEXT_MESSAGE_CONTENT', 'delta': 'answer'},
        <String, dynamic>{
          'type': 'RUN_FINISHED',
          'runId': 'run-1',
          'outcome': <String, dynamic>{'type': 'success'},
        },
      ]);
      await transport.close();
      await pump();
      final assistant = client.getMessages().last;
      expect(assistant.answer, 'answer');
      expect(assistant.thoughts.single.content, 'secret plan');
    });

    test('restores finishReason and model onto onChunk RUN_FINISHED', () async {
      final transport = FakeChatTransport();
      final chunks = <Map<String, dynamic>>[];
      final finished = <Map<String, dynamic>>[];
      final client = ChatClient(
        transport: transport,
        onChunk: chunks.add,
        onFinish: finished.add,
      );
      await client.sendText('hi');
      await emitAll(transport, <Map<String, dynamic>>[
        <String, dynamic>{'type': 'RUN_STARTED', 'runId': 'run-1'},
        <String, dynamic>{'type': 'TEXT_MESSAGE_CONTENT', 'delta': 'x'},
        <String, dynamic>{
          'type': 'RUN_FINISHED',
          'runId': 'run-1',
          'outcome': <String, dynamic>{'type': 'success'},
          'metadata': <String, dynamic>{
            'tanstack': <String, dynamic>{
              'finishReason': 'stop',
              'model': 'test-model',
            },
          },
        },
      ]);
      await transport.close();
      await pump();
      final terminal = chunks.lastWhere((c) => c['type'] == 'RUN_FINISHED');
      expect(terminal['finishReason'], 'stop');
      expect(terminal['model'], 'test-model');
      expect(finished.single['finishReason'], 'stop');
      expect(finished.single['model'], 'test-model');
    });

    test('preserves distinct MESSAGES_SNAPSHOT message ids', () async {
      final transport = FakeChatTransport();
      final client = ChatClient(transport: transport);
      await client.sendText('hi');
      transport.emit(<String, dynamic>{
        'type': 'MESSAGES_SNAPSHOT',
        'messages': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'u1',
            'role': 'user',
            'parts': <Map<String, dynamic>>[
              <String, dynamic>{'type': 'text', 'content': 'hi'},
            ],
          },
          <String, dynamic>{
            'id': 'a1',
            'role': 'assistant',
            'parts': <Map<String, dynamic>>[
              <String, dynamic>{'type': 'text', 'content': 'one'},
            ],
          },
          <String, dynamic>{
            'id': 'a2',
            'role': 'assistant',
            'parts': <Map<String, dynamic>>[
              <String, dynamic>{'type': 'text', 'content': 'two'},
            ],
          },
        ],
      });
      await pump();
      expect(client.getMessages().map((m) => m.id), <String>['u1', 'a1', 'a2']);
      expect(client.getMessages().map((m) => m.answer),
          <String>['hi', 'one', 'two']);
      await client.stop();
    });

    test('surfaces ACTIVITY_SNAPSHOT and ACTIVITY_DELTA parts', () async {
      final transport = FakeChatTransport();
      final client = ChatClient(transport: transport);
      await client.sendText('hi');
      transport.emit(<String, dynamic>{
        'type': 'ACTIVITY_SNAPSHOT',
        'messageId': 'act-1',
        'activityType': 'SEARCH',
        'content': <String, dynamic>{
          'query': 'tanstack',
        },
      });
      transport.emit(<String, dynamic>{
        'type': 'ACTIVITY_DELTA',
        'messageId': 'act-1',
        'activityType': 'SEARCH',
        'patch': <Map<String, dynamic>>[
          <String, dynamic>{
            'op': 'add',
            'path': '/status',
            'value': 'done',
          },
        ],
      });
      await pump();
      final activity = client
          .getMessages()
          .expand((m) => m.parts)
          .firstWhere((p) => p.type == 'activity');
      expect(activity.activityType, 'SEARCH');
      expect(activity.activityContent, <String, dynamic>{
        'query': 'tanstack',
        'status': 'done',
      });
      await client.stop();
    });

    test('does not duplicate an assistant message on reconnect content arrival',
        () async {
      final transport = FakeChatTransport();
      final client = ChatClient(
        transport: transport,
        messages: <AssistantTurn>[
          AssistantTurn(
            id: 'a1',
            role: 'assistant',
            parts: <AssistantPart>[AssistantPart.text('existing')],
          ),
        ],
      );
      await client.sendText('hi');
      transport.emit(<String, dynamic>{
        'type': 'TEXT_MESSAGE_CONTENT',
        'messageId': 'a1',
        'delta': ' more',
      });
      await transport.close();
      await pump();
      expect(
        client.getMessages().where((m) => m.role == 'assistant').length,
        2,
      );
      expect(client.getMessages().last.answer, 'more');
      await client.stop();
    });

    test('passes runtime context to custom events without serializing it',
        () async {
      final transport = FakeChatTransport();
      Object? seenContext;
      final client = ChatClient(
        transport: transport,
        context: <String, dynamic>{'tenant': 'acme'},
        onCustomEvent: (event, context) => seenContext = context,
      );
      await client.sendText('hi');
      transport.emit(<String, dynamic>{
        'type': 'CUSTOM',
        'name': 'analytics',
        'value': <String, dynamic>{'n': 1},
      });
      await pump();
      expect(seenContext, <String, dynamic>{'tenant': 'acme'});
      await client.stop();
    });

    test('reasoning replay keeps signed thinking out of the answer text',
        () async {
      final transport = FakeChatTransport();
      final client = ChatClient(transport: transport);
      await client.sendText('hi');
      await emitAll(transport, <Map<String, dynamic>>[
        <String, dynamic>{'type': 'RUN_STARTED', 'runId': 'run-1'},
        <String, dynamic>{'type': 'REASONING_START', 'messageId': 'r1'},
        <String, dynamic>{
          'type': 'REASONING_MESSAGE_START',
          'messageId': 'r1',
          'role': 'reasoning',
        },
        <String, dynamic>{
          'type': 'REASONING_MESSAGE_CONTENT',
          'messageId': 'r1',
          'delta': 'checked pipeline',
        },
        <String, dynamic>{
          'type': 'REASONING_ENCRYPTED_VALUE',
          'subtype': 'signature',
          'entityId': 'r1',
          'encryptedValue': 'signed',
        },
        <String, dynamic>{'type': 'REASONING_MESSAGE_END', 'messageId': 'r1'},
        <String, dynamic>{'type': 'REASONING_END', 'messageId': 'r1'},
        <String, dynamic>{'type': 'TEXT_MESSAGE_START', 'messageId': 'm1'},
        <String, dynamic>{
          'type': 'TEXT_MESSAGE_CONTENT',
          'messageId': 'm1',
          'delta': 'answer',
        },
        <String, dynamic>{
          'type': 'RUN_FINISHED',
          'runId': 'run-1',
          'outcome': <String, dynamic>{'type': 'success'},
        },
      ]);
      await transport.close();
      await pump();
      final assistant = client.getMessages().last;
      expect(assistant.answer, 'answer');
      expect(assistant.thoughts.single.content, 'checked pipeline');
    });

    test(
        'a throwing listener does not break stream processing or other listeners',
        () async {
      final transport = FakeChatTransport();
      var second = 0;
      final client = ChatClient(
        transport: transport,
        onChanged: () => throw StateError('listener failed'),
      );
      client.subscribeSnapshot(() => second++);
      await client.sendText('hi');
      await emitAll(transport, textChunks('ok'));
      await transport.close();
      await pump();
      expect(second, greaterThan(0));
      expect(client.getMessages().last.answer, 'ok');
    });
  });

  // The upstream cases stub `performance.now()`, `scheduler.yield` and
  // `document.hidden`. Those browser APIs do not exist on the Dart VM, so
  // these cases assert the equivalent observable contract: chunks are handled
  // as they arrive, the event loop stays fair, and timers are not blocked.
  group('ChatClient stream processing — Dart event-loop equivalents', () {
    test('does not require a macrotask between chunks in one batch', () async {
      var macrotaskRan = false;
      final timer = Timer(Duration.zero, () => macrotaskRan = true);
      final client = ChatClient(
        processingScheduler: StreamProcessingScheduler(now: () => 0),
        connection: conn.ConnectionAdapter(
          connect: (messages, {data, signal, runContext}) async* {
            yield* Stream<Map<String, dynamic>>.fromIterable(
              textChunks('ab'),
            );
          },
        ),
      );

      await client.sendText('Hi');
      timer.cancel();

      expect(macrotaskRan, isFalse);
      expect(client.getMessages().last.answer, 'ab');
      await client.dispose();
    });

    test('lets queued timers run while a delayed stream is processed',
        () async {
      var ticks = 0;
      final timer = Timer.periodic(
        const Duration(milliseconds: 1),
        (_) => ticks++,
      );
      final client = ChatClient(
        connection: conn.ConnectionAdapter(
          connect: (messages, {data, signal, runContext}) async* {
            yield <String, dynamic>{'type': 'RUN_STARTED', 'runId': 'r'};
            for (var i = 0; i < 20; i++) {
              await Future<void>.delayed(const Duration(milliseconds: 1));
              yield <String, dynamic>{
                'type': 'TEXT_MESSAGE_CONTENT',
                'messageId': 'm',
                'delta': '$i',
              };
            }
            yield <String, dynamic>{
              'type': 'RUN_FINISHED',
              'runId': 'r',
              'threadId': 't',
              'outcome': <String, dynamic>{'type': 'success'},
            };
          },
        ),
      );

      await client.sendText('Hi');
      timer.cancel();

      expect(ticks, greaterThan(0));
      expect(
          client.getMessages().last.answer, '012345678910111213141516171819');
      await client.dispose();
    });

    test('keeps chunk order when timers interleave with delivery', () async {
      final deltas = <String>[];
      final client = ChatClient(
        connection: conn.ConnectionAdapter(
          connect: (messages, {data, signal, runContext}) async* {
            for (final delta in <String>['a', 'b', 'c']) {
              await Future<void>.delayed(const Duration(milliseconds: 1));
              yield <String, dynamic>{
                'type': 'TEXT_MESSAGE_CONTENT',
                'messageId': 'm',
                'delta': delta,
              };
            }
            yield <String, dynamic>{
              'type': 'RUN_FINISHED',
              'runId': 'r',
              'threadId': 't',
              'outcome': <String, dynamic>{'type': 'success'},
            };
          },
        ),
        onChunk: (chunk) {
          if (chunk['type'] == 'TEXT_MESSAGE_CONTENT') {
            deltas.add('${chunk['delta']}');
          }
        },
      );

      await client.sendText('Hi');

      expect(deltas, <String>['a', 'b', 'c']);
      await client.dispose();
    });

    test('processes a synchronous burst without dropping chunks', () async {
      final client = ChatClient(
        connection: conn.ConnectionAdapter(
          connect: (messages, {data, signal, runContext}) async* {
            yield <String, dynamic>{'type': 'RUN_STARTED', 'runId': 'r'};
            for (var i = 0; i < 500; i++) {
              yield <String, dynamic>{
                'type': 'TEXT_MESSAGE_CONTENT',
                'messageId': 'm',
                'delta': 'x',
              };
            }
            yield <String, dynamic>{
              'type': 'RUN_FINISHED',
              'runId': 'r',
              'threadId': 't',
              'outcome': <String, dynamic>{'type': 'success'},
            };
          },
        ),
      );

      await client.sendText('Hi');

      expect(client.getMessages().last.answer, 'x' * 500);
      await client.dispose();
    });
  });
}
