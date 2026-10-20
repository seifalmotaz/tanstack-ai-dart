// Upstream reference: packages/ai-client/tests/chat-client-context.test.ts
import 'dart:async';

import 'package:tanstack_ai_dart/chat.dart';
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
    test(
        'passes client-local context to client tool execution without serializing it',
        () async {
      final transport = FakeChatTransport();
      Object? seen;
      final client = ChatClient(
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
      final transport = FakeChatTransport();
      Object? seen = 'unset';
      final client = ChatClient(
        transport: transport,
        context: <String, dynamic>{'tenantId': 't1'},
        tools: <ChatClientTool>[
          ChatClientTool(
            name: 'lookup',
            execute: (input, context) {
              seen = context;
              return null;
            },
          ),
        ],
      );
      client.updateOptions(context: null);
      await client.sendText('hi');
      await emitAll(transport, toolChunks());
      await pump(8);
      expect(seen, isNull);
      await client.stop();
    });

    test(
        'surfaces executable client tool outputSchema failures as output-error results',
        () async {
      final transport = FakeChatTransport();
      final client = ChatClient(
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
      final client = ChatClient(
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
      final client = ChatClient(
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
      final client = ChatClient(transport: transport);
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
      final client = ChatClient(transport: transport);
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
      final client = ChatClient(
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
      final client = ChatClient(
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
      final client = ChatClient(
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
      final client = ChatClient(
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
