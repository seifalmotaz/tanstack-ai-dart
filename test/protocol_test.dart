import 'dart:convert';

import 'package:tanstack_ai_dart/tanstack_ai_dart.dart';
import 'package:test/test.dart';

void main() {
  test(
      'tool-only assistant messages carry required content and preserve JSON results',
      () {
    final tool = AssistantPart.tool(
        id: 'read-1',
        name: 'search_leads',
        state: 'complete',
        output: '{"count":1}');
    final turn =
        AssistantTurn(id: 'assistant-1', role: 'assistant', parts: [tool]);
    final wire = assistantModelMessages([turn]);
    expect(wire.first['content'], '');
    expect(wire.last['content'], '{"count":1}');
  });
  test(
      'wire UI parts preserve approvals and omit absent output and private reasoning',
      () {
    final part = AssistantPart.tool(
        id: 'tc',
        name: 'write',
        state: 'approval-responded',
        approval: AssistantApproval(id: 'approval_tc', approved: true));
    final turn = AssistantTurn(id: 'assistant', role: 'assistant', parts: [
      AssistantPart.thinking(id: 'private', content: 'Private reasoning'),
      part,
    ]);
    final body = assistantChatBody('thread', [turn, AssistantTurn.assistant()]);
    final messages = body['messages'] as List;
    expect(messages, hasLength(1));
    final parts = messages.single['parts'] as List;
    expect(parts, hasLength(1));
    expect(parts.single['approval'],
        {'id': 'approval_tc', 'needsApproval': true, 'approved': true});
    expect((parts.single as Map).containsKey('output'), isFalse);
    expect(parts.single['arguments'], '{}');
  });
  group('AssistantStreamReducer', () {
    test('chunks append to text and thinking never enters the answer', () {
      final parts = <AssistantPart>[];
      final reducer = AssistantStreamReducer(parts);

      reducer.apply({'type': 'THINKING_TEXT_MESSAGE_START'});
      reducer.apply({
        'type': 'THINKING_TEXT_MESSAGE_CONTENT',
        'delta': 'The user wants ',
      });
      reducer.apply({
        'type': 'THINKING_TEXT_MESSAGE_CHUNK',
        'delta': 'lead stats.',
      });
      reducer.apply({'type': 'THINKING_TEXT_MESSAGE_END'});

      reducer.apply({'type': 'TEXT_MESSAGE_START'});
      reducer.apply({'type': 'TEXT_MESSAGE_CONTENT', 'delta': 'You have '});
      reducer.apply({
        'type': 'TEXT_MESSAGE_CONTENT',
        'delta': '3 unassigned ',
      });
      reducer.apply({'type': 'TEXT_MESSAGE_CHUNK', 'delta': 'leads.'});
      reducer.apply({'type': 'TEXT_MESSAGE_END'});

      final turn = AssistantTurn(id: 'a1', role: 'assistant', parts: parts);

      expect(turn.answer, 'You have 3 unassigned leads.');
      expect(turn.answer, isNot(contains('The user wants')));
      expect(turn.thoughts.single.content, 'The user wants lead stats.');
    });

    test('split tool args and CUSTOM approval use the exact schema', () {
      final parts = <AssistantPart>[];
      final reducer = AssistantStreamReducer(parts);

      reducer.apply({'type': 'TEXT_MESSAGE_START'});
      reducer.apply({'type': 'TEXT_MESSAGE_CONTENT', 'delta': 'One moment'});
      reducer.apply({
        'type': 'TOOL_CALL_START',
        'toolCallId': 'tc1',
        'toolCallName': 'assign_lead',
      });
      reducer.apply({
        'type': 'TOOL_CALL_ARGS',
        'toolCallId': 'tc1',
        'delta': '{"leadId":"l-',
      });
      reducer.apply({
        'type': 'TOOL_CALL_ARGS',
        'toolCallId': 'tc1',
        'delta': '1"}',
      });
      reducer.apply({
        'type': 'TOOL_CALL_END',
        'toolCallId': 'tc1',
        'toolCallName': 'assign_lead',
      });
      reducer.apply({
        'type': 'CUSTOM',
        'name': 'approval-requested',
        'value': {
          'toolCallId': 'tc1',
          'toolName': 'assign_lead',
          'input': {'leadId': 'l-1'},
          'approval': {'id': 'approval_tc1', 'needsApproval': true},
        },
      });

      final tool = parts.singleWhere((p) => p.type == 'tool-call');
      expect(tool.arguments, '{"leadId":"l-1"}');
      expect(tool.input, {'leadId': 'l-1'});
      expect(tool.state, 'approval-requested');
      expect(tool.approval?.id, 'approval_tc1');
      expect(tool.approval?.needsApproval, isTrue);
      expect(tool.approval?.approved, isNull);

      reducer.apply({
        'type': 'RUN_FINISHED',
        'outcome': {'type': 'interrupt'},
      });
      expect(reducer.done, isTrue);
    });

    test('RUN_FINISHED interrupt also surfaces an approval request', () {
      final parts = <AssistantPart>[];
      final reducer = AssistantStreamReducer(parts);

      reducer.apply({
        'type': 'RUN_FINISHED',
        'outcome': {
          'type': 'interrupt',
          'interrupts': [
            {
              'id': 'approval_tc9',
              'reason': 'approval_required',
              'toolCallId': 'tc9',
              'metadata': {
                'kind': 'approval',
                'toolName': 'bulk_assign_leads',
                'input': {
                  'leadIds': ['lead-1', 'lead-2'],
                  'assignedSalesAgentId': 'agent-1',
                },
              },
            },
          ],
        },
      });

      final tool = parts.singleWhere((p) => p.type == 'tool-call');
      expect(tool.name, 'bulk_assign_leads');
      expect(tool.state, 'approval-requested');
      expect(tool.approval?.id, 'approval_tc9');
      expect(tool.input, {
        'leadIds': ['lead-1', 'lead-2'],
        'assignedSalesAgentId': 'agent-1',
      });
    });

    test('RUN_ERROR records the message', () {
      final reducer = AssistantStreamReducer(<AssistantPart>[]);
      reducer.apply({'type': 'RUN_ERROR', 'message': ' Provider failed '});
      expect(reducer.done, isTrue);
      expect(reducer.error, 'Provider failed');
    });
  });

  group('TanStack wire helpers', () {
    test('approve payload matches the pendingExecution schema', () {
      expect(assistantApprovalPayload(true), {
        'approved': true,
        'pendingExecution': true,
        'message': 'User approved this action',
      });
      expect(assistantApprovalPayload(false), {
        'approved': false,
        'message': 'User denied this action',
      });
    });

    test('approval response becomes assistant toolCalls plus tool message', () {
      final user = AssistantTurn(
        id: 'u1',
        role: 'user',
        parts: [AssistantPart.text('Assign lead l1')],
      );
      final assistant = AssistantTurn(
        id: 'a1',
        role: 'assistant',
        parts: [
          AssistantPart.text('Ready'),
          AssistantPart.tool(
            id: 'tc1',
            name: 'assign_lead',
            arguments: '{"leadId":"l1"}',
            input: {'leadId': 'l1'},
            state: 'approval-responded',
            approval: AssistantApproval(id: 'approval_tc1', approved: true),
          ),
        ],
      );

      final wire = assistantModelMessages([user, assistant]);

      expect(wire.length, 3);
      expect(wire[0], {
        'id': 'u1',
        'role': 'user',
        'content': 'Assign lead l1',
      });
      expect(wire[1]['role'], 'assistant');
      expect(wire[1]['content'], 'Ready');
      final call = (wire[1]['toolCalls'] as List).single as Map;
      expect(call['id'], 'tc1');
      expect(call['type'], 'function');
      expect((call['function'] as Map)['name'], 'assign_lead');
      expect((call['function'] as Map)['arguments'], '{"leadId":"l1"}');

      expect(wire[2]['role'], 'tool');
      expect(wire[2]['toolCallId'], 'tc1');
      expect(jsonDecode(wire[2]['content'] as String), {
        'approved': true,
        'pendingExecution': true,
        'message': 'User approved this action',
      });
    });

    test('reject payload omits pendingExecution', () {
      final assistant = AssistantTurn(
        id: 'a1',
        role: 'assistant',
        parts: [
          AssistantPart.tool(
            id: 'tc1',
            name: 'bulk_assign_leads',
            arguments: '{}',
            state: 'approval-responded',
            approval: AssistantApproval(id: 'approval_tc1', approved: false),
          ),
        ],
      );

      final wire = assistantModelMessages([assistant]);
      expect(wire.length, 2);
      expect(jsonDecode(wire[1]['content'] as String), {
        'approved': false,
        'message': 'User denied this action',
      });
    });

    test('chat body carries durable ids and Arabic text survives', () {
      final user = AssistantTurn(
        id: 'u1',
        role: 'user',
        parts: [AssistantPart.text('مرحبا، كم عدد العملاء غير المعينين؟')],
      );

      final body = assistantChatBody('thread-1', [user]);
      expect(body['durableThreadId'], 'thread-1');
      expect(body['threadId'], 'thread-1');
      expect(body['forwardedProps'], {
        'durableThreadId': 'thread-1',
        'threadId': 'thread-1',
      });
      expect(body['messages'], [
        {
          'id': 'u1',
          'role': 'user',
          'parts': [
            {'type': 'text', 'content': 'مرحبا، كم عدد العملاء غير المعينين؟'}
          ],
        },
      ]);
    });

    test('chat body omits thread ids when none is supplied', () {
      final body = assistantChatBody(null, <AssistantTurn>[]);
      expect(body.containsKey('durableThreadId'), isFalse);
      expect(body.containsKey('threadId'), isFalse);
      expect(body['messages'], isEmpty);
    });

    test('empty assistant placeholders are not sent', () {
      final user = AssistantTurn(
        id: 'u1',
        role: 'user',
        parts: [AssistantPart.text('Hello')],
      );
      final placeholder = AssistantTurn.assistant(id: 'a-empty');

      final wire = assistantModelMessages([user, placeholder]);
      expect(wire.length, 1);
      expect(wire.single['role'], 'user');
    });
  });

  group('history parsing', () {
    test('restores text, thinking and tools without merging thought', () {
      final turns = assistantTurnsFromThread({
        'messages': [
          {
            'id': 'u1',
            'role': 'user',
            'parts': [
              {'type': 'text', 'content': 'How many leads?'},
            ],
          },
          {
            'id': 'a1',
            'role': 'assistant',
            'parts': [
              {'type': 'thinking', 'id': 't1', 'content': 'Check pipeline'},
              {'type': 'text', 'content': 'There are 4 unassigned leads.'},
              {
                'type': 'tool-call',
                'id': 'tc1',
                'name': 'search_leads',
                'state': 'complete',
                'input': {'assignedStatus': 'unassigned'},
                'output': {'count': 4},
              },
            ],
          },
        ],
      });

      expect(turns.length, 2);
      expect(turns[0].answer, 'How many leads?');
      expect(turns[1].answer, 'There are 4 unassigned leads.');
      expect(turns[1].thoughts.single.content, 'Check pipeline');
      expect(turns[1].tools.single.name, 'search_leads');
      expect(turns[1].tools.single.state, 'complete');
    });

    test('consecutive assistant rows merge tool updates by id', () {
      final turns = assistantTurnsFromThread({
        'messages': [
          {
            'id': 'a1',
            'role': 'assistant',
            'parts': [
              {
                'type': 'tool-call',
                'id': 'tc1',
                'name': 'search_leads',
                'state': 'input-streaming',
              },
            ],
          },
          {
            'id': 'a2',
            'role': 'assistant',
            'parts': [
              {
                'type': 'tool-call',
                'id': 'tc1',
                'name': 'search_leads',
                'state': 'complete',
                'output': {'count': 3},
              },
            ],
          },
        ],
      });

      expect(turns.length, 1);
      expect(turns.single.tools.single.state, 'complete');
      expect(turns.single.tools.single.output, {'count': 3});
    });
  });

  group('title generation', () {
    test('strips openers, prefers the first clause, and capitalizes', () {
      expect(
        generateAssistantThreadTitle('please show me unassigned leads. thanks'),
        'Show me unassigned leads',
      );
      expect(generateAssistantThreadTitle('   '), 'New chat');
    });
  });
}
