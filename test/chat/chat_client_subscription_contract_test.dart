// Upstream reference: packages/ai-client/tests/chat-client.test.ts
//
// The Dart client has no long-lived subscribe loop: `subscribe()` only tracks
// the public flag, and each send opens its own subscribe/send request. These
// tests cover the behavior that exists; the removed upstream cases are marked
// `not-implemented` in upstream_mapping.json.
import 'dart:async';

import 'package:tanstack_ai_dart/chat.dart';
import 'package:tanstack_ai_dart/connections.dart' as conn;
import 'package:test/test.dart';

import 'support.dart';

class PushConnection {
  final controller = StreamController<Map<String, dynamic>>.broadcast();
  final List<List<Map<String, dynamic>>> sent = <List<Map<String, dynamic>>>[];
  late final conn.ConnectionAdapter adapter = conn.ConnectionAdapter(
    subscribe: ({signal}) => controller.stream,
    send: (messages, {data, signal, runContext}) async {
      sent.add(messages);
    },
  );
  void push(Map<String, dynamic> chunk) => controller.add(chunk);
  Future<void> close() => controller.close();
}

void main() {
  group('ChatClient subscribe/send connection mode', () {
    test('streams chunks pushed after a send starts', () async {
      final push = PushConnection();
      final client = ChatClient(connection: push.adapter);
      final send = client.sendText('hello');
      await waitFor(() => push.sent.isNotEmpty);

      push.push(<String, dynamic>{
        'type': 'TEXT_MESSAGE_CONTENT',
        'messageId': 'm',
        'delta': 'ok',
      });
      push.push(<String, dynamic>{
        'type': 'RUN_FINISHED',
        'runId': 'r',
        'threadId': 't',
        'outcome': <String, dynamic>{'type': 'success'},
      });
      await send;

      expect(client.getMessages().any((m) => m.answer == 'ok'), isTrue);
      expect(client.getStatus(), 'ready');
      await client.dispose();
    });

    test('stop does not unsubscribe an active subscription', () async {
      final client = ChatClient(connection: PushConnection().adapter);
      client.subscribe();
      await client.stop();
      expect(client.getIsSubscribed(), isTrue);
      await client.dispose();
    });

    test('subscribe is idempotent', () async {
      final client = ChatClient(connection: PushConnection().adapter);
      client.subscribe();
      client.subscribe();
      expect(client.getIsSubscribed(), isTrue);
      await client.dispose();
    });

    test('subscribe with restart keeps the subscription active', () async {
      final client = ChatClient(connection: PushConnection().adapter);
      client.subscribe();
      client.subscribe(restart: true);
      expect(client.getIsSubscribed(), isTrue);
      await client.dispose();
    });

    test('unsubscribe is idempotent', () async {
      final client = ChatClient(connection: PushConnection().adapter);
      client.subscribe();
      await client.unsubscribe();
      await client.unsubscribe();
      expect(client.getIsSubscribed(), isFalse);
      await client.dispose();
    });

    test('sessionGenerating is false initially', () async {
      final client = ChatClient(connection: PushConnection().adapter);
      expect(client.getSessionGenerating(), isFalse);
      await client.dispose();
    });

    test('sessionGenerating flips on RUN_STARTED and RUN_FINISHED', () async {
      final push = PushConnection();
      final client = ChatClient(connection: push.adapter);
      final send = client.sendText('hello');
      await waitFor(() => push.sent.isNotEmpty);

      push.push(<String, dynamic>{'type': 'RUN_STARTED', 'runId': 'r1'});
      await waitFor(() => client.getSessionGenerating());

      push.push(<String, dynamic>{
        'type': 'RUN_FINISHED',
        'runId': 'r1',
        'threadId': 't',
        'outcome': <String, dynamic>{'type': 'success'},
      });
      await send;
      expect(client.getSessionGenerating(), isFalse);
      await client.dispose();
    });

    test('sessionGenerating stays true until a terminal event arrives',
        () async {
      final push = PushConnection();
      final client = ChatClient(connection: push.adapter);
      final send = client.sendText('hello');
      await waitFor(() => push.sent.isNotEmpty);

      push.push(<String, dynamic>{'type': 'RUN_STARTED', 'runId': 'r1'});
      await waitFor(() => client.getSessionGenerating());
      expect(client.getSessionGenerating(), isTrue);
      await client.stop();
      await send;
      await client.dispose();
    });

    test('sessionGenerating clears on RUN_ERROR', () async {
      final push = PushConnection();
      final client = ChatClient(connection: push.adapter);
      final send = client.sendText('hello');
      await waitFor(() => push.sent.isNotEmpty);

      push.push(<String, dynamic>{'type': 'RUN_STARTED', 'runId': 'r1'});
      await waitFor(() => client.getSessionGenerating());
      push.push(<String, dynamic>{'type': 'RUN_ERROR', 'runId': 'r1'});
      await send;
      expect(client.getSessionGenerating(), isFalse);
      await client.dispose();
    });
  });
}
