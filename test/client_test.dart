import 'dart:async';
import 'dart:convert';

import 'package:tanstack_ai_dart/tanstack_ai_dart.dart';
import 'package:test/test.dart';

void main() {
  group('ChatClient', () {
    test('sendText appends turns and reduces a stream to an answer', () async {
      final transport = _FakeTransport();
      final client = ChatClient(transport: transport);

      await client.sendText('  How many leads?  ');
      expect(client.status, ChatClientStatus.streaming);
      expect(client.messages, hasLength(2));
      expect(client.messages.first.role, 'user');
      expect(client.messages.first.answer, 'How many leads?');
      expect(client.messages.last.role, 'assistant');
      expect(client.messages.last.streaming, isTrue);

      final body = transport.bodies.single;
      expect((body['messages'] as List).first, {
        'id': client.messages.first.id,
        'role': 'user',
        'parts': [
          {'type': 'text', 'content': 'How many leads?'}
        ],
      });

      transport.emit({
        'type': 'THINKING_TEXT_MESSAGE_START',
      });
      transport.emit({
        'type': 'THINKING_TEXT_MESSAGE_CONTENT',
        'delta': 'Count them',
      });
      transport.emit({'type': 'TEXT_MESSAGE_START'});
      transport.emit({'type': 'TEXT_MESSAGE_CONTENT', 'delta': 'There are '});
      transport.emit({'type': 'TEXT_MESSAGE_CONTENT', 'delta': '4.'});
      transport.emit({'type': 'TEXT_MESSAGE_END'});
      await transport.close();

      expect(client.status, ChatClientStatus.idle);
      expect(client.error, isNull);
      expect(client.messages.last.answer, 'There are 4.');
      expect(client.messages.last.thoughts.single.content, 'Count them');
      expect(client.messages.last.streaming, isFalse);
    });

    test('approval continuation sends the tool-result payload', () async {
      final part = AssistantPart.tool(
        id: 'tc1',
        name: 'assign_lead',
        arguments: '{"leadId":"l1"}',
        input: {'leadId': 'l1'},
        state: 'approval-requested',
        approval: AssistantApproval(id: 'approval_tc1'),
      );
      final turn = AssistantTurn(
        id: 'a1',
        role: 'assistant',
        parts: [part],
      );
      final transport = _FakeTransport();
      final client = ChatClient(transport: transport, messages: [turn]);

      await client.approve(part, true);

      expect(part.state, 'approval-responded');
      expect(part.approval?.approved, isTrue);
      final messages = assistantModelMessages(client.messages);
      expect(messages[0]['role'], 'assistant');
      expect((messages[0]['toolCalls'] as List).single['id'], 'tc1');
      expect(messages[1]['role'], 'tool');
      expect(jsonDecode(messages[1]['content'] as String), {
        'approved': true,
        'pendingExecution': true,
        'message': 'User approved this action',
      });

      transport.emit({'type': 'TEXT_MESSAGE_START'});
      transport.emit({'type': 'TEXT_MESSAGE_CONTENT', 'delta': 'Assigned.'});
      await transport.close();
      expect(client.messages.single.answer, 'Assigned.');
    });

    test('approval decisions cannot be replayed or applied to another client',
        () async {
      final part = AssistantPart.tool(
          id: 'tc1',
          name: 'write',
          approval: AssistantApproval(id: 'approval'));
      final transport = _FakeTransport();
      final client = ChatClient(transport: transport, messages: [
        AssistantTurn(id: 'a', role: 'assistant', parts: [part])
      ]);
      final stranger = AssistantPart.tool(
          id: 'tc2', name: 'write', approval: AssistantApproval(id: 'outside'));
      await client.approve(stranger, true);
      expect(stranger.approval!.approved, isNull);
      expect(transport.bodies, isEmpty);
      await client.approve(part, false);
      await transport.close();
      await client.approve(part, true);
      expect(transport.bodies, hasLength(1));
      expect(part.approval!.approved, isFalse);
    });

    test(
        'cancelled approved actions cannot execute implicitly on the next prompt',
        () async {
      final part = AssistantPart.tool(
          id: 'tc1',
          name: 'write',
          approval: AssistantApproval(id: 'approval'));
      final transport = _FakeTransport();
      final client = ChatClient(transport: transport, messages: [
        AssistantTurn(id: 'a', role: 'assistant', parts: [part])
      ]);
      await client.approve(part, true);
      await client.stop();
      expect(part.state, 'error');
      expect(part.output, isNotNull);
      await client.sendText('What happened?');
      final messages = transport.bodies.last['messages'] as List;
      final sent = (messages.first['parts'] as List).single;
      expect(sent['state'], 'error');
      expect(sent.containsKey('output'), isTrue);
      await client.stop();
    });

    test('denial omits pendingExecution', () async {
      final part = AssistantPart.tool(
        id: 'tc1',
        name: 'assign_lead',
        approval: AssistantApproval(id: 'approval_tc1'),
      );
      final turn = AssistantTurn(
        id: 'a1',
        role: 'assistant',
        parts: [part],
      );
      final transport = _FakeTransport();
      final client = ChatClient(transport: transport, messages: [turn]);

      await client.approve(part, false);

      final messages = assistantModelMessages(client.messages);
      expect(jsonDecode(messages[1]['content'] as String), {
        'approved': false,
        'message': 'User denied this action',
      });
      await client.stop();
    });

    test('custom bodyBuilder receives the current messages', () async {
      final transport = _FakeTransport();
      final client = ChatClient(
        transport: transport,
        bodyBuilder: (messages) => {
          'messages': assistantWireMessages(messages),
          'threadId': 'thread-7',
        },
      );

      await client.sendText('Hello');
      expect(transport.bodies.single['threadId'], 'thread-7');
      await client.stop();
    });

    test('stop cancels promptly and resets streaming state', () async {
      final transport = _FakeTransport();
      final client = ChatClient(transport: transport);

      await client.sendText('Hello');
      final assistant = client.messages.last;
      expect(assistant.streaming, isTrue);

      await client.stop();

      expect(client.status, ChatClientStatus.idle);
      expect(assistant.streaming, isFalse);
      expect(transport.controllers.single.hasListener, isFalse);
    });

    test('stream error sets error status', () async {
      final transport = _FakeTransport();
      final client = ChatClient(transport: transport);

      await client.sendText('Hello');
      transport.emitError(const FormatException('bad frame'));
      await Future<void>.delayed(Duration.zero);

      expect(client.status, ChatClientStatus.error);
      expect(client.error, contains('bad frame'));
    });

    test('RUN_ERROR event sets error status', () async {
      final transport = _FakeTransport();
      final client = ChatClient(transport: transport);

      await client.sendText('Hello');
      transport.emit({'type': 'RUN_ERROR', 'message': 'provider failed'});
      await transport.close();

      expect(client.status, ChatClientStatus.error);
      expect(client.error, 'provider failed');
    });
  });
}

class _FakeTransport implements ChatTransport {
  final List<Map<String, dynamic>> bodies = <Map<String, dynamic>>[];
  final List<StreamController<Map<String, dynamic>>> controllers =
      <StreamController<Map<String, dynamic>>>[];

  @override
  Stream<Map<String, dynamic>> stream(Map<String, dynamic> body) {
    bodies.add(body);
    final controller = StreamController<Map<String, dynamic>>();
    controllers.add(controller);
    return controller.stream;
  }

  void emit(Map<String, dynamic> event) {
    controllers.last.add(event);
  }

  void emitError(Object error, [StackTrace? stack]) {
    controllers.last.addError(error, stack);
  }

  Future<void> close() => controllers.last.close();
}
