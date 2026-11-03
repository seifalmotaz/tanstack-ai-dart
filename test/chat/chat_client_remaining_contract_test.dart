// Upstream references: chat-client-context.test.ts, chat-client-interrupts.test.ts,
// chat-client-resume.test.ts, chat-client-subagents.test.ts and chat-client.test.ts.
import 'dart:async';

import 'package:tanstack_ai_dart/chat.dart';
import 'package:test/test.dart';
import 'package:tanstack_ai_dart/connections.dart' as connections;

import 'support.dart';

ChatClient interrupted(
  FakeChatTransport transport, {
  List<Map<String, dynamic>>? interrupts,
}) {
  final client = ChatClient(
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
      final client = ChatClient(
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
      client.updateOptions(context: <String, dynamic>{'run': 2});
      await pump(8);
      expect(contexts.first, <String, dynamic>{'run': 1});
      await client.stop();
    });

    test(
        'uses the per-run client tool snapshot for automatic result validation',
        () async {
      final transport = FakeChatTransport();
      final client = ChatClient(
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
      client.updateOptions(body: <String, dynamic>{'changed': true});
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
      await client.resumeInterrupts(<Map<String, dynamic>>[
        <String, dynamic>{'interruptId': 'i1', 'status': 'resolved'},
      ]);
      final ids = (transport.bodies[1]['messages'] as List)
          .map((row) => (row as Map)['id'])
          .toList();
      expect(ids, contains(client.getMessages().first.id));
      await client.stop();
    });
  });

  group('ChatClient resume', () {
    test('resumes canonicalization failures as client-tool output errors',
        () async {
      final manager = InterruptManager();
      manager.hydrate(
        const ChatHydrationInterrupts(
          runId: 'r',
          pending: <Map<String, dynamic>>[
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
        ),
      );
      manager.resolveClientToolOutput('tc', Object());
      expect(manager.getInterrupts().single.status, ChatInterruptStatus.error);
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
      await client.resumeInterrupts(<Map<String, dynamic>>[
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
      final manager = InterruptManager();
      manager.hydrate(
        const ChatHydrationInterrupts(
          runId: 'r',
          pending: <Map<String, dynamic>>[
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
        ),
      );
      manager.resolveClientToolError('tc', 'boom');
      expect(manager.getInterrupts().single.resolution, isNotNull);
    });
  });

  group('ChatClient subagents', () {
    test('lets a stopped child stream again when the server restarts it',
        () async {
      var calls = 0;
      final client = ChatClient(connection: connections.ConnectionAdapter(
        connect: (_, {data, signal, runContext}) async* {
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
      final first = client.sendMessage('hi');
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
      await client.sendMessage('go on');
      final handle = client.getSubagents().firstWhere((h) => h.id == 'sub-1');
      expect(handle.status, 'finished');
      expect(handle.messages.first['parts'], [
        {'type': 'text', 'content': 'again'}
      ]);
    });

    test('accepts a frozen nested subagent card back without throwing', () {
      final client = ChatClient(
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
      final client = ChatClient(
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
      final client = ChatClient(transport: transport);
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
