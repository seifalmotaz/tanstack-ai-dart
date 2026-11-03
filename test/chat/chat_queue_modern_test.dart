import 'dart:async';

import 'package:tanstack_ai_dart/chat.dart';
import 'package:tanstack_ai_dart/connections.dart' as conn;
import 'package:test/test.dart';

import 'support.dart' show waitFor;

class HoldingConnection {
  final requests = <({
    List<conn.WireMessage> messages,
    Map<String, dynamic>? data,
    conn.RunAgentInputContext context
  })>[];
  final controllers = <StreamController<Map<String, dynamic>>>[];

  late final adapter = conn.ConnectionAdapter.connect(
    connect: (messages, {data, signal, required runContext}) {
      requests.add((messages: messages, data: data, context: runContext));
      final controller = StreamController<Map<String, dynamic>>();
      controllers.add(controller);
      signal?.whenCancelled.then((_) {
        if (!controller.isClosed) unawaited(controller.close());
      });
      return controller.stream;
    },
  );

  Future<void> finish(int index, {bool error = false}) async {
    final controller = controllers[index];
    final context = requests[index].context;
    controller.add({
      'type': 'RUN_STARTED',
      'threadId': context.threadId,
      'runId': context.runId
    });
    controller.add(error
        ? {
            'type': 'RUN_ERROR',
            'threadId': context.threadId,
            'runId': context.runId,
            'message': 'boom'
          }
        : {
            'type': 'RUN_FINISHED',
            'threadId': context.threadId,
            'runId': context.runId,
            'outcome': {'type': 'success'}
          });
    await controller.close();
  }
}

void main() {
  test('modern queue drains FIFO after each held stream settles', () async {
    final holding = HoldingConnection();
    final client =
        ChatClient(connection: holding.adapter, threadId: 'thread-1');
    final first = client.sendText('first');
    await waitFor(() => holding.requests.length == 1 && client.isLoading);
    await client.sendText('second');
    await client.sendText('third');
    expect(client.getQueue().map((item) => item.content), ['second', 'third']);
    await holding.finish(0);
    await waitFor(() => holding.requests.length == 2);
    await holding.finish(1);
    await waitFor(() => holding.requests.length == 3);
    await holding.finish(2);
    await first;
    await waitFor(() => !client.isLoading);
    expect(
        client
            .getMessages()
            .where((m) => m.role == 'user')
            .map((m) => m.answer),
        ['first', 'second', 'third']);
    expect(client.getQueue(), isEmpty);
    await client.dispose();
  });
}
