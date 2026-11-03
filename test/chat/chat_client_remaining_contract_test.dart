// Upstream references: chat-client-context.test.ts, chat-client-interrupts.test.ts,
// chat-client-resume.test.ts, chat-client-subagents.test.ts and chat-client.test.ts.
import 'dart:async';

import 'package:tanstack_ai_dart/chat.dart';
import 'package:tanstack_ai_dart/platform.dart' as platform;
import 'package:test/test.dart';
import 'package:tanstack_ai_dart/connections.dart' as connections;

import 'support.dart';

ChatClient interrupted(
  FakeChatTransport transport, {
  List<Map<String, dynamic>>? interrupts,
}) {
  final client = ChatClient.legacy(
    transport: transport,
    options: const ChatClientOptions(threadId: 'thread-1'),
  );
  unawaited(() async {
    await client.sendText('hi');
    await emitAll(transport, <Map<String, dynamic>>[
      <String, dynamic>{'type': 'RUN_STARTED', 'runId': 'r1'},
      <String, dynamic>{
        'type': 'RUN_FINISHED',
        'runId': 'r1',
        'threadId': 'thread-1',
        'outcome': <String, dynamic>{
          'type': 'interrupt',
          'interrupts': interrupts ??
              <Map<String, dynamic>>[
                <String, dynamic>{
                  'id': 'i1',
                  'reason': 'approval_required',
                  'metadata': <String, dynamic>{
                    'kind': 'approval',
                    'toolName': 'confirm',
                    'input': <String, dynamic>{},
                  },
                },
              ],
        },
      },
    ]);
    await transport.close();
  }());
  return client;
}

void main() {
  group('ChatClient runtime context', () {
    test(
        'uses the per-run context snapshot for in-flight client tool execution',
        () async {
      final transport = FakeChatTransport();
      final contexts = <Object?>[];
      final client = ChatClient.legacy(
        transport: transport,
        context: <String, dynamic>{'run': 1},
        tools: <ChatClientTool>[
          ChatClientTool(
            name: 'lookup',
            execute: (input, context) {
              contexts.add(context);
              return 1;
            },
          ),
        ],
      );
      await client.sendText('hi');
      await emitAll(transport, <Map<String, dynamic>>[
        <String, dynamic>{'type': 'RUN_STARTED', 'runId': 'r'},
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
      ]);
      client.updateLegacyOptions(context: <String, dynamic>{'run': 2});
      await pump(8);
      expect(contexts.first, <String, dynamic>{'run': 1});
      await client.stop();
    });

    test(
        'uses the per-run client tool snapshot for automatic result validation',
        () async {
      final transport = FakeChatTransport();
      final client = ChatClient.legacy(
        transport: transport,
        tools: <ChatClientTool>[
          ChatClientTool(
            name: 'lookup',
            execute: (input, context) => 1,
            validateOutput: (output) {
              if (output != 1) throw StateError('bad');
            },
          ),
        ],
      );
      await client.sendText('hi');
      client.updateLegacyOptions(body: <String, dynamic>{'changed': true});
      await emitAll(transport, <Map<String, dynamic>>[
        <String, dynamic>{'type': 'RUN_STARTED', 'runId': 'r'},
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
      ]);
      await pump(8);
      final tool = client
          .getMessages()
          .expand((m) => m.parts)
          .firstWhere((p) => p.type == 'tool-call');
      expect(tool.state, 'complete');
      await client.stop();
    });
  });

  group('ChatClient native interrupts', () {
    test('does not continue when a native resume is queued before Stop',
        () async {
      final transport = FakeChatTransport();
      final client = interrupted(transport);
      await pump();
      await client.stop();
      expect(client.getInterrupts(), isEmpty);
      expect(transport.bodies, hasLength(1));
    });

    test('does not auto-send after rejecting an afterTools generic interrupt',
        () async {
      final transport = FakeChatTransport();
      final client = interrupted(
        transport,
        interrupts: <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'i1',
            'reason': 'choose',
            'metadata': <String, dynamic>{'kind': 'generic'},
          },
        ],
      );
      await pump();
      final interrupt = client.getInterrupts().single;
      interrupt.resolveInterrupt(<String, dynamic>{'reject': true});
      await pump(8);
      expect(client.getInterrupts(), isNotEmpty);
      expect(transport.bodies, hasLength(1));
      await client.stop();
    });

    test('resumes a hydrated ephemeral batch in a fresh child run', () async {
      final transport = FakeChatTransport();
      final client = interrupted(transport);
      await pump();
      await client.resumeInterruptsLegacy(<Map<String, dynamic>>[
        <String, dynamic>{'interruptId': 'i1', 'status': 'resolved'},
      ]);
      final ids = (transport.bodies[1]['messages'] as List)
          .map((row) => (row as Map)['id'])
          .toList();
      expect(ids, contains(client.getMessages().first.id));
      await client.stop();
    });
  });

  test('continues a frontend tool call emitted by a native resume', () async {
    final contexts = <connections.RunAgentInputContext>[];
    final inputs = <Object?>[];
    final connection = connections.ConnectionAdapter.connect(
        connect: (_, {data, signal, required runContext}) async* {
      contexts.add(runContext);
      final index = contexts.length;
      yield {
        'type': 'RUN_STARTED',
        'runId': runContext.runId,
        'threadId': runContext.threadId
      };
      if (index == 1) {
        yield {
          'type': 'RUN_FINISHED',
          'runId': runContext.runId,
          'threadId': runContext.threadId,
          'outcome': {
            'type': 'interrupt',
            'interrupts': [
              {
                'id': 'interrupt-1',
                'reason': 'confirmation',
                'metadata': {
                  'tanstack:interruptBinding': {
                    'v': 1,
                    'kind': 'generic',
                    'interruptId': 'interrupt-1',
                    'interruptedRunId': runContext.runId,
                    'generation': 0,
                    'responseSchemaHash': 'none'
                  }
                }
              }
            ]
          }
        };
      } else if (index == 2) {
        yield {
          'type': 'TOOL_CALL_START',
          'toolCallId': 'frontend-tool-call',
          'toolCallName': 'lookup'
        };
        yield {
          'type': 'TOOL_CALL_ARGS',
          'toolCallId': 'frontend-tool-call',
          'delta': '{"query":"answer"}'
        };
        yield {
          'type': 'RUN_FINISHED',
          'runId': runContext.runId,
          'threadId': runContext.threadId,
          'outcome': {'type': 'success'}
        };
      } else {
        yield {
          'type': 'TEXT_MESSAGE_CONTENT',
          'messageId': 'done',
          'delta': 'done'
        };
        yield {
          'type': 'RUN_FINISHED',
          'runId': runContext.runId,
          'threadId': runContext.threadId,
          'outcome': {'type': 'success'}
        };
      }
    });
    final client =
        ChatClient(connection: connection, threadId: 'thread-1', tools: [
      ClientTool<dynamic, dynamic>(
          name: 'lookup',
          execute: (input, _) {
            inputs.add(input);
            return {'answer': 42};
          })
    ]);
    await client.sendText('hi');
    client.getInterrupts().single.resolveInterrupt({'answer': 'continue'});
    await waitFor(() => contexts.length == 3);
    expect(inputs, [
      {'query': 'answer'}
    ]);
    expect(contexts[1].parentRunId, contexts[0].runId);
    expect(contexts[1].resume!.single['interruptId'], 'interrupt-1');
    expect(contexts[2].resume, isNull);
    await client.dispose();
  });

  test('modern auto tool defers a bound resume until parent stream settles',
      () async {
    final contexts = <connections.RunAgentInputContext>[];
    const schema = RawJsonSchema({
      'type': 'object',
      'properties': {
        'answer': {'type': 'number'}
      },
      'required': ['answer']
    });
    final responseSchema = <String, dynamic>{
      'type': 'object',
      'properties': {
        'answer': {'type': 'number'}
      },
      'required': ['answer']
    };
    final responseHash = platform
        .digestInterruptJson(platform.canonicalInterruptJson(responseSchema));
    final connection = connections.ConnectionAdapter.connect(
        connect: (_, {data, signal, required runContext}) async* {
      contexts.add(runContext);
      yield {
        'type': 'RUN_STARTED',
        'runId': runContext.runId,
        'threadId': runContext.threadId
      };
      if (contexts.length == 1) {
        yield {
          'type': 'TOOL_CALL_START',
          'toolCallId': 'call-1',
          'toolCallName': 'lookup'
        };
        yield {
          'type': 'TOOL_CALL_ARGS',
          'toolCallId': 'call-1',
          'delta': '{"query":"first"}'
        };
        yield {
          'type': 'RUN_FINISHED',
          'runId': runContext.runId,
          'threadId': runContext.threadId,
          'outcome': {
            'type': 'interrupt',
            'interrupts': [
              {
                'id': 'client-1',
                'reason': 'tanstack:client_tool_execution',
                'toolCallId': 'call-1',
                'responseSchema': responseSchema,
                'metadata': {
                  'kind': 'client_tool',
                  'toolName': 'lookup',
                  'input': {'query': 'first'},
                  'tanstack:interruptBinding': {
                    'v': 1,
                    'kind': 'client-tool-execution',
                    'interruptId': 'client-1',
                    'interruptedRunId': runContext.runId,
                    'generation': 0,
                    'toolName': 'lookup',
                    'toolCallId': 'call-1',
                    'outputSchemaHash': platform.hashSchemaInput(schema),
                    'responseSchemaHash': responseHash
                  }
                }
              }
            ]
          }
        };
      } else {
        yield {
          'type': 'RUN_FINISHED',
          'runId': runContext.runId,
          'threadId': runContext.threadId,
          'outcome': {'type': 'success'}
        };
      }
    });
    final client =
        ChatClient(connection: connection, threadId: 'thread-1', tools: [
      ClientTool<dynamic, dynamic>(
          name: 'lookup',
          outputSchema: schema,
          execute: (_, __) => {'answer': 42})
    ]);
    await client.sendText('hi');
    await waitFor(() => contexts.length == 2 && !client.isLoading);
    expect(contexts.last.parentRunId, contexts.first.runId);
    expect(contexts.last.resume, [
      {
        'interruptId': 'client-1',
        'status': 'resolved',
        'payload': {'answer': 42}
      }
    ]);
    expect(client.getInterruptState().interruptErrors, isEmpty);
    await client.dispose();
  });

  group('ChatClient resume', () {
    test('resumes canonicalization failures as client-tool output errors',
        () async {
      final contexts = <connections.RunAgentInputContext>[];
      final responseHash = platform.digestInterruptJson(
          platform.canonicalInterruptJson(<String, dynamic>{}));
      final connection = connections.ConnectionAdapter.connect(
        connect: (_, {data, signal, required runContext}) async* {
          contexts.add(runContext);
          final runId = runContext.runId;
          yield {
            'type': 'RUN_STARTED',
            'runId': runId,
            'threadId': runContext.threadId
          };
          if (contexts.length == 1) {
            yield {
              'type': 'TOOL_CALL_START',
              'toolCallId': 'tc',
              'toolCallName': 'lookup'
            };
            yield {'type': 'TOOL_CALL_ARGS', 'toolCallId': 'tc', 'delta': '{}'};
            yield {
              'type': 'RUN_FINISHED',
              'runId': runId,
              'threadId': runContext.threadId,
              'outcome': {
                'type': 'interrupt',
                'interrupts': [
                  {
                    'id': 'i1',
                    'reason': 'tanstack:client_tool_execution',
                    'toolCallId': 'tc',
                    'responseSchema': <String, dynamic>{},
                    'metadata': {
                      'kind': 'client_tool',
                      'toolName': 'lookup',
                      'input': <String, dynamic>{},
                      'tanstack:interruptBinding': {
                        'v': 1,
                        'kind': 'client-tool-execution',
                        'interruptId': 'i1',
                        'interruptedRunId': runId,
                        'generation': 0,
                        'toolName': 'lookup',
                        'toolCallId': 'tc',
                        'outputSchemaHash': platform.hashSchemaInput(null),
                        'responseSchemaHash': responseHash
                      }
                    }
                  }
                ]
              }
            };
          } else {
            yield {
              'type': 'TEXT_MESSAGE_CONTENT',
              'messageId': 'answer',
              'delta': 'continued'
            };
            yield {
              'type': 'RUN_FINISHED',
              'runId': runId,
              'threadId': runContext.threadId
            };
          }
        },
      );
      final client = ChatClient(
        connection: connection,
        threadId: 'thread-1',
        tools: <ClientTool>[
          ClientTool<dynamic, dynamic>(
              name: 'lookup', execute: (_, __) => {'value': Object()}),
        ],
      );
      await client.sendText('hi');
      await waitFor(() => contexts.length == 2);
      final resolution = contexts[1].resume!.single;
      expect(resolution['interruptId'], 'i1');
      expect((resolution['payload'] as Map)['error'], isA<String>());
      expect((resolution['metadata'] as Map)['tanstack'],
          {'state': 'output-error'});
      expect(
          client.messages
              .any((message) => message.answer.contains('continued')),
          isTrue);
      await client.dispose();
    });

    test('continues a legacy client tool emitted by a native resume', () async {
      final transport = FakeChatTransport();
      final client = interrupted(
        transport,
        interrupts: <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'i1',
            'reason': 'client_tool_input',
            'toolCallId': 'tc',
            'metadata': <String, dynamic>{
              'kind': 'client_tool',
              'toolName': 'lookup',
            },
          },
        ],
      );
      await pump();
      await client.resumeInterruptsLegacy(<Map<String, dynamic>>[
        <String, dynamic>{'interruptId': 'i1', 'status': 'resolved'},
      ]);
      expect(transport.bodies, hasLength(2));
      expect(transport.bodies[1]['parentRunId'], 'r1');
      expect(transport.bodies[1]['resume'], isNotNull);
      await client.stop();
    });

    test(
        'keeps native interrupt ownership when a sequential client tool resume fails',
        () async {
      final contexts = <connections.RunAgentInputContext>[];
      const outputSchema = RawJsonSchema({
        'type': 'object',
        'properties': {
          'answer': {'type': 'number'}
        },
        'required': ['answer']
      });
      final responseSchema = <String, dynamic>{
        'type': 'object',
        'properties': {
          'answer': {'type': 'number'}
        },
        'required': ['answer']
      };
      final responseHash = platform
          .digestInterruptJson(platform.canonicalInterruptJson(responseSchema));
      final connection = connections.ConnectionAdapter.connect(
        connect: (_, {data, signal, required runContext}) async* {
          contexts.add(runContext);
          if (contexts.length == 3) throw StateError('resume failed');
          final call = 'call-${contexts.length}';
          final query = contexts.length == 1 ? 'first' : 'second';
          final runId = runContext.runId;
          yield {
            'type': 'RUN_STARTED',
            'runId': runId,
            'threadId': runContext.threadId
          };
          yield {
            'type': 'TOOL_CALL_START',
            'toolCallId': call,
            'toolCallName': 'lookup'
          };
          yield {
            'type': 'TOOL_CALL_ARGS',
            'toolCallId': call,
            'delta': '{"query":"$query"}'
          };
          yield {
            'type': 'RUN_FINISHED',
            'runId': runId,
            'threadId': runContext.threadId,
            'outcome': {
              'type': 'interrupt',
              'interrupts': [
                {
                  'id': 'interrupt-$call',
                  'reason': 'tanstack:client_tool_execution',
                  'toolCallId': call,
                  'responseSchema': responseSchema,
                  'metadata': {
                    'kind': 'client_tool',
                    'toolName': 'lookup',
                    'input': {'query': query},
                    'tanstack:interruptBinding': {
                      'v': 1,
                      'kind': 'client-tool-execution',
                      'interruptId': 'interrupt-$call',
                      'interruptedRunId': runId,
                      'generation': 0,
                      'toolName': 'lookup',
                      'toolCallId': call,
                      'outputSchemaHash':
                          platform.hashSchemaInput(outputSchema),
                      'responseSchemaHash': responseHash
                    }
                  }
                }
              ]
            }
          };
        },
      );
      final client =
          ChatClient(connection: connection, threadId: 'thread-1', tools: [
        ClientTool<dynamic, dynamic>(
            name: 'lookup',
            outputSchema: outputSchema,
            execute: (input, _) =>
                {'answer': (input as Map)['query'] == 'first' ? 42 : 43}),
      ]);
      await client.sendText('hi');
      await waitFor(() =>
          contexts.length == 3 &&
          client.getInterruptState().interruptErrors.isNotEmpty);
      expect(contexts[0].resume, isNull);
      expect(contexts[1].parentRunId, contexts[0].runId);
      expect(contexts[1].resume!.single['payload'], {'answer': 42});
      expect(contexts[2].parentRunId, contexts[1].runId);
      expect(contexts[2].resume!.single['payload'], {'answer': 43});
      expect(client.getInterruptState().interruptErrors.first['code'],
          'transport');
      await client.dispose();
    });
  });

  group('ChatClient subagents', () {
    test('lets a stopped child stream again when the server restarts it',
        () async {
      var calls = 0;
      final client =
          ChatClient.legacy(connection: connections.ConnectionAdapter.connect(
        connect: (_, {data, signal, required runContext}) async* {
          calls++;
          yield {
            'type': 'RUN_STARTED',
            'runId': 'run-1',
            'threadId': 'thread-1'
          };
          yield {
            'type': 'SUBAGENT_STARTED',
            'subagentRunId': 'sub-1',
            'name': 'researcher'
          };
          yield {
            'type': 'TEXT_MESSAGE_START',
            'messageId': 'child-msg',
            'role': 'assistant',
            'subagentRunId': 'sub-1'
          };
          yield {
            'type': 'TEXT_MESSAGE_CONTENT',
            'messageId': 'child-msg',
            'delta': calls == 1 ? 'partial' : 'again',
            'subagentRunId': 'sub-1'
          };
          if (calls == 1) {
            await signal!.whenCancelled;
            return;
          }
          yield {'type': 'SUBAGENT_FINISHED', 'subagentRunId': 'sub-1'};
          yield {
            'type': 'RUN_FINISHED',
            'runId': 'run-1',
            'threadId': 'thread-1'
          };
        },
      ));
      addTearDown(client.dispose);
      final first = client.sendLegacyMessage('hi');
      await waitFor(() =>
          client.getSubagents().isNotEmpty &&
          client.getSubagents().first.messages.isNotEmpty &&
          (client.getSubagents().first.messages.first['parts'] as List).any(
              (part) =>
                  part['type'] == 'text' && part['content'] == 'partial'));
      expect(client.getSubagents().first.messages.first['parts'], [
        {'type': 'text', 'content': 'partial'}
      ]);
      client.getSubagents().first.stop();
      await first;
      expect(client.getSubagents().first.status, 'error');
      await client.sendLegacyMessage('go on');
      final handle = client.getSubagents().firstWhere((h) => h.id == 'sub-1');
      expect(handle.status, 'finished');
      expect(handle.messages.first['parts'], [
        {'type': 'text', 'content': 'again'}
      ]);
    });

    test('accepts a frozen nested subagent card back without throwing', () {
      final client = ChatClient.legacy(
        transport: FakeChatTransport(),
        messages: <AssistantTurn>[
          AssistantTurn(
            id: 'a',
            role: 'assistant',
            parts: <AssistantPart>[
              AssistantPart(
                type: 'subagent',
                id: 'outer',
                subagent: <String, dynamic>{
                  'id': 'outer',
                  'messages': <dynamic>[
                    <String, dynamic>{
                      'id': 'inner',
                      'role': 'assistant',
                      'parts': <Map<String, dynamic>>[
                        <String, dynamic>{
                          'type': 'subagent',
                          'subagent': <String, dynamic>{
                            'id': 'inner',
                            'messages': <dynamic>[],
                          },
                        },
                      ],
                    },
                  ],
                },
              ),
            ],
          ),
        ],
      );
      final saved = client.getSnapshot().messages;
      client.clear();
      expect(() => client.setMessagesManually(<AssistantTurn>[...saved]),
          returnsNormally);
    });

    test('gives a nested card a handle with stop', () {
      final client = ChatClient.legacy(
        transport: FakeChatTransport(),
        messages: <AssistantTurn>[
          AssistantTurn(
            id: 'a',
            role: 'assistant',
            parts: <AssistantPart>[
              AssistantPart(
                type: 'subagent',
                id: 'outer',
                subagent: <String, dynamic>{
                  'id': 'outer',
                  'messages': <dynamic>[
                    <String, dynamic>{
                      'id': 'inner',
                      'role': 'assistant',
                      'parts': <Map<String, dynamic>>[
                        <String, dynamic>{
                          'type': 'subagent',
                          'subagent': <String, dynamic>{
                            'id': 'inner',
                            'name': 'nested',
                            'status': 'running',
                            'messages': <dynamic>[],
                          },
                        },
                      ],
                    },
                  ],
                },
              ),
            ],
          ),
        ],
      );
      expect(client.getSubagents().any((h) => h.id == 'inner'), isTrue);
    });
  });

  group('ChatClient remaining', () {
    test('clears resume state when tool_calls finishes without an interrupt',
        () async {
      final transport = FakeChatTransport();
      final client = ChatClient.legacy(transport: transport);
      await client.append(userMessage('u', 'hi'));
      transport.emit(<String, dynamic>{
        'type': 'RUN_FINISHED',
        'runId': 'r',
        'finishReason': 'tool_calls',
        'outcome': <String, dynamic>{'type': 'success'},
      });
      await pump(8);
      expect(client.getResumeState(), isNull);
      await client.stop();
    });
  });
}
