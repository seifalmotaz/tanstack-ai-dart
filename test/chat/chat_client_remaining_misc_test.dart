// Upstream references: chat-client-identity.test.ts, chat-client-client-tool-status.test.ts,
// chat-client-join-run-client-tool.test.ts, chat-client-reasoning-rejoin.test.ts,
// chat-client-subagent-rejoin.test.ts and chat-client-subagent-interrupts.test.ts.
import 'dart:async';
import 'dart:convert';

import '../processing/subagent_upstream_fixture.dart';
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
      final client = ChatClient.legacy(transport: FakeChatTransport());
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
      client = ChatClient.legacy(
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
      final client = ChatClient.legacy(transport: transport);
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
      final client = ChatClient.legacy(
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
      final connection = conn.ConnectionAdapter.connect(
        connect: (messages, {data, signal, required runContext}) async* {
          contexts.add(runContext);
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
      final client = ChatClient.legacy(
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
      await client.sendLegacyMessage('later');
      expect(contexts, hasLength(2));
    });
  });

  group('reasoning rejoin', () {
    test("keeps activity when replay starts with 'reasoning content'",
        () async {
      final transport = FakeChatTransport();
      final client = ChatClient.legacy(
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
      final client = ChatClient.legacy(transport: transport);
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
      final client = ChatClient.legacy(transport: transport);
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

  for (final encrypted in [false, true]) {
    test(
        'modern reasoning rejoin preserves replay activity (encrypted: $encrypted)',
        () async {
      List<conn.WireMessage>? sent;
      final connection = conn.ConnectionAdapter.connect(
          hydrate: (_, {options}) async =>
              const conn.ChatHydrationResult(messages: [
                {
                  'id': 'u1',
                  'role': 'user',
                  'parts': [
                    {'type': 'text', 'content': 'Build an app.'}
                  ]
                },
                {
                  'id': 'partial',
                  'role': 'assistant',
                  'parts': [
                    {'type': 'thinking', 'content': 'Inspect'}
                  ]
                },
              ], activeRun: conn.ActiveRun('r1')),
          joinRun: (runId, {signal}) async* {
            yield {'type': 'RUN_STARTED', 'runId': 'r1', 'threadId': 't1'};
            yield encrypted
                ? {
                    'type': 'REASONING_ENCRYPTED_VALUE',
                    'subtype': 'message',
                    'entityId': 'thinking',
                    'encryptedValue': 'signature'
                  }
                : {
                    'type': 'REASONING_MESSAGE_CONTENT',
                    'messageId': 'thinking',
                    'delta': 'Inspect the files.'
                  };
            yield {
              'type': 'TOOL_CALL_START',
              'toolCallId': 'read',
              'toolCallName': 'Read'
            };
            yield {
              'type': 'TOOL_CALL_ARGS',
              'toolCallId': 'read',
              'delta': '{}'
            };
            yield {'type': 'TOOL_CALL_END', 'toolCallId': 'read'};
            yield {
              'type': 'TOOL_CALL_RESULT',
              'toolCallId': 'read',
              'messageId': 'result',
              'content': 'file contents'
            };
            yield {
              'type': 'TEXT_MESSAGE_START',
              'messageId': 'reply',
              'role': 'assistant'
            };
            yield {
              'type': 'TEXT_MESSAGE_CONTENT',
              'messageId': 'reply',
              'delta': 'Built the app.'
            };
            yield {'type': 'TEXT_MESSAGE_END', 'messageId': 'reply'};
            yield {'type': 'RUN_FINISHED', 'runId': 'r1', 'threadId': 't1'};
          },
          connect: (messages, {data, signal, required runContext}) async* {
            sent = messages;
            yield {
              'type': 'RUN_FINISHED',
              'runId': runContext.runId,
              'threadId': runContext.threadId,
              'outcome': {'type': 'success'}
            };
          });
      final client = ChatClient(
          connection: connection,
          threadId: 't1',
          persistence: const ChatPersistenceOptions.server());
      await client.attach();
      await waitFor(() => client.getMessages().any((message) => message.parts
          .any((part) =>
              part.type == 'text' && part.content == 'Built the app.')));
      await client.sendText('Change the title.');
      final rows = sent!;
      final parts =
          rows.expand((row) => row['parts'] as List).cast<Map>().toList();
      expect(
          parts.any((part) =>
              part['type'] == 'thinking' &&
              part['content'] == (encrypted ? '' : 'Inspect the files.')),
          isTrue);
      expect(
          parts.any((part) =>
              part['type'] == 'tool-call' &&
              part['id'] == 'read' &&
              part['output'] == 'file contents'),
          isTrue);
      expect(
          parts.any((part) =>
              part['type'] == 'text' && part['content'] == 'Built the app.'),
          isTrue);
      expect(rows.any((row) => row['id'] == 'partial'), isFalse);
      await client.dispose();
    });
  }

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
      final connection = conn.ConnectionAdapter.connect(
          connect: (messages, {data, signal, required runContext}) async* {
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
      final client = ChatClient.legacy(
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
      final batches = jsonDecode(upstreamSubagentFixture) as List;
      final contexts = <conn.RunAgentInputContext>[];
      final connection = conn.ConnectionAdapter.connect(
          connect: (_, {data, signal, required runContext}) async* {
        contexts.add(runContext);
        final index = contexts.length - 1;
        final encoded = jsonEncode(batches[index])
            .replaceAll('run-${index + 1}', runContext.runId);
        for (final chunk in jsonDecode(encoded) as List) {
          yield Map<String, dynamic>.from(chunk as Map);
        }
      });
      const schema = RawJsonSchema({
        r'$schema': 'https://json-schema.org/draft/2020-12/schema',
        'type': 'object',
        'properties': {
          'path': {'type': 'string'}
        },
        'required': ['path'],
      });
      final client = ChatClient(connection: connection, threadId: 't', tools: [
        ClientTool<dynamic, dynamic>(
            name: 'deleteFile', needsApproval: true, inputSchema: schema),
      ]);
      await client.sendText('Clean up');
      expect(client.getInterrupts(), hasLength(1));
      final interrupt = client.getInterrupts().single;
      expect(interrupt.kind, 'tool-approval');
      expect(client.getSubagents().single.name, 'cleaner');
      expect(client.getSubagents().single.status, 'suspended');
      expect(client.getSubagents().single['interruptIds'],
          contains('approval_call_c'));
      interrupt.resolveApproval(true);
      await waitFor(() => contexts.length == 2 && !client.isLoading);
      expect(contexts.last.parentRunId, contexts.first.runId);
      expect(contexts.last.resume!.single['payload'], {'approved': true});
      expect(client.getInterrupts(), isEmpty);
      final card = client.getSubagents().single;
      expect(card.status, 'finished');
      final parts = card.messages
          .expand((message) => (message as Map)['parts'] as List)
          .cast<Map>()
          .toList();
      expect(
          parts.any(
              (part) => part['type'] == 'tool-call' && part['id'] == 'call_c'),
          isTrue);
      expect(
          parts.any((part) =>
              part['type'] == 'text' && part['content'] == 'Deleted a'),
          isTrue);
      await client.dispose();
    });
  });
}
