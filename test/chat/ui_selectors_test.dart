// Upstream reference: packages/ai-client/tests/ui-selectors.test.ts
import 'package:tanstack_ai_dart/chat.dart';
import 'package:test/test.dart';

AssistantTurn message(String id, List<AssistantPart> parts) =>
    AssistantTurn(id: id, role: 'assistant', parts: parts);

AssistantPart call(String id, String name, {dynamic input}) =>
    AssistantPart.tool(
      id: id,
      name: name,
      arguments: '{}',
      input: input,
      state: 'input-complete',
    );

AssistantPart result(String callId, dynamic content) => AssistantPart(
      type: 'tool-result',
      toolCallId: callId,
      output: content,
      hasOutput: true,
      state: 'complete',
    );

ChatInterrupt approvalInterrupt({
  String id = 'approval-1',
  String toolCallId = 'call-a',
  String toolName = 'purchaseItem',
}) =>
    ChatInterrupt(
      id: id,
      kind: 'tool-approval',
      reason: 'approval_requested',
      toolName: toolName,
      toolCallId: toolCallId,
      threadId: 't',
      interruptedRunId: 'r',
      generation: 1,
    );

ChatInterrupt genericInterrupt({String id = 'generic-1'}) => ChatInterrupt(
      id: id,
      kind: 'generic',
      reason: 'choose_plan',
      threadId: 't',
      interruptedRunId: 'r',
      generation: 1,
    );

void main() {
  group('selectChatUI', () {
    test('matches results and partitions interrupts', () {
      final msg = message('m', <AssistantPart>[
        call('call-a', 'purchaseItem', input: <String, dynamic>{'sku': 'x'}),
        result('call-a', <String, dynamic>{'ok': true}),
        AssistantPart(
          type: 'structured-output',
          structuredStatus: 'complete',
          raw: '{"a":1}',
          data: <String, dynamic>{'a': 1},
        ),
      ]);
      final approval = approvalInterrupt();
      final generic = genericInterrupt();

      final selected = selectChatUI(
        ChatUISelectInput(
          messages: <AssistantTurn>[msg],
          interrupts: <ChatInterrupt>[approval, generic],
          inlineToolNames: <String>['purchaseItem'],
        ),
      );

      final parts = selected.messages.single.parts;
      expect(parts.map((part) => (part as dynamic).key), <String>[
        'toolCall',
        'toolResult',
        'structuredOutput',
      ]);
      final callPart = parts.first as ChatUISelectedToolPart;
      expect(callPart.result?.toolCallId, 'call-a');
      expect(identical(callPart.interrupt, approval), isTrue);
      expect(selected.interrupts, <ChatInterrupt>[generic]);
    });

    test('uses camel-case component keys', () {
      expect(partTypeToKey('tool-call'), 'toolCall');
      expect(partTypeToKey('tool-result'), 'toolResult');
      expect(partTypeToKey('structured-output'), 'structuredOutput');
      expect(partTypeToKey('ui-resource'), 'uiResource');
      expect(partTypeToKey('activity'), 'activity');
      expect(partTypeToKey('subagent'), 'subagent');
    });

    test('exposes activity parts on activity messages', () {
      final selected = selectChatUI(
        ChatUISelectInput(
          messages: <AssistantTurn>[
            AssistantTurn.activity(
              id: 'act-1',
              parts: <AssistantPart>[
                AssistantPart(
                  type: 'activity',
                  id: 'act-1',
                  activityType: 'SEARCH',
                  activityContent: <String, dynamic>{'query': 'tanstack'},
                ),
              ],
            ),
          ],
        ),
      );
      expect(selected.messages.single.message.role, 'activity');
      final part =
          selected.messages.single.parts.single as ChatUISelectedGenericPart;
      expect(part.key, 'activity');
      expect(part.part.activityType, 'SEARCH');
    });

    test('keeps unmatched tool-result parts', () {
      final selected = selectChatUI(
        ChatUISelectInput(
          messages: <AssistantTurn>[
            message('orphan', <AssistantPart>[result('missing-call', 'x')]),
          ],
        ),
      );
      final part =
          selected.messages.single.parts.single as ChatUISelectedResultPart;
      expect(part.matched, isFalse);
      expect(part.part.toolCallId, 'missing-call');
    });

    test('keeps orphan approvals in the interrupt list', () {
      final orphan = approvalInterrupt(toolCallId: 'missing');
      final selected = selectChatUI(
        ChatUISelectInput(
          messages: <AssistantTurn>[
            message('m', <AssistantPart>[call('call-a', 'purchaseItem')]),
          ],
          interrupts: <ChatInterrupt>[orphan],
          inlineToolNames: <String>['purchaseItem'],
        ),
      );
      expect(selected.interrupts, <ChatInterrupt>[orphan]);
    });

    test(
        'attaches list-placement approvals to the call and keeps them in the list',
        () {
      final approval = approvalInterrupt();
      final selected = selectChatUI(
        ChatUISelectInput(
          messages: <AssistantTurn>[
            message('m', <AssistantPart>[call('call-a', 'purchaseItem')]),
          ],
          interrupts: <ChatInterrupt>[approval],
        ),
      );
      final callPart =
          selected.messages.single.parts.first as ChatUISelectedToolPart;
      expect(identical(callPart.interrupt, approval), isTrue);
      expect(selected.interrupts, <ChatInterrupt>[approval]);
    });

    test('hides inline approvals from the interrupt list when a call matches',
        () {
      final approval = approvalInterrupt();
      final generic = genericInterrupt();
      final selected = selectChatUI(
        ChatUISelectInput(
          messages: <AssistantTurn>[
            message('m', <AssistantPart>[call('call-a', 'purchaseItem')]),
          ],
          interrupts: <ChatInterrupt>[approval, generic],
          inlineToolNames: <String>['purchaseItem'],
        ),
      );
      expect(selected.interrupts, <ChatInterrupt>[generic]);
    });

    test(
        'treats mapped tools as inline unless the interrupt map puts them in the list',
        () {
      expect(
        collectInlineToolNames(null, <String>['purchaseItem', 'getWeather']),
        <String>['purchaseItem', 'getWeather'],
      );
      expect(
        collectInlineToolNames(<String, dynamic>{}, <String>['purchaseItem']),
        <String>['purchaseItem'],
      );
      expect(
        collectInlineToolNames(
          <String, dynamic>{
            'purchaseItem': <String, dynamic>{},
          },
          <String>['purchaseItem'],
        ),
        isEmpty,
      );
    });

    test('preserves empty arrays', () {
      final selected = selectChatUI(
        const ChatUISelectInput(
          messages: <AssistantTurn>[],
          interrupts: <ChatInterrupt>[],
        ),
      );
      expect(selected.messages, isEmpty);
      expect(selected.interrupts, isEmpty);
    });

    test('preserves message and part order across every part key', () {
      final selected = selectChatUI(
        ChatUISelectInput(
          messages: <AssistantTurn>[
            message('ordered', <AssistantPart>[
              AssistantPart.thinking(id: 't', content: 'hmm'),
              AssistantPart.text('hi'),
              AssistantPart(
                type: 'image',
                source: <String, dynamic>{
                  'type': 'url',
                  'value': 'https://example.com/a.png',
                },
              ),
              AssistantPart(
                type: 'audio',
                source: <String, dynamic>{
                  'type': 'url',
                  'value': 'https://example.com/a.wav',
                },
              ),
              AssistantPart(
                type: 'video',
                source: <String, dynamic>{
                  'type': 'url',
                  'value': 'https://example.com/a.mp4',
                },
              ),
              AssistantPart(
                type: 'document',
                source: <String, dynamic>{
                  'type': 'url',
                  'value': 'https://example.com/a.pdf',
                },
              ),
              AssistantPart.tool(
                id: 'call-a',
                name: 'getWeather',
                arguments: '{}',
                state: 'awaiting-input',
              ),
              result('other', 'orphan'),
              AssistantPart(
                type: 'structured-output',
                structuredStatus: 'streaming',
                raw: '{',
              ),
              AssistantPart(
                type: 'ui-resource',
                toolCallId: 'call-a',
                name: 'getWeather',
                resource: <String, dynamic>{
                  'uri': 'ui://widget',
                  'mimeType': 'text/html',
                  'text': '<p></p>',
                },
              ),
            ]),
          ],
        ),
      );
      expect(
        selected.messages.single.parts.map((part) => (part as dynamic).key),
        <String>[
          'thinking',
          'text',
          'image',
          'audio',
          'video',
          'document',
          'toolCall',
          'toolResult',
          'structuredOutput',
          'uiResource',
        ],
      );
    });

    test('keeps unbound and registered generic interrupts in the list', () {
      final generic = genericInterrupt();
      final unbound = ChatInterrupt(
        id: 'u',
        kind: 'unbound',
        reason: 'foreign',
        threadId: 't',
        interruptedRunId: 'r',
        generation: 1,
        canResolve: false,
      );
      final selected = selectChatUI(
        ChatUISelectInput(
          messages: <AssistantTurn>[],
          interrupts: <ChatInterrupt>[generic, unbound],
        ),
      );
      expect(selected.interrupts, <ChatInterrupt>[generic, unbound]);
    });
  });

  group('resolveInterruptComponent', () {
    final plan = <String, dynamic>{'id': 'plan'};
    final fallback = <String, dynamic>{'id': 'fallback'};
    final purchase = <String, dynamic>{'id': 'purchase'};
    final map = <String, dynamic>{
      'tools': <String, dynamic>{'purchaseItem': purchase},
      'generic': <String, dynamic>{
        'choosePlan': plan,
        'fallback': fallback,
      },
    };

    test('resolves a registered generic interrupt from generic[id]', () {
      final interrupt = ChatInterrupt(
        id: 'g',
        kind: 'generic',
        reason: 'x',
        definitionId: 'choosePlan',
        threadId: 't',
        interruptedRunId: 'r',
        generation: 1,
      );
      expect(
          identical(resolveInterruptComponent(interrupt, map), plan), isTrue);
    });

    test('resolves unbound through generic.fallback', () {
      final interrupt = ChatInterrupt(
        id: 'u',
        kind: 'unbound',
        reason: 'x',
        threadId: 't',
        interruptedRunId: 'r',
        generation: 1,
        canResolve: false,
      );
      expect(
        identical(resolveInterruptComponent(interrupt, map), fallback),
        isTrue,
      );
    });

    test('resolves a tool approval from tools[name]', () {
      expect(
        identical(
          resolveInterruptComponent(approvalInterrupt(), map),
          purchase,
        ),
        isTrue,
      );
    });
  });
}
