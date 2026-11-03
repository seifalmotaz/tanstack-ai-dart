// Upstream reference: packages/ai-client/tests/chat-client-identity.test.ts
// and chat-client-metadata.test.ts
import 'package:tanstack_ai_dart/chat.dart';
import 'package:tanstack_ai_dart/connections.dart' as conn;
import 'package:test/test.dart';

import 'support.dart';

conn.ConnectionAdapter capturing(
  List<conn.RunAgentInputContext> contexts, {
  List<List<Map<String, dynamic>>>? scripts,
}) {
  var call = 0;
  return conn.ConnectionAdapter(
    connect: (messages, {data, signal, runContext}) async* {
      if (runContext != null) contexts.add(runContext);
      final chunks = scripts != null && call < scripts.length
          ? scripts[call++]
          : <Map<String, dynamic>>[
              <String, dynamic>{'type': 'RUN_STARTED', 'runId': 'run-1'},
              <String, dynamic>{
                'type': 'TEXT_MESSAGE_START',
                'messageId': 'm1',
                'role': 'assistant',
              },
              <String, dynamic>{
                'type': 'TEXT_MESSAGE_CONTENT',
                'messageId': 'm1',
                'delta': 'ok',
              },
              <String, dynamic>{
                'type': 'RUN_FINISHED',
                'runId': 'run-1',
                'outcome': <String, dynamic>{'type': 'success'},
              },
            ];
      for (final chunk in chunks) {
        yield <String, dynamic>{...chunk};
      }
    },
  );
}

void main() {
  group('ChatClient identity', () {
    test('mints a thread id on first send when none is provided, and reuses it',
        () async {
      final contexts = <conn.RunAgentInputContext>[];
      final client = ChatClient(connection: capturing(contexts));
      await client.sendText('first');
      await waitFor(() => !client.getIsLoading());
      await client.sendText('second');
      expect(contexts, hasLength(2));
      expect(contexts[0].threadId, startsWith('thread-'));
      expect(contexts[1].threadId, contexts[0].threadId);
      await client.stop();
    });

    test('uses the provided threadId on the wire', () async {
      final contexts = <conn.RunAgentInputContext>[];
      final client = ChatClient(
        connection: capturing(contexts),
        options: const ChatClientOptions(threadId: 'support-42'),
      );
      await client.sendText('hello');
      expect(contexts.single.threadId, 'support-42');
      await client.stop();
    });

    test('throws when persistence is set without a threadId', () {
      expect(
        () => ChatClient(
          connection: capturing(<conn.RunAgentInputContext>[]),
          persistence: ChatPersistence(
            getItem: () => const <AssistantTurn>[],
          ),
        ),
        throwsArgumentError,
      );
    });
  });

  group('ChatClient metadata', () {
    test('sendMessage object form stamps metadata on the user UIMessage',
        () async {
      final contexts = <conn.RunAgentInputContext>[];
      final client = ChatClient(connection: capturing(contexts));
      await client.sendMessage(
        const ChatMessageInput(
          content: 'Show me failed logins',
          metadata: <String, dynamic>{
            'author': <String, dynamic>{'id': 'user-42', 'name': 'Dana'},
          },
        ),
      );
      final user = client.getMessages().firstWhere((m) => m.role == 'user');
      expect(user.metadata, <String, dynamic>{
        'author': <String, dynamic>{'id': 'user-42', 'name': 'Dana'},
      });
      await client.stop();
    });

    test('sendMessage string form has no metadata', () async {
      final client = ChatClient(
        connection: capturing(<conn.RunAgentInputContext>[]),
      );
      await client.sendText('hello');
      expect(
        client.getMessages().firstWhere((m) => m.role == 'user').metadata,
        isNull,
      );
      await client.stop();
    });

    test('queued object send keeps metadata on the queue entry content',
        () async {
      final transport = FakeChatTransport();
      final client = ChatClient(transport: transport);
      final first = client.sendText('first');
      await pump();
      await client.sendMessage(
        const ChatMessageInput(
          content: 'second',
          metadata: <String, dynamic>{
            'author': <String, dynamic>{'id': 'u2'}
          },
        ),
      );
      final queued = client.getQueue().single;
      expect(queued.content, isA<ChatMessageInput>());
      expect((queued.content as ChatMessageInput).metadata, <String, dynamic>{
        'author': <String, dynamic>{'id': 'u2'},
      });
      await client.stop();
      await first;
    });

    test('append copies uiMessage.metadata', () async {
      final contexts = <conn.RunAgentInputContext>[];
      final client = ChatClient(connection: capturing(contexts));
      await client.append(
        AssistantTurn(
          id: 'user-1',
          role: 'user',
          parts: <AssistantPart>[AssistantPart.text('Hello')],
          metadata: <String, dynamic>{
            'author': <String, dynamic>{'id': 'u1'}
          },
        ),
      );
      expect(client.getMessages().first.metadata, <String, dynamic>{
        'author': <String, dynamic>{'id': 'u1'},
      });
      await client.stop();
    });

    test('batch drain merges object metadata last-write-wins per key',
        () async {
      final transport = FakeChatTransport();
      final client = ChatClient(
        transport: transport,
        queue: const ChatQueueConfig(drain: QueueDrainMode.batch),
      );
      final first = client.sendText('first');
      await pump();
      await client.sendMessage(
        const ChatMessageInput(
          content: 'a',
          metadata: <String, dynamic>{
            'author': <String, dynamic>{'id': 'user-1', 'name': 'Ada'},
            'room': 'ops',
          },
        ),
      );
      await client.sendMessage(
        const ChatMessageInput(
          content: 'b',
          metadata: <String, dynamic>{
            'author': <String, dynamic>{'id': 'user-42', 'name': 'Dana'},
          },
        ),
      );
      await emitAll(transport, textChunks('one'));
      await transport.closeAt(0);
      await waitFor(() => transport.bodies.length == 2);
      final user = client.getMessages().lastWhere((m) => m.role == 'user');
      expect(user.metadata, <String, dynamic>{
        'author': <String, dynamic>{'id': 'user-42', 'name': 'Dana'},
        'room': 'ops',
      });
      await client.stop();
      await first;
    });
  });
}
