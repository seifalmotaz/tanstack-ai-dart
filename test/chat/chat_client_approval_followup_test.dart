// Upstream reference: packages/ai-client/tests/chat-client-approval-followup.test.ts
import 'package:tanstack_ai_dart/chat.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('chained tool approvals', () {
    test(
        'continues after second approval arrives during active continuation stream',
        () async {
      final first = AssistantPart.tool(
        id: 'tc1',
        name: 'first',
        arguments: '{}',
        state: 'approval-requested',
        approval: AssistantApproval(id: 'approval-1'),
      );
      final second = AssistantPart.tool(
        id: 'tc2',
        name: 'second',
        arguments: '{}',
        state: 'approval-requested',
        approval: AssistantApproval(id: 'approval-2'),
      );
      final transport = FakeChatTransport();
      final client = ChatClient(
        transport: transport,
        messages: <AssistantTurn>[
          AssistantTurn(
            id: 'a1',
            role: 'assistant',
            parts: <AssistantPart>[first, second],
          ),
        ],
      );

      await client.approve(first, true);
      expect(transport.bodies, hasLength(1));
      await client.approve(second, true);
      expect(client.isStreaming, isTrue);

      await emitAll(transport, textChunks('continued'));
      await transport.close();
      await waitFor(() => transport.bodies.length == 2);
      final sentParts = (transport.bodies[1]['messages'] as List)
          .where((row) => (row as Map)['role'] == 'assistant')
          .expand((row) => ((row as Map)['parts'] as List))
          .cast<Map>()
          .where((part) => part['type'] == 'tool-call')
          .toList();
      expect(sentParts, hasLength(2));
      expect(
        sentParts.every((part) => part['state'] == 'approval-responded'),
        isTrue,
      );
      await client.stop();
    });
  });
}
