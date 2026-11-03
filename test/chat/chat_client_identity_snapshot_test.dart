// Upstream reference: packages/ai-client/tests/client-snapshots.test.ts,
// chat-hydration-error.test.ts and chat-is-hydrating.test.ts.
import 'dart:async';

import 'package:tanstack_ai_dart/chat.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('ChatClient snapshots', () {
    test('isolates nested message parts from callers and old snapshots', () {
      final input = <String, dynamic>{'id': 1};
      final client = ChatClient(
        transport: FakeChatTransport(),
        messages: <AssistantTurn>[
          AssistantTurn(
            id: 'a1',
            role: 'assistant',
            parts: <AssistantPart>[
              AssistantPart.tool(
                id: 'tc1',
                name: 'lookup',
                input: input,
                state: 'input-complete',
              ),
            ],
          ),
        ],
      );
      final snapshot = client.getSnapshot();
      final livePart = client.getMessages().first.parts.first;
      livePart.input = <String, dynamic>{'id': 2};
      expect((snapshot.messages.first.parts.first).input, <String, dynamic>{
        'id': 1,
      });

      expect(
          () => snapshot.messages.first.parts.first.input = <String, dynamic>{
                'id': 3
              },
          throwsUnsupportedError);
      expect(client.getMessages().first.parts.first.input, <String, dynamic>{
        'id': 2,
      });
    });

    test('copies tool input, approval, and subagent transcripts', () {
      final client = ChatClient(
        transport: FakeChatTransport(),
        messages: <AssistantTurn>[
          AssistantTurn(
            id: 'a1',
            role: 'assistant',
            parts: <AssistantPart>[
              AssistantPart.tool(
                id: 'tc1',
                name: 'lookup',
                input: <String, dynamic>{
                  'nested': <String, dynamic>{'x': 1}
                },
                state: 'approval-requested',
                approval: AssistantApproval(id: 'approval-1'),
              ),
              AssistantPart(
                type: 'subagent',
                id: 'sub-1',
                subagent: <String, dynamic>{
                  'id': 'sub-1',
                  'messages': <dynamic>[
                    <String, dynamic>{'id': 'child'},
                  ],
                },
              ),
            ],
          ),
        ],
      );
      final snapshot = client.getSnapshot();
      final live = client.getMessages().first.parts;
      (live[0].input as Map)['nested'] = <String, dynamic>{'x': 2};
      live[0].approval!.approved = true;
      (live[1].subagent!['messages'] as List).clear();

      final frozen = snapshot.messages.first.parts;
      expect((frozen[0].input as Map)['nested'], <String, dynamic>{'x': 1});
      expect(frozen[0].approval!.approved, isNull);
      expect(frozen[1].subagent!['messages'], hasLength(1));
    });

    test('keeps the identity of unchanged messages across snapshots', () {
      final client = ChatClient(
        transport: FakeChatTransport(),
        messages: <AssistantTurn>[
          userMessage('u1', 'hello'),
          AssistantTurn(
            id: 'a1',
            role: 'assistant',
            parts: <AssistantPart>[AssistantPart.text('one')],
          ),
        ],
      );
      final first = client.getSnapshot();
      client.setMessagesManually(<AssistantTurn>[
        ...client.getMessages(),
        userMessage('u2', 'two'),
      ]);
      final second = client.getSnapshot();
      expect(identical(first.messages[0], second.messages[0]), isTrue);
      expect(identical(first.messages[1], second.messages[1]), isTrue);
      expect(identical(first.messages, second.messages), isFalse);
    });

    test('isolates queue entries published by normal updates', () async {
      final transport = FakeChatTransport();
      final client = ChatClient(transport: transport);
      await client.sendText('first');
      await client.sendText('second');
      final published = client.getSnapshot().queue;
      published.single.content;
      client.cancelQueued(published.single.id);
      expect(client.getQueue(), isEmpty);
      await client.stop();
    });
  });

  group('ChatClient isHydrating', () {
    test('is true from construction until the server transcript is applied',
        () async {
      final gate = Completer<ChatHydrationResult>();
      final seen = <({bool isHydrating, int messages})>[];
      late ChatClient client;
      client = ChatClient(
        transport: FakeChatTransport(),
        options: ChatClientOptions(
          threadId: 't1',
          hydrate: (_, __) => gate.future,
        ),
        onChanged: () {
          if (client.getIsHydrating() == false) {
            seen.add((
              isHydrating: false,
              messages: client.getMessages().length,
            ));
          }
        },
      );
      expect(client.getIsHydrating(), isTrue);
      final attach = client.attach();
      expect(client.getIsHydrating(), isTrue);
      gate.complete(
        ChatHydrationResult(
          messages: <AssistantTurn>[userMessage('m1', 'hi')],
        ),
      );
      await attach;
      expect(client.getIsHydrating(), isFalse);
      expect(client.getMessages(), hasLength(1));
      expect(seen.isNotEmpty, isTrue);
    });

    test('turns off when the server hydrate fails', () async {
      final client = ChatClient(
        transport: FakeChatTransport(),
        options: ChatClientOptions(
          threadId: 't1',
          hydrate: (_, __) => throw StateError('server returned 500'),
        ),
      );
      await client.attach();
      expect(client.getStatus(), 'error');
      expect(client.getError(), contains('500'));
      expect(client.getIsHydrating(), isFalse);
    });

    test('stays on across a detach and re-attach that reuse the same request',
        () async {
      final gate = Completer<ChatHydrationResult>();
      var calls = 0;
      final client = ChatClient(
        transport: FakeChatTransport(),
        options: ChatClientOptions(
          threadId: 't1',
          hydrate: (_, __) {
            calls++;
            return gate.future;
          },
        ),
      );
      final attach = client.attach();
      client.detach();
      final reattach = client.attach();
      expect(calls, 1);
      expect(client.getIsHydrating(), isTrue);
      gate.complete(const ChatHydrationResult(messages: <AssistantTurn>[]));
      await Future.wait(<Future<void>>[attach, reattach]);
      expect(client.getIsHydrating(), isFalse);
    });

    test('turns off when a send takes over, and the late transcript is dropped',
        () async {
      final gate = Completer<ChatHydrationResult>();
      final transport = FakeChatTransport();
      final client = ChatClient(
        transport: transport,
        options: ChatClientOptions(
          threadId: 't1',
          hydrate: (_, __) => gate.future,
        ),
      );
      final attach = client.attach();
      expect(client.getIsHydrating(), isTrue);
      await client.sendText('new turn');
      expect(client.getIsHydrating(), isFalse);
      gate.complete(
        ChatHydrationResult(
          messages: <AssistantTurn>[userMessage('late', 'late')],
        ),
      );
      await attach;
      await pump();
      expect(client.getIsHydrating(), isFalse);
      expect(client.getMessages().map((m) => m.id), isNot(contains('late')));
      await client.stop();
    });

    test('turns off when clear() drops a pending load', () async {
      final gate = Completer<ChatHydrationResult>();
      final client = ChatClient(
        transport: FakeChatTransport(),
        options: ChatClientOptions(
          threadId: 't1',
          hydrate: (_, __) => gate.future,
        ),
      );
      final attach = client.attach();
      expect(client.getIsHydrating(), isTrue);
      await client.clear();
      expect(client.getIsHydrating(), isFalse);
      gate.complete(const ChatHydrationResult(messages: <AssistantTurn>[]));
      await attach;
    });

    test('is always false without persistence', () async {
      final client = ChatClient(transport: FakeChatTransport());
      await client.attach();
      expect(client.getIsHydrating(), isFalse);
    });

    test('clears the hydration error when a later load succeeds', () async {
      var attempt = 0;
      final client = ChatClient(
        transport: FakeChatTransport(),
        options: ChatClientOptions(
          threadId: 't1',
          hydrate: (_, __) {
            attempt++;
            if (attempt == 1) throw StateError('server returned 500');
            return const ChatHydrationResult(messages: <AssistantTurn>[]);
          },
        ),
      );
      await client.attach();
      expect(client.getStatus(), 'error');
      await client.attach();
      expect(client.getError(), isNull);
      expect(client.getStatus(), isNot('error'));
    });
  });
}
