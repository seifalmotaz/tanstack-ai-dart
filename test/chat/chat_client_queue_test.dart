// Upstream reference: packages/ai-client/tests/chat-client-queue.test.ts
import 'package:tanstack_ai_dart/chat.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('normalizeQueueOption', () {
    test('defaults to queue + fifo + reject', () {
      final config = ChatQueueConfig.from(null);
      expect(config.whenBusy, QueueWhenBusy.queue);
      expect(config.drain, QueueDrainMode.fifo);
      expect(config.onOverflow, QueueOverflow.reject);
      expect(config.maxSize, isNull);
    });

    test('treats a string as whenBusy shorthand', () {
      expect(ChatQueueConfig.from('drop').whenBusy, QueueWhenBusy.drop);
      expect(
        ChatQueueConfig.from('interrupt').whenBusy,
        QueueWhenBusy.interrupt,
      );
      expect(ChatQueueConfig.from('queue').whenBusy, QueueWhenBusy.queue);
    });

    test('carries a function as strategy and forces fifo', () {
      final config = ChatQueueConfig.from(<String, dynamic>{
        'drain': 'batch',
        'strategy': (ChatQueueStrategyInput input) => QueueWhenBusy.drop,
      });
      expect(config.strategy, isNotNull);
      expect(config.drain, QueueDrainMode.fifo);
    });

    test('merges a config object over defaults', () {
      final config = ChatQueueConfig.from(<String, dynamic>{
        'whenBusy': 'drop',
        'drain': 'batch',
        'maxSize': 2,
        'onOverflow': 'drop-oldest',
      });
      expect(config.whenBusy, QueueWhenBusy.drop);
      expect(config.drain, QueueDrainMode.batch);
      expect(config.maxSize, 2);
      expect(config.onOverflow, QueueOverflow.dropOldest);
    });

    test('rejects invalid maxSize', () {
      expect(
        () => ChatQueueConfig.from(<String, dynamic>{'maxSize': -1}),
        throwsArgumentError,
      );
    });
  });

  group('ChatClient message queue', () {
    test(
        'enqueues (not drops) a send while streaming and reports via onQueueChange',
        () async {
      final transport = FakeChatTransport();
      final reports = <List<QueuedMessage>>[];
      final client = ChatClient(
        transport: transport,
        onQueueChange: reports.add,
      );
      await client.sendText('first');
      await client.sendText('second');
      expect(client.getQueue().single.content, 'second');
      expect(reports, isNotEmpty);
      expect(reports.last.single.content, 'second');
      await client.stop();
    });

    test('cancelQueued removes a queued item before it drains', () async {
      final transport = FakeChatTransport();
      final client = ChatClient(transport: transport);
      await client.sendText('first');
      await client.sendText('second');
      final id = client.getQueue().single.id;
      client.cancelQueued(id);
      expect(client.getQueue(), isEmpty);
      await emitAll(transport, textChunks('done'));
      await transport.close();
      await pump();
      expect(transport.bodies, hasLength(1));
    });

    test("whenBusy: 'drop' ignores a mid-stream send", () async {
      final transport = FakeChatTransport();
      final client = ChatClient(
        transport: transport,
        queue: const ChatQueueConfig(whenBusy: QueueWhenBusy.drop),
      );
      await client.sendText('first');
      await client.sendText('second');
      expect(client.getQueue(), isEmpty);
      await emitAll(transport, textChunks('done'));
      await transport.close();
      await pump();
      expect(transport.bodies, hasLength(1));
    });
  });

  group('ChatClient queue drain', () {
    test('drains FIFO after the stream settles, in order', () async {
      final transport = FakeChatTransport();
      final client = ChatClient(transport: transport);
      await client.sendText('first');
      await client.sendText('second');
      await client.sendText('third');
      await emitAll(transport, textChunks('one'));
      await transport.close();
      await waitFor(() => transport.bodies.length == 2);
      await emitAll(transport, textChunks('two', runId: 'run-2'));
      await transport.closeAt(1);
      await waitFor(() => transport.bodies.length == 3);
      await emitAll(transport, textChunks('three', runId: 'run-3'));
      await transport.closeAt(2);
      await pump(8);
      final sent = transport.bodies
          .map((body) => (body['messages'] as List).last)
          .map((row) => (row as Map)['parts'] as List)
          .map((parts) => (parts.first as Map)['content'])
          .toList();
      expect(sent, <String>['first', 'second', 'third']);
    });

    test('batch drain merges string queued items with newlines', () async {
      final transport = FakeChatTransport();
      final client = ChatClient(
        transport: transport,
        queue: const ChatQueueConfig(drain: QueueDrainMode.batch),
      );
      await client.sendText('first');
      await client.sendText('a');
      await client.sendText('b');
      await emitAll(transport, textChunks('one'));
      await transport.close();
      await waitFor(() => transport.bodies.length == 2);
      final lastUser = (transport.bodies[1]['messages'] as List).last as Map;
      expect((lastUser['parts'] as List).single['content'], 'a\nb');
      await client.stop();
    });

    test('batch drain flattens multimodal queued items', () async {
      final transport = FakeChatTransport();
      final client = ChatClient(
        transport: transport,
        queue: const ChatQueueConfig(drain: QueueDrainMode.batch),
      );
      await client.sendText('first');
      await client.sendMessage(
        const ChatMessageInput(
          content: <Map<String, dynamic>>[
            <String, dynamic>{'type': 'text', 'content': 'look'},
            <String, dynamic>{
              'type': 'image',
              'source': <String, dynamic>{
                'type': 'url',
                'value': 'https://example.com/a.png',
              },
            },
          ],
        ),
      );
      await client.sendText('tail');
      await emitAll(transport, textChunks('one'));
      await transport.close();
      await waitFor(() => transport.bodies.length == 2);
      final lastUser = (transport.bodies[1]['messages'] as List).last as Map;
      final parts = lastUser['parts'] as List;
      expect(parts.map((p) => (p as Map)['type']), <String>[
        'text',
        'image',
        'text',
      ]);
      await client.stop();
    });

    test('flushes the queue on stop()', () async {
      final transport = FakeChatTransport();
      final client = ChatClient(transport: transport);
      await client.sendText('first');
      await client.sendText('second');
      await client.stop();
      expect(client.getQueue(), isEmpty);
    });

    test('flushes the queue when the stream errors', () async {
      final transport = FakeChatTransport();
      final client = ChatClient(transport: transport);
      await client.sendText('first');
      await client.sendText('second');
      transport.emit(<String, dynamic>{
        'type': 'RUN_ERROR',
        'message': 'boom',
      });
      await transport.close();
      await pump();
      expect(client.getQueue(), isEmpty);
    });

    test('flushes the queue on clear()', () async {
      final transport = FakeChatTransport();
      final client = ChatClient(transport: transport);
      await client.sendText('first');
      await client.sendText('second');
      await client.clear();
      expect(client.getQueue(), isEmpty);
    });

    test('flushes the queue on reload()', () async {
      final transport = FakeChatTransport();
      final client = ChatClient(transport: transport);
      await client.sendText('first');
      await client.sendText('second');
      await client.reload();
      expect(client.getQueue(), isEmpty);
      await client.stop();
    });

    test('flushes the queue on unsubscribe()', () async {
      final transport = FakeChatTransport();
      final client = ChatClient(transport: transport);
      await client.sendText('first');
      await client.sendText('second');
      await client.unsubscribe();
      expect(client.getQueue(), isEmpty);
    });
  });

  group('ChatClient queue policy branches', () {
    test(
        "whenBusy: 'interrupt' aborts the in-flight stream and sends immediately",
        () async {
      final transport = FakeChatTransport();
      final client = ChatClient(
        transport: transport,
        queue: const ChatQueueConfig(whenBusy: QueueWhenBusy.interrupt),
      );
      await client.sendText('first');
      await client.sendText('second');
      expect(transport.bodies, hasLength(2));
      expect(client.getQueue(), isEmpty);
      expect(
        (transport.bodies[1]['messages'] as List)
            .where((row) => (row as Map)['role'] == 'user')
            .length,
        2,
      );
      await client.stop();
    });

    test('per-call whenBusy override beats the client default', () async {
      final transport = FakeChatTransport();
      final client = ChatClient(
        transport: transport,
        queue: const ChatQueueConfig(whenBusy: QueueWhenBusy.drop),
      );
      await client.sendText('first');
      await client.sendText(
        'second',
        options: const ChatSendOptions(whenBusy: QueueWhenBusy.queue),
      );
      expect(client.getQueue(), hasLength(1));
      await client.stop();
    });

    test("maxSize + onOverflow: 'reject' drops the newest when full", () async {
      final transport = FakeChatTransport();
      final client = ChatClient(
        transport: transport,
        queue: const ChatQueueConfig(maxSize: 1),
      );
      await client.sendText('first');
      await client.sendText('second');
      await client.sendText('third');
      expect(client.getQueue().single.content, 'second');
      await client.stop();
    });

    test("maxSize + onOverflow: 'drop-oldest' rotates the queue", () async {
      final transport = FakeChatTransport();
      final client = ChatClient(
        transport: transport,
        queue: const ChatQueueConfig(
          maxSize: 1,
          onOverflow: QueueOverflow.dropOldest,
        ),
      );
      await client.sendText('first');
      await client.sendText('second');
      await client.sendText('third');
      expect(client.getQueue().single.content, 'third');
      await client.stop();
    });

    test('maxSize: 0 never enqueues under drop-oldest', () async {
      final transport = FakeChatTransport();
      final client = ChatClient(
        transport: transport,
        queue: const ChatQueueConfig(
          maxSize: 0,
          onOverflow: QueueOverflow.dropOldest,
        ),
      );
      await client.sendText('first');
      await client.sendText('second');
      expect(client.getQueue(), isEmpty);
      await client.stop();
    });

    test('QueueStrategy pending.id matches the enqueued item id', () async {
      final seen = <String>[];
      final transport = FakeChatTransport();
      final client = ChatClient(
        transport: transport,
        queue: ChatQueueConfig(
          strategy: (input) {
            seen.add(input.pending.id);
            return QueueWhenBusy.queue;
          },
        ),
      );
      await client.sendText('first');
      await client.sendText('second');
      expect(seen, hasLength(1));
      expect(client.getQueue().single.id, seen.single);
      await client.stop();
    });

    test('QueueStrategy drop and per-call whenBusy override', () async {
      final transport = FakeChatTransport();
      final client = ChatClient(
        transport: transport,
        queue: ChatQueueConfig(
          strategy: (_) => QueueWhenBusy.drop,
        ),
      );
      await client.sendText('first');
      await client.sendText('second');
      expect(client.getQueue(), isEmpty);
      await client.sendText(
        'third',
        options: const ChatSendOptions(whenBusy: QueueWhenBusy.queue),
      );
      expect(client.getQueue().single.content, 'third');
      await client.stop();
    });

    test('preserves per-message body through FIFO drain', () async {
      final transport = FakeChatTransport();
      final client = ChatClient(transport: transport);
      await client.sendText('first');
      await client.sendMessage(
        'second',
        body: <String, dynamic>{'model': 'gpt-5.5'},
      );
      await emitAll(transport, textChunks('one'));
      await transport.close();
      await waitFor(() => transport.bodies.length == 2);
      final forwarded = transport.bodies[1]['forwardedProps'] as Map;
      expect(forwarded['model'], 'gpt-5.5');
      await client.stop();
    });

    test('preserves sendOptions.body for queued sends', () async {
      final transport = FakeChatTransport();
      final client = ChatClient(transport: transport);
      await client.sendText('first');
      await client.sendText(
        'second',
        options: const ChatSendOptions(
          body: <String, dynamic>{'temperature': 0.2},
        ),
      );
      await emitAll(transport, textChunks('one'));
      await transport.close();
      await waitFor(() => transport.bodies.length == 2);
      final forwarded = transport.bodies[1]['forwardedProps'] as Map;
      expect(forwarded['temperature'], 0.2);
      await client.stop();
    });

    test('error during FIFO drain flushes remaining queued items', () async {
      final transport = FakeChatTransport();
      final client = ChatClient(transport: transport);
      await client.sendText('first');
      await client.sendText('second');
      await client.sendText('third');
      await emitAll(transport, textChunks('one'));
      await transport.close();
      await waitFor(() => transport.bodies.length == 2);
      transport.emit(<String, dynamic>{
        'type': 'RUN_ERROR',
        'message': 'boom',
      });
      await transport.closeAt(1);
      await pump(8);
      expect(client.getQueue(), isEmpty);
    });

    test('concurrent rapid sends do not strand user messages without streams',
        () async {
      final transport = FakeChatTransport();
      final client = ChatClient(transport: transport);
      await Future.wait(<Future<void>>[
        client.sendText('a'),
        client.sendText('b'),
        client.sendText('c'),
      ]);
      await emitAll(transport, textChunks('one'));
      await transport.close();
      await waitFor(() => transport.bodies.length >= 2);
      await emitAll(transport, textChunks('two', runId: 'run-2'));
      await transport.closeAt(1);
      await waitFor(() => transport.bodies.length >= 3);
      await emitAll(transport, textChunks('three', runId: 'run-3'));
      await transport.closeAt(2);
      await pump(8);
      final users = client
          .getMessages()
          .where((message) => message.role == 'user')
          .map((message) => message.answer)
          .toList();
      expect(users, <String>['a', 'b', 'c']);
      await client.stop();
    });

    test(
        'batch drain does not strand messages enqueued during the batch stream',
        () async {
      final transport = FakeChatTransport();
      final client = ChatClient(
        transport: transport,
        queue: const ChatQueueConfig(drain: QueueDrainMode.batch),
      );
      await client.sendText('first');
      await client.sendText('q1');
      await emitAll(transport, textChunks('one'));
      await transport.close();
      await waitFor(() => transport.bodies.length == 2);
      await client.sendText('late');
      await emitAll(transport, textChunks('two', runId: 'run-2'));
      await transport.closeAt(1);
      await waitFor(() => transport.bodies.length == 3);
      await emitAll(transport, textChunks('three', runId: 'run-3'));
      await transport.closeAt(2);
      await pump(8);
      expect(
        client
            .getMessages()
            .where((m) => m.role == 'user')
            .map((m) => m.answer),
        contains('late'),
      );
      await client.stop();
    });

    test(
        'interrupt during FIFO drain keeps remaining items for after the interrupt',
        () async {
      final transport = FakeChatTransport();
      final client = ChatClient(transport: transport);
      await client.sendText('first');
      await client.sendText('second');
      await client.sendText('third');
      await emitAll(transport, textChunks('one'));
      await transport.close();
      await waitFor(() => transport.bodies.length == 2);
      await client.sendText(
        'interrupt',
        options: const ChatSendOptions(whenBusy: QueueWhenBusy.interrupt),
      );
      expect(client.getQueue(), isNotEmpty);
      await emitAll(transport, textChunks('interrupted', runId: 'run-2'));
      await transport.closeAt(1);
      await pump(8);
      expect(
        client
            .getMessages()
            .where((m) => m.role == 'user')
            .map((m) => m.answer),
        contains('interrupt'),
      );
      await client.stop();
    });

    test('preserves per-message body through FIFO drain and batch last-wins',
        () async {
      final transport = FakeChatTransport();
      final client = ChatClient(
        transport: transport,
        queue: const ChatQueueConfig(drain: QueueDrainMode.batch),
      );
      await client.sendText('first');
      await client.sendMessage(
        'a',
        body: <String, dynamic>{'temperature': 0.1, 'keep': true},
      );
      await client.sendMessage(
        'b',
        body: <String, dynamic>{'temperature': 0.9},
      );
      await emitAll(transport, textChunks('one'));
      await transport.close();
      await waitFor(() => transport.bodies.length == 2);
      final forwarded = transport.bodies[1]['forwardedProps'] as Map;
      expect(forwarded['temperature'], 0.9);
      expect(forwarded['keep'], isTrue);
      await client.stop();
    });
  });
}
