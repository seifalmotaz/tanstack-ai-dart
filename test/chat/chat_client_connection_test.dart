// Upstream reference: connection-adapters.test.ts + chat-client identity tests
import 'dart:async';

import 'package:tanstack_ai_dart/chat.dart';
import 'package:tanstack_ai_dart/connections.dart' as conn;
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('ChatClient canonical conn.ConnectionAdapter', () {
    test('preserves distinct server assistant message ids via StreamProcessor',
        () async {
      final sent = <List<conn.WireMessage>>[];
      final connection = conn.ConnectionAdapter(
        connect: (messages, {data, signal, runContext}) async* {
          sent.add(messages.map((m) => Map<String, dynamic>.from(m)).toList());
          yield <String, dynamic>{
            'type': 'RUN_STARTED',
            'runId': 'run-1',
            'threadId': 'thread-1',
          };
          yield <String, dynamic>{
            'type': 'TEXT_MESSAGE_START',
            'messageId': 'server-a1',
            'role': 'assistant',
          };
          yield <String, dynamic>{
            'type': 'TEXT_MESSAGE_CONTENT',
            'messageId': 'server-a1',
            'delta': 'first',
          };
          yield <String, dynamic>{
            'type': 'TEXT_MESSAGE_END',
            'messageId': 'server-a1',
          };
          yield <String, dynamic>{
            'type': 'TEXT_MESSAGE_START',
            'messageId': 'server-a2',
            'role': 'assistant',
          };
          yield <String, dynamic>{
            'type': 'TEXT_MESSAGE_CONTENT',
            'messageId': 'server-a2',
            'delta': 'second',
          };
          yield <String, dynamic>{
            'type': 'TEXT_MESSAGE_END',
            'messageId': 'server-a2',
          };
          yield <String, dynamic>{
            'type': 'RUN_FINISHED',
            'runId': 'run-1',
            'threadId': 'thread-1',
            'outcome': <String, dynamic>{'type': 'success'},
          };
        },
      );
      final client = ChatClient(connection: connection);
      await client.sendText('hello');
      await waitFor(() => client.getMessages().length >= 3);
      await pump(8);

      final ids = client.getMessages().map((m) => m.id).toList();
      expect(ids, contains('server-a1'));
      expect(ids, contains('server-a2'));
      expect(ids.toSet().length, ids.length);
      expect(
        client
            .getMessages()
            .where((m) => m.role == 'assistant')
            .map((m) => m.id),
        <String>['server-a1', 'server-a2'],
      );
      expect(
        client
            .getMessages()
            .where((m) => m.role == 'assistant')
            .map((m) => m.answer),
        <String>['first', 'second'],
      );
      expect(sent.single.first['id'], isNot(startsWith('assistant-')));
      expect(sent.single.first['role'], 'user');
    });

    test('hydrates through the canonical connection hydrate callback',
        () async {
      final connection = conn.ConnectionAdapter(
        connect: (messages, {data, signal, runContext}) async* {
          yield <String, dynamic>{
            'type': 'RUN_FINISHED',
            'runId': 'r',
            'threadId': 't1',
            'outcome': <String, dynamic>{'type': 'success'},
          };
        },
        hydrate: (threadId, {options}) async => const conn.ChatHydrationResult(
          messages: <conn.WireMessage>[
            <String, dynamic>{
              'id': 'server-u1',
              'role': 'user',
              'parts': <Map<String, dynamic>>[
                <String, dynamic>{'type': 'text', 'content': 'hi'},
              ],
            },
            <String, dynamic>{
              'id': 'server-a1',
              'role': 'assistant',
              'parts': <Map<String, dynamic>>[
                <String, dynamic>{'type': 'text', 'content': 'hello'},
              ],
            },
          ],
        ),
      );
      final client = ChatClient(
        connection: connection,
        options: const ChatClientOptions(
          threadId: 't1',
          persistence: true,
          history: ChatHistoryConfig(pageSize: 20),
        ),
      );
      await client.attach();
      expect(client.getMessages().map((m) => m.id), <String>[
        'server-u1',
        'server-a1',
      ]);
      expect(client.getMessages().last.answer, 'hello');
    });

    test('re-joins an active hydrated run automatically', () async {
      final joined = <String>[];
      final connection = conn.ConnectionAdapter(
        connect: (messages, {data, signal, runContext}) async* {
          yield <String, dynamic>{
            'type': 'RUN_FINISHED',
            'runId': 'r',
            'threadId': 't1',
            'outcome': <String, dynamic>{'type': 'success'},
          };
        },
        joinRun: (runId, {signal}) async* {
          joined.add(runId);
          yield <String, dynamic>{
            'type': 'TEXT_MESSAGE_START',
            'messageId': 'joined-a1',
            'role': 'assistant',
          };
          yield <String, dynamic>{
            'type': 'TEXT_MESSAGE_CONTENT',
            'messageId': 'joined-a1',
            'delta': 'rejoined',
          };
          yield <String, dynamic>{
            'type': 'RUN_FINISHED',
            'runId': runId,
            'threadId': 't1',
            'outcome': <String, dynamic>{'type': 'success'},
          };
        },
        hydrate: (threadId, {options}) async => const conn.ChatHydrationResult(
          messages: <conn.WireMessage>[
            <String, dynamic>{
              'id': 'server-u1',
              'role': 'user',
              'parts': <Map<String, dynamic>>[
                <String, dynamic>{'type': 'text', 'content': 'hi'},
              ],
            },
          ],
          activeRun: conn.ActiveRun('run-1'),
        ),
      );
      final client = ChatClient(
        connection: connection,
        options: const ChatClientOptions(threadId: 't1', persistence: true),
      );
      await client.attach();
      await waitFor(() => joined.isNotEmpty);
      await waitFor(() => client.getMessages().any((m) => m.id == 'joined-a1'));
      expect(joined.single, 'run-1');
      expect(
        client.getMessages().firstWhere((m) => m.id == 'joined-a1').answer,
        'rejoined',
      );
    });

    test('subscribe/send connection streams chunks to the processor', () async {
      final queue = StreamController<Map<String, dynamic>>.broadcast();
      final connection = conn.ConnectionAdapter(
        subscribe: ({signal}) => queue.stream,
        send: (messages, {data, signal, runContext}) async {
          queue.add(<String, dynamic>{
            'type': 'RUN_STARTED',
            'runId': runContext!.runId,
            'threadId': runContext.threadId,
          });
          queue.add(<String, dynamic>{
            'type': 'TEXT_MESSAGE_START',
            'messageId': 'live-a1',
            'role': 'assistant',
          });
          queue.add(<String, dynamic>{
            'type': 'TEXT_MESSAGE_CONTENT',
            'messageId': 'live-a1',
            'delta': 'live',
          });
          queue.add(<String, dynamic>{
            'type': 'RUN_FINISHED',
            'runId': runContext.runId,
            'threadId': runContext.threadId,
            'outcome': <String, dynamic>{'type': 'success'},
          });
        },
      );
      final client = ChatClient(connection: connection);
      await client.sendText('hello');
      await waitFor(() => client.getMessages().any((m) => m.id == 'live-a1'));
      expect(
        client.getMessages().firstWhere((m) => m.id == 'live-a1').answer,
        'live',
      );
      await queue.close();
    });

    test('advertises client tools and forwarded props on the run context',
        () async {
      conn.RunAgentInputContext? seen;
      final connection = conn.ConnectionAdapter(
        connect: (messages, {data, signal, runContext}) async* {
          seen = runContext;
          yield <String, dynamic>{
            'type': 'RUN_FINISHED',
            'runId': runContext!.runId,
            'threadId': runContext.threadId,
            'outcome': <String, dynamic>{'type': 'success'},
          };
        },
      );
      final client = ChatClient(
        connection: connection,
        tools: const <ChatClientTool>[
          ChatClientTool(name: 'lookup', description: 'Find records'),
        ],
        forwardedProps: <String, dynamic>{'model': 'test'},
      );
      await client.sendText('hi');
      expect(seen!.clientTools!.single.name, 'lookup');
      expect(seen!.clientTools!.single.description, 'Find records');
      expect(seen!.forwardedProps, <String, dynamic>{
        'model': 'test',
      });
    });
  });
}
