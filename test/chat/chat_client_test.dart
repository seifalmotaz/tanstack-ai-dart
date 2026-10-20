// Upstream reference: packages/ai-client/tests/chat-client.test.ts
import 'package:tanstack_ai_dart/chat.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('ChatClient', () {
    group('constructor', () {
      test('should create a client with default options', () {
        final client = ChatClient(transport: FakeChatTransport());
        expect(client.getMessages(), isEmpty);
        expect(client.getIsLoading(), isFalse);
        expect(client.getIsSubscribed(), isFalse);
        expect(client.getError(), isNull);
      });

      test('exposes a UI snapshot that subscribeSnapshot notifies', () {
        final client = ChatClient(
          transport: FakeChatTransport(),
          messages: <AssistantTurn>[userMessage('msg-1', 'Hello')],
        );
        final snapshot = client.getSnapshot();
        expect(snapshot.messages, hasLength(1));
        expect(snapshot.status, 'ready');
        expect(snapshot.isLoading, isFalse);
        expect(identical(client.getSnapshot(), snapshot), isTrue);

        var calls = 0;
        final stop = client.subscribeSnapshot(() => calls++);
        client.setMessagesManually(<AssistantTurn>[]);
        expect(calls, 1);
        expect(client.getSnapshot().messages, isEmpty);
        expect(identical(client.getSnapshot(), snapshot), isFalse);
        stop();
        client.setMessagesManually(
            <AssistantTurn>[userMessage('msg-2', 'After')]);
        expect(calls, 1);
      });

      test('should initialize with provided messages', () {
        final initial = <AssistantTurn>[userMessage('m1', 'hello')];
        final client = ChatClient(
          transport: FakeChatTransport(),
          messages: initial,
        );
        expect(client.getMessages(), same(initial));
      });

      test('should generate unique message ids', () async {
        final transport = FakeChatTransport();
        final client = ChatClient(transport: transport);
        await client.sendText('one');
        await client.stop();
        await client.sendText('two');
        final ids = client.getMessages().map((m) => m.id).toSet();
        expect(ids, hasLength(4));
      });
    });

    group('sendMessage', () {
      test('should send a message and append it', () async {
        final transport = FakeChatTransport();
        final client = ChatClient(transport: transport);
        await client.sendText('Hello');
        final messages = client.getMessages();
        expect(messages.first.role, 'user');
        expect(messages.first.parts.first.content, 'Hello');
        await client.stop();
      });

      test('should create and return assistant message from stream chunks',
          () async {
        final transport = FakeChatTransport();
        final client = ChatClient(transport: transport);
        await client.sendText('Hello');
        await emitAll(transport, textChunks('Hello, world!'));
        await transport.close();
        await pump();

        final assistant =
            client.getMessages().firstWhere((m) => m.role == 'assistant');
        expect(assistant.id, isNotEmpty);
        expect(assistant.createdAt, isNotNull);
        expect(assistant.answer, 'Hello, world!');
        expect(assistant.streaming, isFalse);
        expect(client.getIsLoading(), isFalse);
      });

      test('should not send empty messages', () async {
        final transport = FakeChatTransport();
        final client = ChatClient(transport: transport);
        await client.sendText('');
        await client.sendText('   ');
        expect(client.getMessages(), isEmpty);
        expect(transport.bodies, isEmpty);
      });

      test(
          'should queue (not send immediately) a message sent while loading, then auto-send it once the stream settles',
          () async {
        final transport = FakeChatTransport();
        final client = ChatClient(transport: transport);
        await client.sendText('First');
        await client.sendText('Second');
        expect(transport.bodies, hasLength(1));
        expect(client.getQueue().single.content, 'Second');

        await emitAll(transport, textChunks('Response'));
        await transport.close();
        await waitFor(() => transport.bodies.length == 2);
        await emitAll(transport, textChunks('Done', runId: 'run-2'));
        await transport.closeAt(1);
        await pump();

        final users = client
            .getMessages()
            .where((m) => m.role == 'user')
            .map((m) => m.answer)
            .toList();
        expect(users, <String>['First', 'Second']);
      });

      test('isolates queue entries published by normal updates', () async {
        final transport = FakeChatTransport();
        final client = ChatClient(transport: transport);
        final snapshots = <List<QueuedMessage>>[];
        await client.sendText('First');
        // Mutating the published list must not mutate the queue.
        client.getQueue().add(
              QueuedMessage(id: 'outside', content: 'outside'),
            );
        expect(client.getQueue(), isEmpty);
        await client.sendText('Second');
        snapshots.add(client.getQueue());
        snapshots.first.clear();
        expect(client.getQueue(), hasLength(1));
        await client.stop();
      });

      test('does not leak sendOptions.whenBusy onto the wire next to body',
          () async {
        final transport = FakeChatTransport();
        final client = ChatClient(transport: transport);
        await client.sendText(
          'Hello',
          options: const ChatSendOptions(body: <String, dynamic>{'x': 1}),
        );
        expect(transport.bodies.single.containsKey('whenBusy'), isFalse);
        expect(
          (transport.bodies.single['forwardedProps'] as Map)['x'],
          1,
        );
        await client.stop();
      });

      test('multimodal sendMessage keeps text and media parts', () async {
        final transport = FakeChatTransport();
        final client = ChatClient(transport: transport);
        await client.sendMessage(
          const ChatMessageInput(
            id: 'custom-id',
            content: <Map<String, dynamic>>[
              <String, dynamic>{'type': 'text', 'content': 'Describe'},
              <String, dynamic>{
                'type': 'image',
                'source': <String, dynamic>{
                  'type': 'url',
                  'value': 'https://example.com/a.png',
                },
              },
            ],
          ),
        );
        final user = client.getMessages().first;
        expect(user.id, 'custom-id');
        expect(user.parts.map((p) => p.type), <String>['text', 'image']);
        expect(user.parts.last.source!['value'], 'https://example.com/a.png');
        await client.stop();
      });

      test('merged body: chat, positional, sendOptions; sendOptions wins',
          () async {
        final transport = FakeChatTransport();
        final client = ChatClient(
          transport: transport,
          body: <String, dynamic>{'a': 'chat', 'b': 'chat'},
        );
        await client.sendMessage(
          'hello',
          body: <String, dynamic>{'b': 'positional', 'c': 'positional'},
          sendOptions: const ChatSendOptions(
            body: <String, dynamic>{'c': 'options'},
          ),
        );
        final forwarded = transport.bodies.single['forwardedProps'] as Map;
        expect(forwarded, containsPair('a', 'chat'));
        expect(forwarded, containsPair('b', 'positional'));
        expect(forwarded, containsPair('c', 'options'));
        await client.stop();
      });
    });

    group('append', () {
      test('should append a UIMessage', () async {
        final transport = FakeChatTransport();
        final client = ChatClient(transport: transport);
        await client.append(userMessage('u1', 'hi'));
        expect(client.getMessages().first.id, 'u1');
        final body = transport.bodies.single;
        expect((body['messages'] as List).first['id'], 'u1');
        await client.stop();
      });

      test('skips system messages', () async {
        final transport = FakeChatTransport();
        final client = ChatClient(transport: transport);
        await client.append(
          AssistantTurn(
            id: 's1',
            role: 'system',
            parts: <AssistantPart>[AssistantPart.text('rules')],
          ),
        );
        expect(client.getMessages(), isEmpty);
        expect(transport.bodies, isEmpty);
      });

      test('keeps an appended activity message without starting a run',
          () async {
        final transport = FakeChatTransport();
        final client = ChatClient(transport: transport);
        await client.append(
          AssistantTurn.activity(
            id: 'act-1',
            parts: <AssistantPart>[
              AssistantPart(
                type: 'activity',
                id: 'act-1',
                activityType: 'SEARCH',
                activityContent: <String, dynamic>{'query': 'tanstack'},
              ),
            ],
          ),
        );
        expect(client.getMessages().single.role, 'activity');
        expect(transport.bodies, isEmpty);
      });
    });

    group('stop/clear/reload', () {
      test('should stop loading and abort request', () async {
        final transport = FakeChatTransport();
        final client = ChatClient(transport: transport);
        await client.sendText('Hello');
        expect(client.isStreaming, isTrue);
        await client.stop();
        expect(client.isStreaming, isFalse);
        expect(client.getInterrupts(), isEmpty);
        expect(transport.controllers.single.hasListener, isFalse);
      });

      test('should clear all messages', () async {
        final transport = FakeChatTransport();
        final client = ChatClient(transport: transport);
        await client.sendText('Hello');
        await client.clear();
        expect(client.getMessages(), isEmpty);
        expect(client.getQueue(), isEmpty);
        expect(client.getError(), isNull);
        expect(client.getResumeState(), isNull);
      });

      test('should reload from last user message', () async {
        final transport = FakeChatTransport();
        final client = ChatClient(
          transport: transport,
          messages: <AssistantTurn>[
            userMessage('u1', 'first'),
            assistantMessage('a1', <AssistantPart>[AssistantPart.text('one')]),
            userMessage('u2', 'second'),
            assistantMessage('a2', <AssistantPart>[AssistantPart.text('two')]),
          ],
        );
        await client.reload();
        expect(client.getMessages(), hasLength(4));
        expect(client.getMessages()[0].id, 'u1');
        expect(client.getMessages()[1].id, 'a1');
        expect(client.getMessages()[2].id, 'u2');
        expect(client.getMessages().last.role, 'assistant');
        expect(transport.bodies, hasLength(1));
        await client.stop();
      });

      test('should do nothing if no user messages', () async {
        final transport = FakeChatTransport();
        final client = ChatClient(
          transport: transport,
          messages: <AssistantTurn>[
            assistantMessage('a1', <AssistantPart>[AssistantPart.text('one')]),
          ],
        );
        await client.reload();
        expect(transport.bodies, isEmpty);
      });
    });

    group('callbacks and status', () {
      test('should call onChunk for each chunk', () async {
        final transport = FakeChatTransport();
        final chunks = <Map<String, dynamic>>[];
        final client = ChatClient(
          transport: transport,
          onChunk: chunks.add,
        );
        await client.sendText('Hello');
        await emitAll(transport, textChunks('hi'));
        await transport.close();
        await pump();
        expect(chunks.any((c) => c['type'] == 'TEXT_MESSAGE_CONTENT'), isTrue);
        expect(chunks.last['type'], 'RUN_FINISHED');
      });

      test('should transition through states during generation', () async {
        final transport = FakeChatTransport();
        final client = ChatClient(transport: transport);
        expect(client.getIsLoading(), isFalse);
        await client.sendText('Hello');
        expect(client.getStatus(), 'streaming');
        await emitAll(transport, textChunks('done'));
        await transport.close();
        await pump();
        expect(client.getStatus(), 'ready');
      });

      test('should clear error on successful request', () async {
        final transport = FakeChatTransport();
        final client = ChatClient(transport: transport);
        await client.sendText('first');
        transport.emit(<String, dynamic>{
          'type': 'RUN_ERROR',
          'message': 'boom',
        });
        await transport.close();
        await pump();
        expect(client.getStatus(), 'error');

        await client.sendText('second');
        await emitAll(transport, textChunks('ok', runId: 'run-2'));
        await transport.closeAt(1);
        await pump();
        expect(client.getError(), isNull);
      });

      test('should call onCustomEvent for arbitrary custom events', () async {
        final transport = FakeChatTransport();
        final seen = <Map<String, dynamic>>[];
        final client = ChatClient(
          transport: transport,
          onCustomEvent: (event, _) => seen.add(event),
        );
        await client.sendText('Hello');
        transport.emit(<String, dynamic>{
          'type': 'CUSTOM',
          'name': 'analytics',
          'value': <String, dynamic>{'n': 1},
        });
        transport.emit(<String, dynamic>{
          'type': 'CUSTOM',
          'name': 'tool-input-available',
          'value': <String, dynamic>{
            'toolCallId': 't1',
            'toolName': 'x',
            'input': <String, dynamic>{},
          },
        });
        await pump();
        expect(seen.single['name'], 'analytics');
        await client.stop();
      });
    });

    group('sessionGenerating', () {
      test('should flip to true on RUN_STARTED and false on RUN_FINISHED',
          () async {
        final transport = FakeChatTransport();
        final changes = <bool>[];
        final client = ChatClient(
          transport: transport,
          onSessionGeneratingChange: changes.add,
        );
        await client.sendText('Hello');
        transport.emit(<String, dynamic>{
          'type': 'RUN_STARTED',
          'runId': 'run-1',
          'threadId': 'thread-1',
        });
        await pump();
        expect(client.getSessionGenerating(), isTrue);
        transport.emit(<String, dynamic>{
          'type': 'RUN_FINISHED',
          'runId': 'run-1',
          'threadId': 'thread-1',
          'outcome': <String, dynamic>{'type': 'success'},
        });
        await transport.close();
        await pump();
        expect(client.getSessionGenerating(), isFalse);
        expect(changes, contains(true));
        expect(changes.last, isFalse);
      });

      test('should flip to false on RUN_ERROR', () async {
        final transport = FakeChatTransport();
        final client = ChatClient(transport: transport);
        await client.sendText('Hello');
        transport.emit(<String, dynamic>{
          'type': 'RUN_STARTED',
          'runId': 'run-1',
        });
        transport.emit(<String, dynamic>{
          'type': 'RUN_ERROR',
          'runId': 'run-1',
          'message': 'failed',
        });
        await transport.close();
        await pump();
        expect(client.getSessionGenerating(), isFalse);
      });
    });
  });
}
