// Upstream reference: packages/ai-client/tests/chat-client.test.ts
// Each test keeps the upstream scenario name and asserts the observable
// contract through the Dart ChatClient surface.
import 'dart:async';

import 'package:tanstack_ai_dart/chat.dart';
import 'package:test/test.dart';

import 'support.dart';

ChatClient persistedClient(
  FakeChatTransport transport, {
  List<AssistantTurn>? initial,
  ChatPersistence? persistence,
  String threadId = 't1',
}) =>
    ChatClient(
      transport: transport,
      messages: initial,
      options: ChatClientOptions(
        threadId: threadId,
        persistence: persistence,
      ),
    );

Future<void> settle(FakeChatTransport transport) async {
  await pump();
  if (transport.controllers.isNotEmpty &&
      !transport.controllers.last.isClosed) {
    await transport.close();
  }
  await pump();
}

void main() {
  group('ChatClient constructor', () {
    test('should hydrate messages from persistence', () async {
      final stored = <AssistantTurn>[userMessage('p1', 'Persisted hello')];
      final client = persistedClient(
        FakeChatTransport(),
        persistence: ChatPersistence(getItem: () => stored),
      );
      await client.attach();
      expect(client.getMessages().single.id, 'p1');
    });

    test('should hydrate messages from persistence.client', () async {
      final stored = <AssistantTurn>[userMessage('p2', 'Stored')];
      final client = persistedClient(
        FakeChatTransport(),
        persistence: ChatPersistence(getItem: () async => stored),
      );
      await client.attach();
      expect(client.getMessages().single.answer, 'Stored');
    });

    test('should prefer persisted messages over initial messages', () async {
      final client = persistedClient(
        FakeChatTransport(),
        initial: <AssistantTurn>[userMessage('initial', 'Initial')],
        persistence: ChatPersistence(
          getItem: () => <AssistantTurn>[userMessage('persisted', 'Persisted')],
        ),
      );
      await client.attach();
      expect(client.getMessages().single.id, 'persisted');
    });

    test('should fall back to initial messages when persistence returns null',
        () async {
      final client = persistedClient(
        FakeChatTransport(),
        initial: <AssistantTurn>[userMessage('initial', 'Initial')],
        persistence: ChatPersistence(getItem: () => null),
      );
      await client.attach();
      expect(client.getMessages().single.id, 'initial');
    });

    test(
        'should fall back to initial messages when persistence returns undefined',
        () async {
      final client = persistedClient(
        FakeChatTransport(),
        initial: <AssistantTurn>[userMessage('initial', 'Initial')],
        persistence: ChatPersistence(),
      );
      await client.attach();
      expect(client.getMessages().single.id, 'initial');
    });

    test('should let persisted empty arrays override initial messages',
        () async {
      final client = persistedClient(
        FakeChatTransport(),
        initial: <AssistantTurn>[userMessage('initial', 'Initial')],
        persistence: ChatPersistence(
          getItem: () => const <AssistantTurn>[],
        ),
      );
      await client.attach();
      expect(client.getMessages(), isEmpty);
    });

    test('should hydrate from async persistence and notify message listeners',
        () async {
      final gate = Completer<List<AssistantTurn>?>();
      final client = persistedClient(
        FakeChatTransport(),
        persistence: ChatPersistence(getItem: () => gate.future),
      );
      var calls = 0;
      client.subscribeSnapshot(() => calls++);
      final attaching = client.attach();
      gate.complete(<AssistantTurn>[userMessage('p3', 'Async')]);
      await attaching;
      expect(client.getMessages().single.id, 'p3');
      expect(calls, greaterThan(0));
    });

    test(
        'should ignore async persistence hydration after local message changes',
        () async {
      final gate = Completer<List<AssistantTurn>?>();
      final client = persistedClient(
        FakeChatTransport(),
        persistence: ChatPersistence(getItem: () => gate.future),
      );
      final attaching = client.attach();
      client
          .setMessagesManually(<AssistantTurn>[userMessage('local', 'Local')]);
      gate.complete(<AssistantTurn>[userMessage('late', 'Late')]);
      await attaching;
      expect(client.getMessages().single.id, 'local');
    });

    test('should keep current constructor behavior when persistence is omitted',
        () {
      final initial = <AssistantTurn>[userMessage('i', 'Initial')];
      final client =
          ChatClient(transport: FakeChatTransport(), messages: initial);
      expect(client.getMessages(), same(initial));
    });

    test('should throw if neither connection nor fetcher is provided', () {
      expect(() => ChatClient(), throwsA(anything));
    });
  });

  group('ChatClient sendMessage', () {
    test('should create and return assistant message from stream chunks',
        () async {
      final transport = FakeChatTransport();
      final client = ChatClient(transport: transport);
      await client.sendText('Hello');
      await emitAll(transport, textChunks('world'));
      await settle(transport);
      expect(
          client.getMessages().firstWhere((m) => m.role == 'assistant').answer,
          'world');
    });
  });

  group('ChatClient append', () {
    test('should generate id and createdAt if missing', () async {
      final transport = FakeChatTransport();
      final client = ChatClient(transport: transport);
      await client.append(
        AssistantTurn(
          id: 'given',
          role: 'user',
          parts: <AssistantPart>[AssistantPart.text('x')],
        ),
      );
      expect(client.getMessages().first.id, 'given');
      expect(client.getMessages().first.createdAt, isNotNull);
      await client.stop();
    });

    test(
        'keeps append pending through an intermediate tool_calls RUN_FINISHED until the interrupt',
        () async {
      final transport = FakeChatTransport();
      final client = ChatClient(transport: transport);
      await client.append(userMessage('u1', 'hi'));
      await emitAll(transport, <Map<String, dynamic>>[
        <String, dynamic>{'type': 'RUN_STARTED', 'runId': 'r1'},
        <String, dynamic>{
          'type': 'TOOL_CALL_START',
          'toolCallId': 'tc1',
          'toolCallName': 'lookup',
        },
        <String, dynamic>{
          'type': 'TOOL_CALL_END',
          'toolCallId': 'tc1',
          'toolCallName': 'lookup',
          'input': <String, dynamic>{},
        },
        <String, dynamic>{
          'type': 'RUN_FINISHED',
          'runId': 'r1',
          'finishReason': 'tool_calls',
          'outcome': <String, dynamic>{'type': 'success'},
        },
        <String, dynamic>{
          'type': 'RUN_FINISHED',
          'runId': 'r2',
          'outcome': <String, dynamic>{
            'type': 'interrupt',
            'interrupts': <Map<String, dynamic>>[
              <String, dynamic>{
                'id': 'i1',
                'reason': 'approval_required',
                'toolCallId': 'tc1',
                'metadata': <String, dynamic>{
                  'kind': 'approval',
                  'toolName': 'lookup',
                  'input': <String, dynamic>{},
                },
              },
            ],
          },
        },
      ]);
      await transport.close();
      await pump();
      expect(client.getPendingInterrupts(), hasLength(1));
    });
  });

  group('ChatClient clear', () {
    test('should abort an in-flight stream when persistence is omitted',
        () async {
      final transport = FakeChatTransport();
      final client = ChatClient(transport: transport);
      await client.sendText('hi');
      await client.clear();
      expect(client.isStreaming, isFalse);
      expect(transport.controllers.single.hasListener, isFalse);
    });

    test(
        'should prevent delayed stream chunks from recreating messages after clear',
        () async {
      final transport = FakeChatTransport();
      final client = ChatClient(transport: transport);
      await client.sendText('hi');
      final hold = transport.controllers.last;
      await client.clear();
      hold.add(
          <String, dynamic>{'type': 'TEXT_MESSAGE_CONTENT', 'delta': 'late'});
      await pump();
      expect(client.getMessages(), isEmpty);
    });
  });

  group('ChatClient persistence write', () {
    test('should save message snapshots after sendMessage changes messages',
        () async {
      final saved = <List<AssistantTurn>>[];
      final transport = FakeChatTransport();
      final client = persistedClient(
        transport,
        persistence: ChatPersistence(setItem: saved.add),
      );
      await client.sendText('hello');
      await settle(transport);
      expect(saved, isNotEmpty);
      expect(saved.last.any((m) => m.role == 'user'), isTrue);
    });

    test('should save message snapshots when messages are set manually',
        () async {
      final saved = <List<AssistantTurn>>[];
      final client = persistedClient(
        FakeChatTransport(),
        persistence: ChatPersistence(setItem: saved.add),
      );
      client.setMessagesManually(<AssistantTurn>[userMessage('m', 'x')]);
      await pump();
      expect(saved, hasLength(1));
      expect(saved.single.single.id, 'm');
    });

    test('should swallow async persistence write and remove failures',
        () async {
      final client = persistedClient(
        FakeChatTransport(),
        persistence: ChatPersistence(
          setItem: (_) => throw StateError('write failed'),
          removeItem: () => throw StateError('remove failed'),
        ),
      );
      await client.sendText('x');
      await client.clear();
      expect(client.getError(), isNull);
    });
  });

  group('ChatClient callbacks', () {
    test('should call onMessagesChange when messages update', () async {
      final transport = FakeChatTransport();
      var calls = 0;
      final client = ChatClient(
        transport: transport,
        onMessagesChange: (_) => calls++,
      );
      await client.sendText('x');
      expect(calls, greaterThan(0));
      await client.stop();
    });

    test('should call onLoadingChange when loading state changes', () async {
      final transport = FakeChatTransport();
      final seen = <bool>[];
      final client = ChatClient(
        transport: transport,
        onLoadingChange: seen.add,
      );
      await client.sendText('x');
      await settle(transport);
      expect(seen, contains(true));
      expect(seen.last, isFalse);
    });

    test('should call onFinish when stream completes', () async {
      final transport = FakeChatTransport();
      final finished = <Map<String, dynamic>>[];
      final client = ChatClient(
        transport: transport,
        onFinish: finished.add,
      );
      await client.sendText('x');
      await emitAll(transport, textChunks('ok'));
      await settle(transport);
      expect(finished.single['type'], 'RUN_FINISHED');
    });

    test('should call onError when error occurs', () async {
      final transport = FakeChatTransport();
      final errors = <Object>[];
      final client = ChatClient(
        transport: transport,
        onError: (error, _) => errors.add(error),
      );
      await client.sendText('x');
      transport.emitError(StateError('boom'));
      await pump();
      expect(errors.single.toString(), contains('boom'));
    });
  });

  group('ChatClient tool calls', () {
    test('should handle tool calls from stream', () async {
      final transport = FakeChatTransport();
      final client = ChatClient(transport: transport);
      await client.sendText('x');
      await emitAll(transport, <Map<String, dynamic>>[
        <String, dynamic>{'type': 'RUN_STARTED', 'runId': 'r'},
        <String, dynamic>{
          'type': 'TOOL_CALL_START',
          'toolCallId': 'tc',
          'toolCallName': 'lookup',
        },
        <String, dynamic>{
          'type': 'TOOL_CALL_ARGS',
          'toolCallId': 'tc',
          'delta': '{"id":1}',
        },
        <String, dynamic>{
          'type': 'TOOL_CALL_END',
          'toolCallId': 'tc',
          'toolCallName': 'lookup',
        },
      ]);
      final tool = client
          .getMessages()
          .expand((m) => m.parts)
          .firstWhere((p) => p.type == 'tool-call');
      expect(tool.name, 'lookup');
      expect(tool.input, <String, dynamic>{'id': 1});
      await client.stop();
    });

    test('does not continue a server-owned client tool input error', () async {
      final transport = FakeChatTransport();
      final client = ChatClient(transport: transport);
      await client.sendText('x');
      await emitAll(transport, <Map<String, dynamic>>[
        <String, dynamic>{'type': 'RUN_STARTED', 'runId': 'r'},
        <String, dynamic>{
          'type': 'TOOL_CALL_START',
          'toolCallId': 'tc',
          'toolCallName': 'lookup',
        },
        <String, dynamic>{
          'type': 'TOOL_CALL_RESULT',
          'toolCallId': 'tc',
          'content': 'bad',
          'error': 'invalid',
        },
        <String, dynamic>{
          'type': 'RUN_FINISHED',
          'runId': 'r',
          'outcome': <String, dynamic>{'type': 'success'},
        },
      ]);
      await settle(transport);
      final tool = client
          .getMessages()
          .expand((m) => m.parts)
          .firstWhere((p) => p.type == 'tool-call');
      expect(tool.state, 'error');
      expect(transport.bodies, hasLength(1));
    });

    test('addToolResult should add tool result and update message', () async {
      final transport = FakeChatTransport();
      final client = ChatClient(
        transport: transport,
        messages: <AssistantTurn>[
          AssistantTurn(
            id: 'a',
            role: 'assistant',
            parts: <AssistantPart>[
              AssistantPart.tool(id: 'tc', name: 'lookup'),
            ],
          ),
        ],
      );
      await client
          .addToolResult(toolCallId: 'tc', output: <String, dynamic>{'x': 1});
      expect(client.getMessages().first.parts.first.output,
          <String, dynamic>{'x': 1});
      await client.stop();
    });
  });

  group('ChatClient error handling', () {
    test('should set error state on connection failure', () async {
      final transport = FakeChatTransport();
      final client = ChatClient(transport: transport);
      await client.sendText('x');
      transport.emitError(StateError('connection failed'));
      await pump();
      expect(client.getStatus(), 'error');
      expect(client.getError(), contains('connection failed'));
    });

    test('should not hang when connection is updated during an active stream',
        () async {
      final transport = FakeChatTransport();
      final client = ChatClient(transport: transport);
      await client.sendText('x');
      client.updateOptions(body: <String, dynamic>{'model': 'new'});
      expect(client.isStreaming, isTrue);
      await client.stop();
    });
  });

  group('ChatClient multimodal sendMessage', () {
    for (final entry in <String, Map<String, dynamic>>{
      'image': <String, dynamic>{
        'type': 'image',
        'source': <String, dynamic>{'type': 'url', 'value': 'https://x/a.png'},
      },
      'audio': <String, dynamic>{
        'type': 'audio',
        'source': <String, dynamic>{'type': 'url', 'value': 'https://x/a.wav'},
      },
      'video': <String, dynamic>{
        'type': 'video',
        'source': <String, dynamic>{'type': 'url', 'value': 'https://x/a.mp4'},
      },
      'document': <String, dynamic>{
        'type': 'document',
        'source': <String, dynamic>{'type': 'url', 'value': 'https://x/a.pdf'},
      },
    }.entries) {
      test('should send a multimodal message with ${entry.key} content',
          () async {
        final transport = FakeChatTransport();
        final client = ChatClient(transport: transport);
        await client.sendMessage(
          ChatMessageInput(
            content: <Map<String, dynamic>>[
              <String, dynamic>{'type': 'text', 'content': 'see'},
              entry.value,
            ],
          ),
        );
        final sent =
            (transport.bodies.single['messages'] as List).single as Map;
        expect((sent['parts'] as List).map((p) => (p as Map)['type']), <String>[
          'text',
          entry.key,
        ]);
        await client.stop();
      });
    }

    test('should use custom message id when provided', () async {
      final transport = FakeChatTransport();
      final client = ChatClient(transport: transport);
      await client.sendMessage(
        const ChatMessageInput(content: 'hi', id: 'custom'),
      );
      expect(client.getMessages().first.id, 'custom');
      await client.stop();
    });

    test('should generate message id when not provided', () async {
      final transport = FakeChatTransport();
      final client = ChatClient(transport: transport);
      await client.sendText('hi');
      expect(client.getMessages().first.id, isNotEmpty);
      await client.stop();
    });

    test('should allow empty content array', () async {
      final transport = FakeChatTransport();
      final client = ChatClient(transport: transport);
      await client.sendMessage(
        const ChatMessageInput(content: <Map<String, dynamic>>[]),
      );
      expect(client.getMessages().first.parts, isEmpty);
      await client.stop();
    });

    test('should send string content as simple text message', () async {
      final transport = FakeChatTransport();
      final client = ChatClient(transport: transport);
      await client.sendText('plain');
      final sent = (transport.bodies.single['messages'] as List).single as Map;
      expect((sent['parts'] as List).single, <String, dynamic>{
        'type': 'text',
        'content': 'plain',
      });
      await client.stop();
    });

    test('should merge per-message body with base body', () async {
      final transport = FakeChatTransport();
      final client = ChatClient(
        transport: transport,
        body: <String, dynamic>{'base': 1},
      );
      await client.sendMessage('x', body: <String, dynamic>{'extra': 2});
      final forwarded = transport.bodies.single['forwardedProps'] as Map;
      expect(forwarded['base'], 1);
      expect(forwarded['extra'], 2);
      await client.stop();
    });

    test(
        'should merge sendOptions.body into the request (hook-style per-call body)',
        () async {
      final transport = FakeChatTransport();
      final client = ChatClient(transport: transport);
      await client.sendText(
        'x',
        options:
            const ChatSendOptions(body: <String, dynamic>{'temperature': 1}),
      );
      expect(
        (transport.bodies.single['forwardedProps'] as Map)['temperature'],
        1,
      );
      await client.stop();
    });

    test('reload does not replay a previous per-call body', () async {
      final transport = FakeChatTransport();
      final client = ChatClient(
        transport: transport,
        messages: <AssistantTurn>[userMessage('u', 'hi')],
      );
      await client.sendMessage('x', body: <String, dynamic>{'temp': 1});
      await client.reload();
      final second = transport.bodies[1]['forwardedProps'] as Map?;
      expect(second?['temp'], isNull);
      await client.stop();
    });

    test('should accept forwardedProps option and merge into request body',
        () async {
      final transport = FakeChatTransport();
      final client = ChatClient(
        transport: transport,
        forwardedProps: <String, dynamic>{'fp': true},
      );
      await client.sendText('x');
      expect((transport.bodies.single['forwardedProps'] as Map)['fp'], isTrue);
      await client.stop();
    });

    test(
        'updateOptions({ forwardedProps }) leaves a previously-set body intact',
        () async {
      final transport = FakeChatTransport();
      final client = ChatClient(
        transport: transport,
        body: <String, dynamic>{'body': 1},
      );
      client.updateOptions(forwardedProps: <String, dynamic>{'fp': 2});
      await client.sendText('x');
      final forwarded = transport.bodies.single['forwardedProps'] as Map;
      expect(forwarded['body'], 1);
      expect(forwarded['fp'], 2);
      await client.stop();
    });

    test(
        'updateOptions({ body }) leaves a previously-set forwardedProps intact',
        () async {
      final transport = FakeChatTransport();
      final client = ChatClient(
        transport: transport,
        forwardedProps: <String, dynamic>{'fp': 1},
      );
      client.updateOptions(body: <String, dynamic>{'body': 2});
      await client.sendText('x');
      final forwarded = transport.bodies.single['forwardedProps'] as Map;
      expect(forwarded['fp'], 1);
      expect(forwarded['body'], 2);
      await client.stop();
    });

    test('should merge body and forwardedProps with forwardedProps winning',
        () async {
      final transport = FakeChatTransport();
      final client = ChatClient(
        transport: transport,
        body: <String, dynamic>{'both': 'body', 'bodyOnly': 1},
        forwardedProps: <String, dynamic>{'both': 'fp', 'fpOnly': 2},
      );
      await client.sendText('x');
      final forwarded = transport.bodies.single['forwardedProps'] as Map;
      expect(forwarded['both'], 'fp');
      expect(forwarded['bodyOnly'], 1);
      expect(forwarded['fpOnly'], 2);
      await client.stop();
    });

    test('should not auto-emit conversationId in merged body', () async {
      final transport = FakeChatTransport();
      final client = ChatClient(transport: transport);
      await client.sendText('x');
      expect(transport.bodies.single.containsKey('conversationId'), isFalse);
      await client.stop();
    });

    test('should pass through user-set conversationId via forwardedProps',
        () async {
      final transport = FakeChatTransport();
      final client = ChatClient(
        transport: transport,
        forwardedProps: <String, dynamic>{'conversationId': 'c1'},
      );
      await client.sendText('x');
      expect(
        (transport.bodies.single['forwardedProps'] as Map)['conversationId'],
        'c1',
      );
      await client.stop();
    });

    test('should clear per-message body after request', () async {
      final transport = FakeChatTransport();
      final client = ChatClient(transport: transport);
      await client.sendText('x',
          options: const ChatSendOptions(
            body: <String, dynamic>{'once': 1},
          ));
      await client.stop();
      await client.sendText('y');
      final forwarded = transport.bodies[1]['forwardedProps'] as Map?;
      expect(forwarded?['once'], isNull);
      await client.stop();
    });

    test('should emit events with multimodal content', () async {
      final transport = FakeChatTransport();
      final chunks = <Map<String, dynamic>>[];
      final client = ChatClient(transport: transport, onChunk: chunks.add);
      await client.sendMessage(
        const ChatMessageInput(
          content: <Map<String, dynamic>>[
            <String, dynamic>{'type': 'text', 'content': 'x'},
            <String, dynamic>{
              'type': 'image',
              'source': <String, dynamic>{'type': 'url', 'value': 'u'},
            },
          ],
        ),
      );
      await emitAll(transport, textChunks('ok'));
      await settle(transport);
      expect(chunks.any((c) => c['type'] == 'TEXT_MESSAGE_CONTENT'), isTrue);
    });
  });

  group('ChatClient custom events', () {
    test('should extract toolCallId from custom event data and pass in context',
        () async {
      final transport = FakeChatTransport();
      Map<String, dynamic>? seen;
      final client = ChatClient(
        transport: transport,
        onCustomEvent: (event, _) => seen = event,
      );
      await client.sendText('x');
      transport.emit(<String, dynamic>{
        'type': 'CUSTOM',
        'name': 'custom',
        'value': <String, dynamic>{'toolCallId': 'tc'},
      });
      await pump();
      expect(seen!['value']['toolCallId'], 'tc');
      await client.stop();
    });

    test('should handle custom events with no data', () async {
      final transport = FakeChatTransport();
      var calls = 0;
      final client = ChatClient(
        transport: transport,
        onCustomEvent: (_, __) => calls++,
      );
      await client.sendText('x');
      transport.emit(<String, dynamic>{'type': 'CUSTOM', 'name': 'empty'});
      await pump();
      expect(calls, 1);
      await client.stop();
    });

    test(
        'should NOT call onCustomEvent for system events like tool-input-available',
        () async {
      final transport = FakeChatTransport();
      var calls = 0;
      final client = ChatClient(
        transport: transport,
        onCustomEvent: (_, __) => calls++,
      );
      await client.sendText('x');
      transport.emit(<String, dynamic>{
        'type': 'CUSTOM',
        'name': 'tool-input-available',
        'value': <String, dynamic>{'toolCallId': 'tc'},
      });
      await pump();
      expect(calls, 0);
      await client.stop();
    });

    test('should work when onCustomEvent is not provided', () async {
      final transport = FakeChatTransport();
      final client = ChatClient(transport: transport);
      await client.sendText('x');
      transport.emit(<String, dynamic>{'type': 'CUSTOM', 'name': 'x'});
      await pump();
      expect(client.getError(), isNull);
      await client.stop();
    });

    test('should handle multiple different custom events in sequence',
        () async {
      final transport = FakeChatTransport();
      final names = <String>[];
      final client = ChatClient(
        transport: transport,
        onCustomEvent: (event, _) => names.add('${event['name']}'),
      );
      await client.sendText('x');
      transport.emit(<String, dynamic>{'type': 'CUSTOM', 'name': 'a'});
      transport.emit(<String, dynamic>{'type': 'CUSTOM', 'name': 'b'});
      await pump();
      expect(names, <String>['a', 'b']);
      await client.stop();
    });

    test('should preserve event data exactly as received from stream',
        () async {
      final transport = FakeChatTransport();
      Map<String, dynamic>? seen;
      final value = <String, dynamic>{
        'nested': <String, dynamic>{'n': 1}
      };
      final client = ChatClient(
        transport: transport,
        onCustomEvent: (event, _) => seen = event,
      );
      await client.sendText('x');
      transport.emit(<String, dynamic>{
        'type': 'CUSTOM',
        'name': 'custom',
        'value': value,
      });
      await pump();
      expect(seen!['value'], value);
      await client.stop();
    });
  });

  group('ChatClient activity messages', () {
    test('does not send activity messages as model input on the next turn',
        () async {
      final transport = FakeChatTransport();
      final client = ChatClient(
        transport: transport,
        messages: <AssistantTurn>[
          AssistantTurn.activity(
            id: 'act',
            parts: <AssistantPart>[
              AssistantPart(type: 'activity', activityType: 'SEARCH'),
            ],
          ),
        ],
      );
      await client.sendText('next');
      final rows = transport.bodies.single['messages'] as List;
      expect(rows.any((r) => (r as Map)['id'] == 'act'), isFalse);
      await client.stop();
    });

    test('exposes initial activity messages', () {
      final activity = AssistantTurn.activity(
        id: 'act',
        parts: <AssistantPart>[
          AssistantPart(type: 'activity', activityType: 'SEARCH'),
        ],
      );
      final client = ChatClient(
        transport: FakeChatTransport(),
        messages: <AssistantTurn>[activity],
      );
      expect(client.getMessages().single.role, 'activity');
    });

    test('hydrates activity from an inbound MESSAGES_SNAPSHOT ActivityMessage',
        () async {
      final transport = FakeChatTransport();
      final client = ChatClient(transport: transport);
      await client.sendText('x');
      transport.emit(<String, dynamic>{
        'type': 'MESSAGES_SNAPSHOT',
        'messages': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'act',
            'role': 'activity',
            'parts': <Map<String, dynamic>>[
              <String, dynamic>{
                'type': 'activity',
                'activityType': 'SEARCH',
                'content': <String, dynamic>{'q': 'x'},
              },
            ],
          },
        ],
      });
      await pump();
      expect(client.getMessages().single.role, 'activity');
      await client.stop();
    });
  });

  group('ChatClient subscribe/send connection mode', () {
    test('subscribe should be idempotent without restart', () {
      final client = ChatClient(transport: FakeChatTransport());
      client.subscribe();
      client.subscribe();
      expect(client.getIsSubscribed(), isTrue);
    });

    test('unsubscribe should be idempotent', () async {
      final client = ChatClient(transport: FakeChatTransport());
      client.subscribe();
      await client.unsubscribe();
      await client.unsubscribe();
      expect(client.getIsSubscribed(), isFalse);
    });

    test('stop should not unsubscribe an active subscription', () async {
      final client = ChatClient(transport: FakeChatTransport());
      client.subscribe();
      await client.stop();
      expect(client.getIsSubscribed(), isTrue);
    });

    test('sessionGenerating should be false initially', () {
      final client = ChatClient(transport: FakeChatTransport());
      expect(client.getSessionGenerating(), isFalse);
    });

    test('should not re-subscribe on connection update when not subscribed',
        () {
      final client = ChatClient(transport: FakeChatTransport());
      client.updateOptions(body: <String, dynamic>{'x': 1});
      expect(client.getIsSubscribed(), isFalse);
    });
  });
}
