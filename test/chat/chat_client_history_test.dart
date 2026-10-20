// Upstream reference: packages/ai-client/tests/chat-client-history.test.ts
import 'dart:async';

import 'package:tanstack_ai_dart/chat.dart';
import 'package:test/test.dart';

import 'support.dart';

List<String> ids(List<AssistantTurn> messages) =>
    messages.map((message) => message.id).toList();

List<String> bodyIds(Map<String, dynamic> body) => [
      for (final row in body['messages'] as List)
        if (row['id'] is String) row['id'] as String,
    ];

void main() {
  group('ChatClient history paging', () {
    test('hydrate GET includes limit when history.pageSize is set', () async {
      final calls = <ChatHydrateOptions>[];
      final client = ChatClient(
        transport: FakeChatTransport(),
        options: ChatClientOptions(
          threadId: 't1',
          history: const ChatHistoryConfig(pageSize: 50),
          hydrate: (threadId, options) {
            calls.add(options);
            return ChatHydrationResult(
              messages: <AssistantTurn>[userMessage('m-newest', 'latest')],
              page: const ChatHydrationPage(
                truncated: true,
                cursor: 'm-newest',
              ),
            );
          },
        ),
      );
      await client.attach();
      expect(ids(client.getMessages()), <String>['m-newest']);
      expect(calls.single.limit, 50);
      expect(client.getHasOlderMessages(), isTrue);
    });

    test('loadOlderMessages prepends older ids in front', () async {
      final client = ChatClient(
        transport: FakeChatTransport(),
        options: ChatClientOptions(
          threadId: 't1',
          history: const ChatHistoryConfig(pageSize: 50),
          hydrate: (threadId, options) {
            if (options.before == 'm2') {
              return ChatHydrationResult(
                messages: <AssistantTurn>[userMessage('m1', 'one')],
                page: const ChatHydrationPage(),
              );
            }
            return ChatHydrationResult(
              messages: <AssistantTurn>[
                userMessage('m2', 'two'),
                assistantMessage(
                  'm3',
                  <AssistantPart>[AssistantPart.text('three')],
                ),
              ],
              page: const ChatHydrationPage(
                truncated: true,
                cursor: 'm2',
              ),
            );
          },
        ),
      );
      await client.attach();
      expect(client.getSnapshot().hasOlderMessages, isTrue);

      await client.loadOlderMessages();

      expect(ids(client.getMessages()), <String>['m1', 'm2', 'm3']);
      expect(client.getHasOlderMessages(), isFalse);
      expect(client.getSnapshot().hasOlderMessages, isFalse);
    });

    test('send with history.pageSize posts only the new turn', () async {
      final sentIds = <List<String>>[];
      final transport = FakeChatTransport();
      final client = ChatClient(
        transport: transport,
        options: ChatClientOptions(
          threadId: 't1',
          history: const ChatHistoryConfig(pageSize: 50),
          hydrate: (_, __) => ChatHydrationResult(
            messages: <AssistantTurn>[
              userMessage('old-1', 'earlier'),
              assistantMessage(
                'old-2',
                <AssistantPart>[AssistantPart.text('reply')],
              ),
            ],
            page: const ChatHydrationPage(),
          ),
        ),
      );
      await client.attach();
      expect(ids(client.getMessages()), <String>['old-1', 'old-2']);

      await client.sendMessage(
        const ChatMessageInput(content: 'hello', id: 'new-user'),
      );
      sentIds.add(bodyIds(transport.bodies.single));

      expect(sentIds.single, <String>['new-user']);
      await client.stop();
    });

    test('send without history.pageSize posts the painted window', () async {
      final transport = FakeChatTransport();
      final client = ChatClient(
        transport: transport,
        options: ChatClientOptions(
          threadId: 't1',
          hydrate: (_, __) => ChatHydrationResult(
            messages: <AssistantTurn>[
              userMessage('old-1', 'earlier'),
              assistantMessage(
                'old-2',
                <AssistantPart>[AssistantPart.text('reply')],
              ),
            ],
          ),
        ),
      );
      await client.attach();
      await client.sendMessage(
        const ChatMessageInput(content: 'hello', id: 'new-user'),
      );
      expect(bodyIds(transport.bodies.single), <String>[
        'old-1',
        'old-2',
        'new-user',
      ]);
      await client.stop();
    });

    test('loadOlderMessages rejects on network fail and keeps painted messages',
        () async {
      var fail = false;
      final client = ChatClient(
        transport: FakeChatTransport(),
        options: ChatClientOptions(
          threadId: 't1',
          history: const ChatHistoryConfig(pageSize: 50),
          hydrate: (_, options) async {
            if (fail && options.before != null) {
              throw StateError('network');
            }
            return ChatHydrationResult(
              messages: <AssistantTurn>[userMessage('m2', 'two')],
              page: const ChatHydrationPage(
                truncated: true,
                cursor: 'm2',
              ),
            );
          },
        ),
      );
      await client.attach();
      fail = true;
      await expectLater(client.loadOlderMessages(), throwsStateError);
      expect(ids(client.getMessages()), <String>['m2']);
      expect(client.getHasOlderMessages(), isTrue);
    });

    test('loadOlderMessages no-ops while a page load is in flight', () async {
      final gate = Completer<void>();
      var calls = 0;
      final client = ChatClient(
        transport: FakeChatTransport(),
        options: ChatClientOptions(
          threadId: 't1',
          history: const ChatHistoryConfig(pageSize: 50),
          hydrate: (_, options) async {
            calls++;
            if (options.before != null) {
              await gate.future;
              return ChatHydrationResult(
                messages: <AssistantTurn>[userMessage('m1', 'one')],
                page: const ChatHydrationPage(),
              );
            }
            return ChatHydrationResult(
              messages: <AssistantTurn>[userMessage('m2', 'two')],
              page: const ChatHydrationPage(
                truncated: true,
                cursor: 'm2',
              ),
            );
          },
        ),
      );
      await client.attach();
      final first = client.loadOlderMessages();
      await client.loadOlderMessages();
      expect(calls, 2);
      gate.complete();
      await first;
      expect(ids(client.getMessages()), <String>['m1', 'm2']);
    });

    test('reload sends the last user so persistence can cut the stored tail',
        () async {
      final transport = FakeChatTransport();
      final client = ChatClient(
        transport: transport,
        options: ChatClientOptions(
          threadId: 't1',
          history: const ChatHistoryConfig(pageSize: 50),
          hydrate: (_, __) => ChatHydrationResult(
            messages: <AssistantTurn>[
              userMessage('u1', 'ask'),
              assistantMessage(
                'a1',
                <AssistantPart>[AssistantPart.text('tool?')],
              ),
            ],
            page: const ChatHydrationPage(),
          ),
        ),
      );
      await client.attach();
      await client.reload();
      expect(bodyIds(transport.bodies.single), <String>['u1']);
      await client.stop();
    });

    test(
        'resume after a paged hydrate posts from the last user through the assistant',
        () async {
      final transport = FakeChatTransport();
      final client = ChatClient(
        transport: transport,
        options: ChatClientOptions(
          threadId: 't1',
          history: const ChatHistoryConfig(pageSize: 50),
          hydrate: (_, __) => ChatHydrationResult(
            messages: <AssistantTurn>[
              userMessage('u1', 'ask'),
              assistantMessage(
                'a1',
                <AssistantPart>[AssistantPart.text('tool?')],
              ),
            ],
            page: const ChatHydrationPage(),
            interrupts: const ChatHydrationInterrupts(
              runId: 'run-1',
              pending: <Map<String, dynamic>>[
                <String, dynamic>{
                  'id': 'i1',
                  'reason': 'approval_requested',
                  'message': 'Approve?',
                },
              ],
            ),
          ),
        ),
      );
      await client.attach();
      await client.resumeInterruptsUnsafe(
        <Map<String, dynamic>>[
          <String, dynamic>{
            'interruptId': 'i1',
            'status': 'resolved',
            'payload': <String, dynamic>{'approved': true},
          },
        ],
        threadId: 't1',
        runId: 'run-1',
      );
      expect(bodyIds(transport.bodies.single), <String>['u1', 'a1']);
      await client.stop();
    });

    test('send after Load older still posts only the new turn', () async {
      final transport = FakeChatTransport();
      final client = ChatClient(
        transport: transport,
        options: ChatClientOptions(
          threadId: 't1',
          history: const ChatHistoryConfig(pageSize: 50),
          hydrate: (_, options) {
            if (options.before == 'm2') {
              return ChatHydrationResult(
                messages: <AssistantTurn>[userMessage('m1', 'one')],
                page: const ChatHydrationPage(),
              );
            }
            return ChatHydrationResult(
              messages: <AssistantTurn>[
                userMessage('m2', 'two'),
                assistantMessage(
                  'm3',
                  <AssistantPart>[AssistantPart.text('three')],
                ),
              ],
              page: const ChatHydrationPage(
                truncated: true,
                cursor: 'm2',
              ),
            );
          },
        ),
      );
      await client.attach();
      await client.loadOlderMessages();
      await client.sendMessage(
        const ChatMessageInput(content: 'hello', id: 'new-user'),
      );
      expect(bodyIds(transport.bodies.single), <String>['new-user']);
      await client.stop();
    });

    test(
        'loadOlderMessages rejects an empty older page and keeps hasOlderMessages',
        () async {
      final client = ChatClient(
        transport: FakeChatTransport(),
        options: ChatClientOptions(
          threadId: 't1',
          history: const ChatHistoryConfig(pageSize: 50),
          hydrate: (_, options) => ChatHydrationResult(
            messages: options.before == null
                ? <AssistantTurn>[userMessage('m2', 'two')]
                : const <AssistantTurn>[],
            page: options.before == null
                ? const ChatHydrationPage(
                    truncated: true,
                    cursor: 'm2',
                  )
                : const ChatHydrationPage(),
          ),
        ),
      );
      await client.attach();
      await expectLater(client.loadOlderMessages(), throwsStateError);
      expect(ids(client.getMessages()), <String>['m2']);
      expect(client.getHasOlderMessages(), isTrue);
    });

    test('applies page state before prepend so the last page is not stuck',
        () async {
      final client = ChatClient(
        transport: FakeChatTransport(),
        options: ChatClientOptions(
          threadId: 't1',
          history: const ChatHistoryConfig(pageSize: 50),
          hydrate: (_, options) => ChatHydrationResult(
            messages: options.before == null
                ? <AssistantTurn>[userMessage('m2', 'two')]
                : <AssistantTurn>[userMessage('m1', 'one')],
            page: options.before == null
                ? const ChatHydrationPage(
                    truncated: true,
                    cursor: 'm2',
                  )
                : const ChatHydrationPage(),
          ),
        ),
      );
      await client.attach();
      await client.loadOlderMessages();
      expect(client.getHasOlderMessages(), isFalse);
    });

    test('clear resets older-page state and ignores a late older fetch',
        () async {
      final gate = Completer<void>();
      final client = ChatClient(
        transport: FakeChatTransport(),
        options: ChatClientOptions(
          threadId: 't1',
          history: const ChatHistoryConfig(pageSize: 50),
          hydrate: (_, options) async {
            if (options.before != null) {
              await gate.future;
              return ChatHydrationResult(
                messages: <AssistantTurn>[userMessage('m1', 'one')],
              );
            }
            return ChatHydrationResult(
              messages: <AssistantTurn>[userMessage('m2', 'two')],
              page: const ChatHydrationPage(
                truncated: true,
                cursor: 'm2',
              ),
            );
          },
        ),
      );
      await client.attach();
      final pending = client.loadOlderMessages();
      await client.clear();
      gate.complete();
      await pending;
      expect(client.getMessages(), isEmpty);
      expect(client.getHasOlderMessages(), isFalse);
    });
  });
}
