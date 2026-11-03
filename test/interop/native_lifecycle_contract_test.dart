import 'dart:async';
import 'package:tanstack_ai_dart/tanstack_ai_dart.dart';
import 'package:test/test.dart';

void main() {
  test('a pre-subscribed synchronous push connection settles and closes',
      () async {
    final source = StreamController<Map<String, dynamic>>.broadcast(sync: true);
    final sent = Completer<void>();
    final subscriptions = <bool>[];
    final states = <String>[];
    final client = ChatClient(
        connection: ConnectionAdapter(
            subscribe: ({signal}) => source.stream,
            send: (messages, {data, signal, runContext}) async {
              if (!sent.isCompleted) sent.complete();
            }),
        onSubscriptionChange: subscriptions.add,
        onConnectionStatusChange: states.add);
    addTearDown(client.dispose);
    client.subscribe();
    final pending = client.sendMessage('Hello');
    await sent.future;
    for (final character in 'callback flow'.split('')) {
      source.add({
        'type': 'TEXT_MESSAGE_CONTENT',
        'messageId': 'msg-1',
        'delta': character
      });
    }
    source.add({
      'type': 'RUN_FINISHED',
      'runId': 'run-msg-1',
      'threadId': 'thread-msg-1'
    });
    await pending.timeout(const Duration(seconds: 1),
        onTimeout: () =>
            fail('send stuck: ${client.getStatus()} ${client.getError()}'));
    await client.unsubscribe().timeout(const Duration(seconds: 1),
        onTimeout: () => fail('unsubscribe stuck'));
    expect(subscriptions, [true, false]);
    expect(states, ['connecting', 'connected', 'disconnected']);
    await source.close().timeout(const Duration(seconds: 1),
        onTimeout: () => fail('producer close stuck'));
  });
}
