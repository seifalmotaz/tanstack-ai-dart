import 'dart:async';
import 'package:tanstack_ai_dart/tanstack_ai_dart.dart';
import 'package:test/test.dart';

Future<void> settled(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 4));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('join did not settle');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

ChatClient restored(JoinRunFunction join, {void Function(Object)? onError}) =>
    ChatClient(
      connection: ConnectionAdapter(
        connect: (_, {data, signal, runContext}) => const Stream.empty(),
        joinRun: join,
      ),
      threadId: 't',
      initialMessages: [AssistantTurn.user('kept', id: 'u')],
      initialResumeSnapshot: const ChatResumeSnapshot(
        resumeState: ChatResumeState(threadId: 't', runId: 'r'),
      ),
      onError: (error, _) => onError?.call(error),
    );

void main() {
  test('stop does not await a custom adapter cleanup that never settles',
      () async {
    var cancellations = 0;
    final body = StreamController<Map<String, dynamic>>(
      onCancel: () {
        cancellations++;
        return Completer<void>().future;
      },
    );
    final client = ChatClient(
        connection: ConnectionAdapter(
      connect: (_, {data, signal, runContext}) => body.stream,
    ));
    addTearDown(client.dispose);
    final run = client.sendMessage('hello');
    await settled(() => body.hasListener);
    await client.stop().timeout(const Duration(milliseconds: 200));
    await run;
    expect(cancellations, 1);
    expect(client.getIsLoading(), isFalse);
    expect(client.getError(), isNull);
    unawaited(body.close());
  });

  test('join deadline frees input while retaining a quiet run pointer',
      () async {
    CancellationSignal? capturedSignal;
    var calls = 0;
    final client = restored((id, {signal}) async* {
      calls++;
      capturedSignal = signal;
      await signal!.whenCancelled;
    });
    addTearDown(client.dispose);
    expect(calls, 0);
    await client.attach();
    await settled(() => calls == 1 && !client.getIsLoading());
    expect(capturedSignal!.isAborted, isTrue);
    expect(client.getResumeState()?.runId, 'r');
    expect(client.getStatus(), 'ready');
    expect(client.messages.single.answer, 'kept');
    expect(client.getError(), isNull);
  });

  test('a refused join before its first chunk clears the dead pointer softly',
      () async {
    var errors = 0;
    final client = restored((id, {signal}) async* {
      throw StateError('Unknown or expired memory stream run');
    }, onError: (_) => errors++);
    addTearDown(client.dispose);
    await client.attach();
    await settled(() => !client.getIsLoading());
    expect(client.getResumeState(), isNull);
    expect(client.getStatus(), 'ready');
    expect(client.messages.single.answer, 'kept');
    expect(errors, 0);
  });

  test('post-attach rejoin errors surface to the consuming UI', () async {
    var errors = 0;
    final client = restored((id, {signal}) async* {
      yield {'type': 'RUN_STARTED', 'runId': id, 'threadId': 't'};
      throw StateError('reader failed after attach');
    }, onError: (_) => errors++);
    addTearDown(client.dispose);
    await client.attach();
    await settled(() => errors == 1);
    expect(client.getIsLoading(), isFalse);
    expect(client.getStatus(), 'error');
    expect(client.getError(), contains('reader failed after attach'));
  });
}
