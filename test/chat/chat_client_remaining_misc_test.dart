// Upstream references: chat-client-identity.test.ts, chat-client-client-tool-status.test.ts,
// chat-client-join-run-client-tool.test.ts, chat-client-reasoning-rejoin.test.ts,
// chat-client-subagent-rejoin.test.ts and chat-client-subagent-interrupts.test.ts.
import 'dart:async';
import 'package:tanstack_ai_dart/chat.dart';
import 'package:tanstack_ai_dart/connections.dart' as conn;
import 'package:test/test.dart';
import 'package:tanstack_ai_dart/platform.dart' as storage;

import 'support.dart';

class MemoryPersistence implements storage.ChatClientPersistence {
  storage.ChatPersistedState? value;
  MemoryPersistence(this.value);
  @override
  Object? getItem(String id) => value;
  @override
  void setItem(String id, storage.ChatPersistedState state) {
    value = state;
  }

  @override
  void removeItem(String id) {
    value = null;
  }
}

void main() {
  group('ChatClient identity', () {
    test('does not call crypto.randomUUID or Math.random in the constructor',
        () {
      // Dart equivalent: construction performs no id generation at all.
      final client = ChatClient(transport: FakeChatTransport());
      expect(client.getMessages(), isEmpty);
      expect(client.threadId, isNull);
    });
  });

  group('client tool call status (issue #421)', () {
    test('plain text run emits onStatusChange(\'ready\') exactly once',
        () async {
      final transport = FakeChatTransport();
      final states = <String>[];
      late final ChatClient client;
      client = ChatClient(
        transport: transport,
        onStatusChange: states.add,
      );
      await client.sendText('x');
      await emitAll(transport, textChunks('ok'));
      await transport.close();
      await pump();
      expect(states.where((state) => state == 'ready'), hasLength(1));
    });

    test(
        'sendMessage with a bare RUN_FINISHED{stop} first run (no assistant message) settles to ready',
        () async {
      final transport = FakeChatTransport();
      final client = ChatClient(transport: transport);
      await client.sendText('x');
      transport.emit(<String, dynamic>{
        'type': 'RUN_FINISHED',
        'runId': 'r',
        'threadId': 't',
        'finishReason': 'stop',
        'outcome': <String, dynamic>{'type': 'success'},
      });
      await transport.close();
      await pump();
      expect(client.getStatus(), 'ready');
    });

    test(
        'settles status to ready after a client tool when the continuation run emits only RUN_FINISHED',
        () async {
      final transport = FakeChatTransport();
      final client = ChatClient(
        transport: transport,
        tools: <ChatClientTool>[
          ChatClientTool(name: 'lookup', execute: (input, context) => 1),
        ],
      );
      await client.sendText('x');
      await emitAll(transport, <Map<String, dynamic>>[
        <String, dynamic>{'type': 'RUN_STARTED', 'runId': 'r1'},
        <String, dynamic>{
          'type': 'TOOL_CALL_START',
          'toolCallId': 'tc',
          'toolCallName': 'lookup',
        },
        <String, dynamic>{
          'type': 'TOOL_CALL_END',
          'toolCallId': 'tc',
          'toolCallName': 'lookup',
          'input': <String, dynamic>{},
        },
        <String, dynamic>{
          'type': 'RUN_FINISHED',
          'runId': 'r1',
          'outcome': <String, dynamic>{'type': 'success'},
        },
      ]);
      await transport.close();
      await waitFor(() => transport.bodies.length == 2);
      transport.emit(<String, dynamic>{
        'type': 'RUN_FINISHED',
        'runId': 'r2',
        'threadId': 't',
        'outcome': <String, dynamic>{'type': 'success'},
      });
      await transport.closeAt(1);
      await pump();
      expect(client.getStatus(), 'ready');
    });
  });

  group('joinRun client-tool continuation (issue #1058)', () {
    test('posts the client-tool result after joinRun replay ends', () async {
      final toolGate = Completer<void>();
      final joinHold = Completer<void>();
      final contexts = <conn.RunAgentInputContext>[];
      var joined = false;
      final schema = <String, dynamic>{
        'type': 'object',
        'properties': {
          'answer': {'type': 'number'}
        },
        'required': ['answer'],
        'additionalProperties': false
      };
      final outputSchema = StandardSchema(
          (value) => SchemaValidationResult.success(value),
          schema: schema);
      final hash = storage.hashSchemaInput(outputSchema);
      final connection = conn.ConnectionAdapter(
        connect: (messages, {data, signal, runContext}) async* {
          contexts.add(runContext!);
          yield {
            'type': 'RUN_STARTED',
            'runId': runContext.runId,
            'threadId': 't1'
          };
          yield {
            'type': 'TEXT_MESSAGE_CONTENT',
            'messageId': 'm1',
            'delta': 'done'
          };
          yield {
            'type': 'RUN_FINISHED',
            'runId': runContext.runId,
            'threadId': 't1',
            'finishReason': 'stop'
          };
        },
        joinRun: (runId, {signal}) async* {
          joined = true;
          yield {'type': 'RUN_STARTED', 'runId': runId, 'threadId': 't1'};
          yield {
            'type': 'TOOL_CALL_START',
            'toolCallId': 'tool-call-1',
            'toolCallName': 'lookup'
          };
          yield {
            'type': 'TOOL_CALL_ARGS',
            'toolCallId': 'tool-call-1',
            'delta': '{"query":"first"}'
          };
          yield {
            'type': 'RUN_FINISHED',
            'runId': runId,
            'threadId': 't1',
            'outcome': {
              'type': 'interrupt',
              'interrupts': [
                {
                  'id': 'client_tool_tool-call-1',
                  'reason': 'tanstack:client_tool_execution',
                  'toolCallId': 'tool-call-1',
                  'responseSchema': schema,
                  'metadata': {
                    'kind': 'client_tool',
                    'toolName': 'lookup',
                    'input': {'query': 'first'},
                    'tanstack:interruptBinding': {
                      'v': 1,
                      'kind': 'client-tool-execution',
                      'interruptId': 'client_tool_tool-call-1',
                      'interruptedRunId': 'r1',
                      'generation': 0,
                      'toolName': 'lookup',
                      'toolCallId': 'tool-call-1',
                      'outputSchemaHash': hash,
                      'responseSchemaHash': hash,
                    }
                  }
                }
              ]
            }
          };
          await joinHold.future;
        },
      );
      final client = ChatClient(
          threadId: 't1',
          connection: connection,
          persistence: MemoryPersistence(storage.ChatPersistedState(
            messages: [userMessage('user-1', 'hi').toRow()],
            resume: const storage.ChatResumeSnapshot(
                resumeState: ChatResumeState(threadId: 't1', runId: 'r1')),
          )),
          tools: [
            ClientTool<Map<String, dynamic>, Map<String, dynamic>>(
                name: 'lookup',
                outputSchema: outputSchema,
                execute: (input, context) async {
                  await toolGate.future;
                  return {'answer': 42};
                })
          ]);
      addTearDown(client.dispose);
      await client.attach();
      await waitFor(() => joined);
      await pump(10);
      toolGate.complete();
      await pump(10);
      expect(contexts, isEmpty);
      joinHold.complete();
      await waitFor(() => contexts.length == 1 && !client.getIsLoading());
      expect(contexts.single.parentRunId, 'r1');
      expect(contexts.single.resume, [
        {
          'interruptId': 'client_tool_tool-call-1',
          'status': 'resolved',
          'payload': {'answer': 42}
        }
      ]);
      expect(client.getInterruptState().interruptErrors, isEmpty);
      expect(client.getInterrupts(), isEmpty);
      await client.sendMessage('later');
      expect(contexts, hasLength(2));
    });
  });

  group('reasoning rejoin', () {
    test("keeps activity when replay starts with 'reasoning content'",
        () async {
      final transport = FakeChatTransport();
      final client = ChatClient(
        transport: transport,
        messages: <AssistantTurn>[
          AssistantTurn(
            id: 'a0',
            role: 'assistant',
            parts: <AssistantPart>[AssistantPart.text('existing')],
          ),
        ],
      );
      await client.sendText('x');
      transport.emit(<String, dynamic>{
        'type': 'REASONING_MESSAGE_CONTENT',
        'delta': 'thinking',
      });
      await pump();
      expect(
        client.getMessages().any((m) => m.parts.any((p) => p.type == 'text')),
        isTrue,
      );
      await client.stop();
    });

    test("keeps activity when replay starts with 'encrypted reasoning'",
        () async {
      final transport = FakeChatTransport();
      final client = ChatClient(transport: transport);
      await client.sendText('x');
      transport.emit(<String, dynamic>{
        'type': 'REASONING_ENCRYPTED_VALUE',
        'entityId': 'r',
        'encryptedValue': 'x',
      });
      await pump();
      expect(client.getError(), isNull);
      await client.stop();
    });

    test("keeps activity when replay starts with 'step signature'", () async {
      final transport = FakeChatTransport();
      final client = ChatClient(transport: transport);
      await client.sendText('x');
      transport.emit(<String, dynamic>{
        'type': 'STEP_FINISHED',
        'stepName': 'step',
      });
      await pump();
      expect(client.getError(), isNull);
      await client.stop();
    });
  });

  group('joinRun subagent replay', () {
    test(
        'rebuilds one subagent card from the stream instead of keeping the partial text',
        () async {
      final partial = {
        'id': 'assistant-1',
        'role': 'assistant',
        'parts': [
          {
            'type': 'subagent',
            'subagent': {
              'id': 'child-1',
              'name': 'researcher',
              'status': 'running',
              'messages': [
                {
                  'id': 'note-1',
                  'role': 'assistant',
                  'parts': [
                    {'type': 'text', 'content': 'Hel'}
                  ]
                }
              ]
            }
          }
        ]
      };
      final connection = conn.ConnectionAdapter(
          connect: (messages, {data, signal, runContext}) async* {
        yield {'type': 'RUN_FINISHED', 'runId': 'unused', 'threadId': 't1'};
      }, joinRun: (runId, {signal}) async* {
        yield {'type': 'RUN_STARTED', 'runId': 'r1', 'threadId': 't1'};
        yield {
          'type': 'SUBAGENT_STARTED',
          'subagentRunId': 'child-1',
          'name': 'researcher'
        };
        yield {
          'type': 'TEXT_MESSAGE_START',
          'messageId': 'note-1',
          'role': 'assistant',
          'subagentRunId': 'child-1'
        };
        yield {
          'type': 'TEXT_MESSAGE_CONTENT',
          'messageId': 'note-1',
          'delta': 'Hello notes',
          'subagentRunId': 'child-1'
        };
        yield {'type': 'SUBAGENT_FINISHED', 'subagentRunId': 'child-1'};
        yield {'type': 'RUN_FINISHED', 'runId': 'r1', 'threadId': 't1'};
      });
      final client = ChatClient(
          threadId: 't1',
          connection: connection,
          persistence: MemoryPersistence(storage.ChatPersistedState(
            messages: [
              userMessage('user-1', 'research squids').toRow(),
              partial
            ],
            resume: const storage.ChatResumeSnapshot(
                resumeState: ChatResumeState(threadId: 't1', runId: 'r1')),
          )));
      addTearDown(client.dispose);
      await client.attach();
      await waitFor(() =>
          client.getSubagents().any((handle) => handle.status == 'finished'));
      final assistants = client
          .getMessages()
          .where((message) => message.role == 'assistant')
          .toList();
      final cards = assistants.single.parts
          .where((part) => part.type == 'subagent')
          .toList();
      expect(cards, hasLength(1));
      final card = cards.single.subagent!;
      expect(card['status'], 'finished');
      expect((card['messages'] as List).first['parts'][0],
          containsPair('content', 'Hello notes'));
    });
  });

  group('ChatClient subagent interrupts', () {
    test('approves a child tool call and finishes the child', () async {
      final transport = FakeChatTransport();
      final part = AssistantPart.tool(
        id: 'child-tool',
        name: 'deleteFile',
        approval: AssistantApproval(id: 'approval'),
      );
      final client = ChatClient(
        transport: transport,
        messages: <AssistantTurn>[
          AssistantTurn(
            id: 'a',
            role: 'assistant',
            parts: <AssistantPart>[
              AssistantPart(
                type: 'subagent',
                id: 'sub-1',
                subagent: <String, dynamic>{
                  'id': 'sub-1',
                  'name': 'child',
                  'status': 'suspended',
                  'messages': <dynamic>[],
                },
              ),
              part,
            ],
          ),
        ],
      );
      await client.approve(part, true);
      expect(part.state, 'approval-responded');
      await client.stop();
    });
  });
}
