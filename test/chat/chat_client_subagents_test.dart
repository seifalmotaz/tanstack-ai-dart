// Upstream reference: packages/ai-client/tests/chat-client-subagents.test.ts
import 'dart:async';

import 'package:tanstack_ai_dart/chat.dart';
import 'package:tanstack_ai_dart/connections.dart' as conn;
import 'package:test/test.dart';

import 'support.dart';

Map<String, dynamic> runStarted([String runId = 'run-1']) => <String, dynamic>{
      'type': 'RUN_STARTED',
      'runId': runId,
      'threadId': 'thread-1',
    };

Map<String, dynamic> subagentStarted({
  String id = 'sub-1',
  String name = 'researcher',
  Map<String, dynamic>? metadata,
}) =>
    <String, dynamic>{
      'type': 'SUBAGENT_STARTED',
      'subagentRunId': id,
      'name': name,
      if (metadata != null) 'metadata': metadata,
    };

Map<String, dynamic> childTextStart(String id) => <String, dynamic>{
      'type': 'TEXT_MESSAGE_START',
      'messageId': '$id-m',
      'role': 'assistant',
      'subagentRunId': id,
    };

Map<String, dynamic> childTextContent(String id, String delta) =>
    <String, dynamic>{
      'type': 'TEXT_MESSAGE_CONTENT',
      'messageId': '$id-m',
      'delta': delta,
      'subagentRunId': id,
    };

Map<String, dynamic> childTextEnd(String id) => <String, dynamic>{
      'type': 'TEXT_MESSAGE_END',
      'messageId': '$id-m',
      'subagentRunId': id,
    };

Map<String, dynamic> subagentFinished({String id = 'sub-1'}) =>
    <String, dynamic>{
      'type': 'SUBAGENT_FINISHED',
      'subagentRunId': id,
      'outcome': <String, dynamic>{'type': 'success'},
    };

Map<String, dynamic> runFinished([String runId = 'run-1']) => <String, dynamic>{
      'type': 'RUN_FINISHED',
      'runId': runId,
      'threadId': 'thread-1',
      'outcome': <String, dynamic>{'type': 'success'},
    };

ChatClient clientFor(List<Map<String, dynamic>> chunks) => ChatClient(
      connection: conn.ConnectionAdapter(
        connect: (messages, {data, signal, runContext}) async* {
          for (final chunk in chunks) {
            yield chunk;
          }
        },
      ),
    );

AssistantPart subagentPart(ChatClient client) => client
    .getMessages()
    .firstWhere((message) => message.role == 'assistant')
    .parts
    .firstWhere((part) => part.type == 'subagent');

void main() {
  group('ChatClient subagents', () {
    test(
        'keeps useChat.subagents and part.subagent as the same object with stop',
        () async {
      final client = clientFor(<Map<String, dynamic>>[
        runStarted(),
        subagentStarted(),
        childTextStart('sub-1'),
        childTextContent('sub-1', 'Hello'),
        childTextEnd('sub-1'),
        subagentFinished(),
        runFinished(),
      ]);
      await client.sendText('hi');
      await waitFor(() => client.getSubagents().isNotEmpty);

      final part = subagentPart(client);
      final subagents = client.getSubagents();
      expect(subagents, hasLength(1));
      expect(identical(part.subagent, subagents.first), isTrue);
      expect(subagents.first.stop, isA<void Function()>());
      expect(subagents.first.name, 'researcher');
      await pump(8);
      expect(subagents.first.status, 'finished');
    });

    test('gives the handle the checked input from the card metadata', () async {
      final client = clientFor(<Map<String, dynamic>>[
        runStarted(),
        subagentStarted(
          metadata: <String, dynamic>{
            'tanstack': <String, dynamic>{
              'subagentInput': <String, dynamic>{'task': 'Find squids'},
            },
          },
        ),
        childTextStart('sub-1'),
        childTextContent('sub-1', 'Hello'),
        childTextEnd('sub-1'),
        subagentFinished(),
        runFinished(),
      ]);
      await client.sendText('hi');
      await waitFor(() => client.getSubagents().isNotEmpty);
      expect(client.getSubagents().first.input, <String, dynamic>{
        'task': 'Find squids',
      });
    });

    test('keeps status error after stop when SUBAGENT_FINISHED arrives later',
        () async {
      final gate = Completer<void>();
      final client = ChatClient(
        connection: conn.ConnectionAdapter(
          connect: (messages, {data, signal, runContext}) async* {
            yield runStarted();
            yield subagentStarted();
            await gate.future;
            if (signal?.isCancelled ?? false) return;
            yield childTextStart('sub-1');
            yield childTextContent('sub-1', 'late');
            yield subagentFinished();
            yield runFinished();
          },
        ),
      );
      final send = client.sendText('hi');
      await waitFor(() => client.getSubagents().isNotEmpty);
      final handle = client.getSubagents().first;
      final part = subagentPart(client);
      expect(identical(handle, part.subagent), isTrue);
      handle.stop();
      expect(handle.status, 'error');
      expect(handle.error, <String, dynamic>{'message': 'Stopped'});

      gate.complete();
      await pump(8);
      expect(identical(handle, part.subagent), isTrue);
      expect(handle.status, 'error');
      expect(part.subagent!['status'], 'error');
      expect(handle.messages, isEmpty);
      await send;
    });

    test('aborts a hanging child on stop so no later child text arrives',
        () async {
      final gate = Completer<void>();
      var aborted = false;
      final client = ChatClient(
        connection: conn.ConnectionAdapter(
          connect: (messages, {data, signal, runContext}) async* {
            yield runStarted();
            yield subagentStarted();
            yield childTextStart('sub-1');
            yield childTextContent('sub-1', 'partial');
            signal?.addListener(() {
              aborted = true;
              if (!gate.isCompleted) gate.complete();
            });
            await gate.future;
            if (signal?.isCancelled ?? false) return;
            yield childTextContent('sub-1', 'late');
            yield runFinished();
          },
        ),
      );
      final send = client.sendText('hi');
      await waitFor(() => client.getSubagents().isNotEmpty);
      client.getSubagents().first.stop();
      await pump(8);
      expect(aborted, isTrue);
      expect(
          client.getSubagents().first.messages.join(), isNot(contains('late')));
      await client.dispose();
      await send;
    });

    test('gives restored cards a handle, and drops it after clear()', () {
      final client = ChatClient(
        transport: FakeChatTransport(),
        messages: <AssistantTurn>[
          AssistantTurn(
            id: 'a1',
            role: 'assistant',
            parts: <AssistantPart>[
              AssistantPart(
                type: 'subagent',
                id: 'sub-restored',
                subagent: <String, dynamic>{
                  'id': 'sub-restored',
                  'name': 'researcher',
                  'status': 'finished',
                  'messages': <dynamic>[],
                  'metadata': <String, dynamic>{
                    'tanstack': <String, dynamic>{
                      'subagentInput': <String, dynamic>{'task': 'Saved'},
                    },
                  },
                },
              ),
            ],
          ),
        ],
      );
      final handle = client.getSubagents().single;
      expect(handle.id, 'sub-restored');
      expect(handle.name, 'researcher');
      expect(handle.input, <String, dynamic>{'task': 'Saved'});
      expect(identical(client.getMessages().first.parts.first.subagent, handle),
          isTrue);
      client.clear();
      expect(client.getSubagents(), isEmpty);
    });

    test('accepts frozen snapshot messages back without throwing', () {
      final client = ChatClient(
        transport: FakeChatTransport(),
        messages: <AssistantTurn>[
          AssistantTurn(
            id: 'a1',
            role: 'assistant',
            parts: <AssistantPart>[
              AssistantPart(
                type: 'subagent',
                id: 'sub-restored',
                subagent: <String, dynamic>{
                  'id': 'sub-restored',
                  'name': 'researcher',
                  'status': 'finished',
                  'messages': <dynamic>[],
                },
              ),
            ],
          ),
        ],
      );
      final saved = client.getSnapshot().messages;
      client.clear();
      client.setMessagesManually(<AssistantTurn>[...saved]);
      expect(client.getSubagents().single.stop, isA<void Function()>());
    });
  });
}
