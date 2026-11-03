import 'dart:async';

import 'package:tanstack_ai_dart/tanstack_ai_dart.dart';
import 'package:test/test.dart';

ConnectionAdapter replyConnection({List<WireMessage>? seen}) => stream(
      (request) async* {
        seen?.addAll(request.messages);
        yield {'type': 'RUN_STARTED', 'threadId': 'thread', 'runId': 'run'};
        yield {
          'type': 'TEXT_MESSAGE_START',
          'messageId': 'answer',
          'role': 'assistant'
        };
        yield {
          'type': 'TEXT_MESSAGE_CONTENT',
          'messageId': 'answer',
          'delta': 'أهلاً'
        };
        yield {'type': 'TEXT_MESSAGE_END', 'messageId': 'answer'};
        yield {'type': 'RUN_FINISHED', 'threadId': 'thread', 'runId': 'run'};
      },
    );

void main() {
  test(
      'typed constructor sends text and emits current state then ordered updates',
      () async {
    final seen = <WireMessage>[];
    final client =
        ChatClient(connection: replyConnection(seen: seen), threadId: 'thread');
    final snapshots = <ChatSnapshot>[];
    final first = client.states.listen(snapshots.add);
    await Future<void>.delayed(Duration.zero);
    expect(snapshots.single.state, ChatClientState.ready);
    await client.sendText('Hello');
    await Future<void>.delayed(Duration.zero);
    expect(seen.first['role'], 'user');
    expect(client.messages.last.answer, 'أهلاً');
    expect(snapshots.any((s) => s.state == ChatClientState.streaming), isTrue);
    expect(snapshots.last.state, ChatClientState.ready);
    expect(snapshots.last.messages.last.answer, 'أهلاً');
    expect(snapshots.first.messages, isEmpty);
    final lateStates = <ChatSnapshot>[];
    final second = client.states.listen(lateStates.add);
    await Future<void>.delayed(Duration.zero);
    expect(lateStates.single, same(client.snapshot));
    await first.cancel();
    await second.cancel();
    await client.dispose();
  });

  test('typed messages retain IDs, metadata and parts', () async {
    final seen = <WireMessage>[];
    final client =
        ChatClient(threadId: 'thread', connection: replyConnection(seen: seen));
    await client.sendMessage(ChatMessageInput.parts(
      [AssistantPart.text('Hello')],
      id: 'custom',
      metadata: {'language': 'en'},
    ));
    expect(client.messages.first.id, 'custom');
    expect(client.messages.first.metadata, {'language': 'en'});
    expect(client.messages.first.parts.single.chatPart, isA<ChatTextPart>());
    await client.dispose();
  });

  test(
      'transcript and initial data cannot mutate client state without an action',
      () async {
    final initial = AssistantTurn.user('before');
    final client = ChatClient(
        threadId: 'thread',
        connection: replyConnection(),
        initialMessages: [initial]);
    initial.parts.single.content = 'outside';
    expect(client.messages.single.answer, 'before');
    expect(() => client.messages.clear(), throwsUnsupportedError);
    expect(() => client.messages.single.parts.single.content = 'changed',
        throwsUnsupportedError);
    client.setMessagesManually([AssistantTurn.user('replacement')]);
    expect(client.messages.single.answer, 'replacement');
    await client.dispose();
  });

  test('typed setters clear nullable options and update tools', () async {
    final client = ChatClient(
        threadId: 'thread',
        connection: replyConnection(),
        context: 'old',
        forwardedProps: {'old': true});
    client.context = null;
    client.forwardedProps = {'provider': 'test'};
    client.tools = [
      ClientTool<String, String>(name: 'echo', execute: (v, _) => v)
    ];
    expect(client.context, isNull);
    expect(client.forwardedProps, {'provider': 'test'});
    expect(client.tools.single.name, 'echo');
    client.replaceConnection(replyConnection());
    await client.sendText('After replacement');
    expect(client.messages.last.answer, 'أهلاً');
    expect(() => client.tools.clear(), throwsUnsupportedError);
    await client.dispose();
  });

  test('dispose closes state streams without waiting for paused subscriptions',
      () async {
    final client =
        ChatClient(threadId: 'thread', connection: replyConnection());
    final done = Completer<void>();
    final active = client.states.listen((_) {}, onDone: done.complete);
    final paused = client.states.listen((_) {})..pause();
    await client.dispose().timeout(const Duration(seconds: 1));
    await done.future.timeout(const Duration(seconds: 1));
    await paused.cancel();
    await active.cancel();
    expect(await client.states.toList(), isEmpty);
  });

  test(
      'stream listener can issue a new action without reentrant controller errors',
      () async {
    final client =
        ChatClient(threadId: 'thread', connection: replyConnection());
    var changed = false;
    final sub = client.states.listen((snapshot) {
      if (!changed) {
        changed = true;
        client.setMessagesManually([AssistantTurn.user('from listener')]);
      }
    });
    await Future<void>.delayed(Duration.zero);
    expect(client.messages.single.answer, 'from listener');
    await sub.cancel();
    await client.dispose();
  });

  test('thread ID must not be empty', () {
    expect(
        () => ChatClient(
            connection: replyConnection(),
            threadId: '',
            persistence: const ChatPersistenceOptions.server()),
        throwsArgumentError);
  });
}
