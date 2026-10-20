import 'dart:async';
import 'package:tanstack_ai_dart/tanstack_ai_dart.dart';
import 'package:test/test.dart';

ConnectionAdapter _connection() =>
    ConnectionAdapter(connect: (messages, {data, signal, runContext}) async* {
      yield {'type': 'TEXT_MESSAGE_CONTENT', 'messageId': 'm', 'delta': 'a'};
      yield {'type': 'TEXT_MESSAGE_CONTENT', 'messageId': 'm', 'delta': 'b'};
      yield {'type': 'RUN_FINISHED', 'runId': 'run-m', 'threadId': 'thread-m'};
    });

void main() {
  group('ChatClient stream processing', () {
    test('does not wait for a macrotask after each live chunk', () async {
      var timerRan = false;
      final client = ChatClient(
          connection: _connection(),
          processingScheduler: StreamProcessingScheduler(now: () => 0));
      addTearDown(client.dispose);
      final timer = Timer(Duration.zero, () => timerRan = true);
      await client.sendMessage('Hi');
      expect(timerRan, isFalse);
      timer.cancel();
      expect(client.messages.last.answer, 'ab');
    });
    test('falls back to a timer after a full processing slice', () async {
      var timerRan = false;
      var now = 0;
      final client = ChatClient(
          connection: _connection(),
          processingScheduler: StreamProcessingScheduler(
              now: () => now += 9,
              isHidden: () => false,
              yieldToHost: () => Future<void>.delayed(Duration.zero)));
      addTearDown(client.dispose);
      Timer.run(() => timerRan = true);
      await client.sendMessage('Hi');
      expect(timerRan, isTrue);
    });
    test('uses the scheduler after a full processing slice', () async {
      var yields = 0;
      var now = 0;
      var timerRan = false;
      final timer = Timer(Duration.zero, () => timerRan = true);
      final client = ChatClient(
          connection: _connection(),
          processingScheduler: StreamProcessingScheduler(
              now: () => now += 9,
              isHidden: () => false,
              yieldToHost: () async {
                yields++;
              }));
      addTearDown(client.dispose);
      await client.sendMessage('Hi');
      expect(yields, greaterThan(0));
      expect(timerRan, isFalse);
      timer.cancel();
    });
    test('does not yield in a hidden document', () async {
      var yields = 0;
      var now = 0;
      var timerRan = false;
      final timer = Timer(Duration.zero, () => timerRan = true);
      final client = ChatClient(
          connection: _connection(),
          processingScheduler: StreamProcessingScheduler(
              now: () => now += 9,
              isHidden: () => true,
              yieldToHost: () async {
                yields++;
              }));
      addTearDown(client.dispose);
      await client.sendMessage('Hi');
      expect(yields, 0);
      expect(timerRan, isFalse);
      timer.cancel();
    });
    test('does not carry hidden-page processing time into a visible page',
        () async {
      var now = 0;
      var hidden = true;
      var yields = 0;
      final client = ChatClient(
          connection: _connection(),
          processingScheduler: StreamProcessingScheduler(
              now: () => now,
              isHidden: () => hidden,
              yieldToHost: () async {
                yields++;
              }),
          onChunk: (chunk) {
            now += 5;
            if (chunk['type'] == 'RUN_FINISHED') hidden = false;
          });
      addTearDown(client.dispose);
      await client.sendMessage('Hi');
      expect(yields, 0);
      expect(client.messages.last.answer, 'ab');
    });
  });
}
