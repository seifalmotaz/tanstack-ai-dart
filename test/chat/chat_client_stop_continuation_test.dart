// Upstream reference: packages/ai-client/tests/chat-client-stop-continuation.test.ts
import 'package:tanstack_ai_dart/chat.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('ChatClient stop continuation', () {
    test('a tool result arriving after stop does not start another run',
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
      await client.stop();
      final bodiesAfterStop = transport.bodies.length;

      await client.addToolResult(
        toolCallId: 'tc1',
        tool: 'lookup',
        output: <String, dynamic>{'late': true},
      );
      await pump(8);
      expect(transport.bodies.length, bodiesAfterStop);
    });

    test('a stopped continuation does not resume after clear()', () async {
      final part = AssistantPart.tool(
        id: 'tc1',
        name: 'write',
        state: 'approval-requested',
        approval: AssistantApproval(id: 'approval-1'),
      );
      final transport = FakeChatTransport();
      final client = ChatClient(
        transport: transport,
        messages: <AssistantTurn>[
          AssistantTurn(
              id: 'a', role: 'assistant', parts: <AssistantPart>[part]),
        ],
      );
      await client.approve(part, true);
      await client.clear();
      await client.addToolResult(
        toolCallId: 'tc1',
        tool: 'write',
        output: <String, dynamic>{'ok': true},
      );
      await pump(8);
      expect(transport.bodies, hasLength(1));
      expect(client.getMessages(), isEmpty);
    });
  });
}
