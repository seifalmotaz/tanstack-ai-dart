import 'package:tanstack_ai_dart/tanstack_ai_dart.dart';
import 'package:test/test.dart';
import 'package:tanstack_ai_dart/src/chat/message_snapshot.dart';

void main() {
  test('snapshots expose lifecycle and freeze queued content and body',
      () async {
    final client = ChatClient(connection: ConnectionAdapter(
      connect: (_, {data, signal, runContext}) async* {
        yield {
          'type': 'RUN_STARTED',
          'runId': runContext!.runId,
          'threadId': runContext.threadId
        };
        await signal!.whenCancelled;
      },
    ));
    addTearDown(client.dispose);
    final running = client.sendMessage('first');
    await Future<void>.delayed(Duration.zero);
    final body = <String, dynamic>{
      'nested': {'value': 1}
    };
    await client.sendMessage({
      'content': [
        {'type': 'text', 'content': 'queued'}
      ]
    }, sendOptions: ChatSendOptions(body: body));
    final snapshot = client.getSnapshot();
    expect(snapshot.isSubscribed, client.getIsSubscribed());
    expect(snapshot.connectionStatus, client.getConnectionStatus());
    expect(snapshot.runId, client.getCurrentRunId());
    expect(snapshot.interruptState, same(client.getInterruptState()));
    expect(snapshot.queue, hasLength(1));
    expect(() => snapshot.queue.clear(), throwsUnsupportedError);
    expect(() => (snapshot.queue.single.content as Map)['content'] = [],
        throwsUnsupportedError);
    expect(() => (snapshot.queue.single.body!['nested'] as Map)['value'] = 2,
        throwsUnsupportedError);
    (body['nested'] as Map)['value'] = 3;
    expect((snapshot.queue.single.body!['nested'] as Map)['value'], 1);
    await client.stop();
    await running;
  });

  test(
      'mutable copies preserve signed and unknown parts without sharing containers',
      () {
    final source = AssistantTurn(id: 'a', role: 'assistant', parts: [
      AssistantPart.fromJson({
        'type': 'thinking',
        'content': 'A',
        'signature': 'signed',
        'custom': {
          'v': [1]
        }
      }),
      AssistantPart.fromJson({
        'type': 'tool-call',
        'id': 't',
        'name': 'lookup',
        'state': 'complete',
        'output': null
      }),
    ]);
    final copied = copyAssistantTurn(freezeAssistantTurn(source));
    expect(copied.parts.map((part) => part.toJson()),
        source.parts.map((part) => part.toJson()));
    (copied.parts.first.wireFields!['custom'] as Map)['v'] = [2];
    expect((source.parts.first.wireFields!['custom'] as Map)['v'], [1]);
    expect(copied.parts.last.hasInput, isFalse);
    expect(copied.parts.last.hasOutput, isTrue);
    expect(copied.parts.last.output, isNull);
  });

  ChatClient clientWith(AssistantTurn turn) => ChatClient(
        connection: ConnectionAdapter(
            connect: (messages, {data, signal, runContext}) =>
                const Stream.empty()),
        messages: [turn],
      );

  test(
      'snapshots freeze typed fields, unknown fields, nested maps and approvals',
      () async {
    final turn = AssistantTurn(id: 'a', role: 'assistant', parts: [
      AssistantPart.fromJson({
        'type': 'thinking',
        'content': 'Reasoning',
        'signature': 'signed',
        'custom': {
          'nested': [1]
        },
      }),
      AssistantPart.fromJson({
        'type': 'tool-call',
        'id': 't',
        'name': 'lookup',
        'input': null,
        'output': null,
        'state': 'approval-requested',
        'approval': {
          'id': 'approval',
          'needsApproval': true,
          'custom': {'v': 1}
        },
      }),
    ]);
    final client = clientWith(turn);
    addTearDown(client.dispose);
    final snapshot = client.getSnapshot();
    expect(snapshot.messages.single.parts.first.toJson(),
        turn.parts.first.toJson());
    expect(() => snapshot.messages.single.streaming = true,
        throwsUnsupportedError);
    expect(() => snapshot.messages.single.parts.first.content = 'changed',
        throwsUnsupportedError);
    expect(
        () => (snapshot.messages.single.parts.first.wireFields!['custom']
            as Map)['nested'] = [],
        throwsUnsupportedError);
    expect(() => snapshot.messages.single.parts.last.approval!.approved = true,
        throwsUnsupportedError);
    expect(turn.parts.last.approval!.approved, isNull);
  });

  test(
      'unchanged messages preserve snapshot identity and manual replacement copies input before clearing',
      () async {
    final client = clientWith(AssistantTurn(
        id: 'a', role: 'assistant', parts: [AssistantPart.text('A')]));
    addTearDown(client.dispose);
    final first = client.getSnapshot();
    client.updateOptions(context: Object());
    final second = client.getSnapshot();
    expect(identical(first.messages.single, second.messages.single), isTrue);
    client.setMessagesManually(client.messages);
    expect(client.messages.single.answer, 'A');
    client.setMessagesManually(second.messages);
    client.messages.single.parts.first.content = 'B';
    expect(second.messages.single.answer, 'A');
    expect(client.getSnapshot().messages.single.answer, 'B');
  });

  test('non-JSON tool outputs do not hide later text or streaming changes',
      () async {
    int callback() => 1;
    final turn = AssistantTurn(id: 'a', role: 'assistant', parts: [
      AssistantPart.text('A'),
      AssistantPart.tool(id: 't', name: 'lookup', output: callback)
    ]);
    final client = clientWith(turn);
    addTearDown(client.dispose);
    final first = client.getSnapshot();
    client.messages.single.parts.first.content = 'B';
    client.messages.single.streaming = true;
    client.updateOptions(context: Object());
    final next = client.getSnapshot();
    expect(next.messages.single.answer, 'B');
    expect(next.messages.single.streaming, isTrue);
    expect(identical(next.messages.single.parts.last.output, callback), isTrue);
    expect(first.messages.single.answer, 'A');
  });
}
