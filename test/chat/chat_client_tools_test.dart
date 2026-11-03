// Upstream reference: packages/ai-client/tests/chat-client-context.test.ts
import 'dart:async';

import 'package:tanstack_ai_dart/chat.dart';
import 'package:tanstack_ai_dart/connections.dart';
import 'package:test/test.dart';

import 'support.dart';

List<Map<String, dynamic>> toolChunks({
  String toolCallId = 'tc1',
  String name = 'lookup',
  String args = '{"id":1}',
}) =>
    <Map<String, dynamic>>[
      <String, dynamic>{'type': 'RUN_STARTED', 'runId': 'run-1'},
      <String, dynamic>{
        'type': 'TOOL_CALL_START',
        'toolCallId': toolCallId,
        'toolCallName': name,
      },
      <String, dynamic>{
        'type': 'TOOL_CALL_ARGS',
        'toolCallId': toolCallId,
        'delta': args,
      },
      <String, dynamic>{
        'type': 'TOOL_CALL_END',
        'toolCallId': toolCallId,
        'toolCallName': name,
      },
      <String, dynamic>{
        'type': 'RUN_FINISHED',
        'runId': 'run-1',
        'outcome': <String, dynamic>{'type': 'success'},
      },
    ];

void main() {
  group('ChatClient runtime context', () {
    test('executes only explicitly pending tool calls on a successful run',
        () async {
      final executed = <String>[];
      final connection = ConnectionAdapter.connect(
        connect: (_, {data, signal, required runContext}) async* {
          yield {
            'type': 'RUN_STARTED',
            'threadId': runContext.threadId,
            'runId': runContext.runId
          };
          for (final id in ['one', 'two']) {
            yield {
              'type': 'TOOL_CALL_START',
              'toolCallId': id,
              'toolCallName': id
            };
            yield {'type': 'TOOL_CALL_ARGS', 'toolCallId': id, 'delta': '{}'};
          }
          yield {
            'type': 'RUN_FINISHED',
            'threadId': runContext.threadId,
            'runId': runContext.runId,
            'outcome': {
              'type': 'success',
              'pendingToolCallIds': ['two']
            }
          };
        },
      );
      final client =
          ChatClient(connection: connection, threadId: 'thread-1', tools: [
        for (final name in ['one', 'two'])
          ClientTool<dynamic, dynamic>(
              name: name,
              execute: (_, __) {
                executed.add(name);
                return 1;
              }),
      ]);
      await client.sendText('hi');
      await pump();
      expect(executed, ['two']);
      await client.dispose();
    });
    test(
        'unbound tool interrupt does not execute or resume, but accepts local output',
        () async {
      var sends = 0;
      var executions = 0;
      final connection = ConnectionAdapter.connect(
        connect: (_, {data, signal, required runContext}) async* {
          sends++;
          yield {
            'type': 'RUN_STARTED',
            'threadId': runContext.threadId,
            'runId': runContext.runId
          };
          yield {
            'type': 'TOOL_CALL_START',
            'toolCallId': 'tc1',
            'toolCallName': 'lookup'
          };
          yield {'type': 'TOOL_CALL_ARGS', 'toolCallId': 'tc1', 'delta': '{}'};
          yield {'type': 'TOOL_CALL_END', 'toolCallId': 'tc1'};
          yield {
            'type': 'RUN_FINISHED',
            'threadId': runContext.threadId,
            'runId': runContext.runId,
            'outcome': {
              'type': 'interrupt',
              'interrupts': [
                {
                  'id': 'unbound',
                  'toolCallId': 'tc1',
                  'reason': 'client_tool_input',
                  'metadata': {
                    'kind': 'client_tool',
                    'toolName': 'lookup',
                    'input': <String, dynamic>{}
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
            execute: (_, __) {
              executions++;
              return 1;
            }),
      ]);
      await client.sendText('hi');
      expect(executions, 0);
      expect(client.getInterrupts().single.kind, 'unbound');
      await client.addToolResult(toolCallId: 'tc1', output: 42);
      await pump();
      expect(sends, 1);
      final part = client
          .getMessages()
          .expand((m) => m.parts)
          .firstWhere((p) => p.id == 'tc1');
      expect(part.output, 42);
      await client.dispose();
    });
    test('passes thread and tool call identity to typed tool execution',
        () async {
      final transport = FakeChatTransport();
      ToolCallContext? seen;
      final client = ChatClient.legacy(
        transport: transport,
        threadId: 'thread-1',
        context: {'tenantId': 't1'},
        tools: <ClientTool>[
          ClientTool<dynamic, dynamic>(
            name: 'lookup',
            execute: (input, context) {
              seen = context;
              return {'found': true};
            },
          ),
        ],
      );
      await client.sendText('hi');
      await emitAll(transport, toolChunks());
      await transport.close();
      await waitFor(() => seen != null);
      expect(seen!.threadId, 'thread-1');
      expect(seen!.toolCallId, 'tc1');
      expect(seen!.context, {'tenantId': 't1'});
      expect(transport.bodies.first.toString(), isNot(contains('tenantId')));
      await client.stop();
    });
    test(
        'passes client-local context to client tool execution without serializing it',
        () async {
      final transport = FakeChatTransport();
      Object? seen;
      final client = ChatClient.legacy(
        transport: transport,
        context: <String, dynamic>{'tenantId': 't1'},
        tools: <ChatClientTool>[
          ChatClientTool(
            name: 'lookup',
            execute: (input, context) {
              seen = context;
              return <String, dynamic>{'found': true};
            },
          ),
        ],
      );
      await client.sendText('hi');
      await emitAll(transport, toolChunks());
      await transport.close();
      await waitFor(() => transport.bodies.length == 2);
      expect(seen, <String, dynamic>{'tenantId': 't1'});
      expect(
          '${transport.bodies.first['context']}', isNot(contains('tenantId')));
      await client.stop();
    });

    test('clears client-local context when updateOptions receives null',
        () async {
      final outputs = <Object?>[];
      var calls = 0;
      final connection = ConnectionAdapter.connect(
          connect: (_, {data, signal, required runContext}) async* {
        final index = calls++;
        yield {
          'type': 'RUN_STARTED',
          'threadId': runContext.threadId,
          'runId': runContext.runId
        };
        if (index.isEven) {
          yield {
            'type': 'TOOL_CALL_START',
            'toolCallId': 'call-$index',
            'toolCallName': 'lookup'
          };
          yield {
            'type': 'TOOL_CALL_ARGS',
            'toolCallId': 'call-$index',
            'delta': '{}'
          };
        } else {
          yield {
            'type': 'TEXT_MESSAGE_CONTENT',
            'messageId': 'm-$index',
            'delta': 'done'
          };
        }
        yield {
          'type': 'RUN_FINISHED',
          'threadId': runContext.threadId,
          'runId': runContext.runId,
          'outcome': {'type': 'success'}
        };
      });
      final client =
          ChatClient(connection: connection, threadId: 'thread-1', context: {
        'tenantId': 't1'
      }, tools: [
        ClientTool<dynamic, dynamic>(
            name: 'lookup',
            execute: (_, context) {
              outputs.add(context.context);
              return {'ok': true};
            })
      ]);
      await client.sendText('first');
      await waitFor(() => calls >= 2);
      client.context = null;
      await client.sendText('second');
      await waitFor(() => calls >= 4);
      expect(outputs, [
        {'tenantId': 't1'},
        null
      ]);
      await client.dispose();
    });

    test(
        'surfaces executable client tool outputSchema failures as output-error results',
        () async {
      final transport = FakeChatTransport();
      final client = ChatClient.legacy(
        transport: transport,
        tools: <ChatClientTool>[
          ChatClientTool(
            name: 'lookup',
            execute: (input, context) => <String, dynamic>{'bad': true},
            validateOutput: (output) {
              throw StateError('expected found');
            },
          ),
        ],
      );
      await client.sendText('hi');
      await emitAll(transport, toolChunks());
      await pump(8);
      final tool = client
          .getMessages()
          .expand((message) => message.parts)
          .firstWhere((part) => part.type == 'tool-call');
      expect(tool.state, 'error');
      expect('${tool.output}', contains('expected found'));
      await client.stop();
    });

    test('keeps non-JSON output of client tools that are not interrupts',
        () async {
      final transport = FakeChatTransport();
      final client = ChatClient.legacy(
        transport: transport,
        tools: <ChatClientTool>[
          ChatClientTool(
            name: 'lookup',
            execute: (input, context) => 42,
          ),
        ],
      );
      await client.sendText('hi');
      await emitAll(transport, toolChunks());
      await pump(8);
      final tool = client
          .getMessages()
          .expand((message) => message.parts)
          .firstWhere((part) => part.type == 'tool-call');
      expect(tool.output, 42);
      expect(tool.hasOutput, isTrue);
      await client.stop();
    });

    test(
        'renders a client tool that throws an empty-message error as terminal error',
        () async {
      final transport = FakeChatTransport();
      final client = ChatClient.legacy(
        transport: transport,
        tools: <ChatClientTool>[
          ChatClientTool(
            name: 'lookup',
            execute: (input, context) => throw StateError('boom'),
          ),
        ],
      );
      await client.sendText('hi');
      await emitAll(transport, toolChunks());
      await pump(8);
      final tool = client
          .getMessages()
          .expand((message) => message.parts)
          .firstWhere((part) => part.type == 'tool-call');
      expect(tool.state, 'error');
      expect('${tool.output}', contains('boom'));
      await client.stop();
    });

    test(
        'manual addToolResult updates the part and continues with a new assistant',
        () async {
      final transport = FakeChatTransport();
      final client = ChatClient.legacy(transport: transport);
      await client.sendText('hi');
      await emitAll(transport, <Map<String, dynamic>>[
        <String, dynamic>{'type': 'RUN_STARTED', 'runId': 'run-1'},
        <String, dynamic>{
          'type': 'TOOL_CALL_START',
          'toolCallId': 'tc1',
          'toolCallName': 'lookup',
        },
        <String, dynamic>{
          'type': 'TOOL_CALL_ARGS',
          'toolCallId': 'tc1',
          'delta': '{"id":1}',
        },
        <String, dynamic>{
          'type': 'TOOL_CALL_END',
          'toolCallId': 'tc1',
          'toolCallName': 'lookup',
        },
        <String, dynamic>{
          'type': 'RUN_FINISHED',
          'runId': 'run-1',
          'outcome': <String, dynamic>{'type': 'success'},
        },
      ]);
      await transport.close();
      await pump();
      await client.addToolResult(
        toolCallId: 'tc1',
        tool: 'lookup',
        output: <String, dynamic>{'found': true},
      );
      await waitFor(() => transport.bodies.length == 2);
      final tool = client
          .getMessages()
          .expand((message) => message.parts)
          .firstWhere((part) => part.type == 'tool-call');
      expect(tool.state, 'complete');
      expect(tool.output, <String, dynamic>{'found': true});
      expect(client.getMessages().last.role, 'assistant');
      await client.stop();
    });

    test('tool result output presence distinguishes null from absent',
        () async {
      final transport = FakeChatTransport();
      final client = ChatClient.legacy(transport: transport);
      await client.sendText('hi');
      await emitAll(transport, <Map<String, dynamic>>[
        <String, dynamic>{'type': 'RUN_STARTED', 'runId': 'run-1'},
        <String, dynamic>{
          'type': 'TOOL_CALL_START',
          'toolCallId': 'tc1',
          'toolCallName': 'lookup',
        },
        <String, dynamic>{
          'type': 'TOOL_CALL_END',
          'toolCallId': 'tc1',
          'toolCallName': 'lookup',
          'input': <String, dynamic>{},
        },
        <String, dynamic>{
          'type': 'RUN_FINISHED',
          'runId': 'run-1',
          'outcome': <String, dynamic>{'type': 'success'},
        },
      ]);
      await transport.close();
      await pump();
      await client.addToolResult(toolCallId: 'tc1', output: null);
      await waitFor(() => transport.bodies.length == 2);
      final part = (transport.bodies[1]['messages'] as List)
          .expand((row) => ((row as Map)['parts'] as List))
          .cast<Map>()
          .firstWhere((part) => part['type'] == 'tool-call');
      expect(part.containsKey('output'), isTrue);
      expect(part['output'], isNull);
      await client.stop();
    });

    test(
        'awaits asynchronous outputSchema validation for executable client tools',
        () async {
      final transport = FakeChatTransport();
      final gate = Completer<void>();
      final client = ChatClient.legacy(
        transport: transport,
        tools: <ChatClientTool>[
          ChatClientTool(
            name: 'lookup',
            execute: (input, context) => <String, dynamic>{'ok': true},
            validateOutput: (output) async {
              await gate.future;
              if ((output as Map)['ok'] != true) throw StateError('bad');
            },
          ),
        ],
      );
      await client.sendText('hi');
      await emitAll(transport, toolChunks());
      await pump(8);
      var tool = client
          .getMessages()
          .expand((m) => m.parts)
          .firstWhere((p) => p.type == 'tool-call');
      expect(tool.state, isNot('complete'));
      gate.complete();
      await pump(8);
      tool = client
          .getMessages()
          .expand((m) => m.parts)
          .firstWhere((p) => p.type == 'tool-call');
      expect(tool.state, 'complete');
      await client.stop();
    });

    test(
        'awaits asynchronous outputSchema validation for manual client tool results',
        () async {
      final transport = FakeChatTransport();
      final client = ChatClient.legacy(
        transport: transport,
        tools: <ChatClientTool>[
          ChatClientTool(
            name: 'lookup',
            validateOutput: (output) async {
              await Future<void>.delayed(Duration.zero);
              if ((output as Map)['ok'] != true) throw StateError('bad');
            },
          ),
        ],
        messages: <AssistantTurn>[
          AssistantTurn(
            id: 'a',
            role: 'assistant',
            parts: <AssistantPart>[
              AssistantPart.tool(id: 'tc1', name: 'lookup', arguments: '{}'),
            ],
          ),
        ],
      );
      await client.addToolResult(
        toolCallId: 'tc1',
        tool: 'lookup',
        output: <String, dynamic>{'ok': false},
      );
      await pump(8);
      final tool = client
          .getMessages()
          .expand((m) => m.parts)
          .firstWhere((p) => p.type == 'tool-call');
      expect(tool.state, 'error');
      await client.stop();
    });

    test(
        'client tools from a foreign AG-UI server runs the tool and continues with its result',
        () async {
      final transport = FakeChatTransport();
      final client = ChatClient.legacy(
        transport: transport,
        tools: <ChatClientTool>[
          ChatClientTool(
            name: 'foreign',
            execute: (input, context) => <String, dynamic>{'ran': true},
          ),
        ],
      );
      await client.sendText('hi');
      await emitAll(transport, <Map<String, dynamic>>[
        <String, dynamic>{'type': 'RUN_STARTED', 'runId': 'r'},
        <String, dynamic>{
          'type': 'TOOL_CALL_START',
          'toolCallId': 'tc',
          'toolCallName': 'foreign',
        },
        <String, dynamic>{
          'type': 'TOOL_CALL_END',
          'toolCallId': 'tc',
          'toolCallName': 'foreign',
          'input': <String, dynamic>{},
        },
        <String, dynamic>{
          'type': 'RUN_FINISHED',
          'runId': 'r',
          'outcome': <String, dynamic>{'type': 'success'},
        },
      ]);
      await transport.close();
      await waitFor(() => transport.bodies.length == 2);
      expect(
        transport.bodies[1].toString(),
        contains('ran'),
      );
      await client.stop();
    });

    test(
        'client tools from a foreign AG-UI server does not run a tool that needs approval',
        () async {
      final transport = FakeChatTransport();
      var ran = false;
      final client = ChatClient.legacy(
        transport: transport,
        tools: <ChatClientTool>[
          ChatClientTool(
            name: 'foreign',
            needsApproval: true,
            execute: (input, context) {
              ran = true;
              return <String, dynamic>{'ran': true};
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
          'toolCallName': 'foreign',
        },
        <String, dynamic>{
          'type': 'TOOL_CALL_END',
          'toolCallId': 'tc',
          'toolCallName': 'foreign',
          'input': <String, dynamic>{},
        },
      ]);
      await pump(8);
      expect(ran, isFalse);
      await client.stop();
    });
  });
}
