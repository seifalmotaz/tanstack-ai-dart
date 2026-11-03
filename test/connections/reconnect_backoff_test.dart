import 'package:fake_async/fake_async.dart';
import 'package:tanstack_ai_dart/connections.dart';
import 'package:tanstack_ai_dart/src/connections/reconnect.dart'
    show reconnectBackoff;
import 'package:test/test.dart';

void main() {
  test('retry waits for Retry-After capped at maxDelay', () {
    fakeAsync((clock) {
      final tracker = ReconnectTracker(const ReconnectOptions(
          initialDelay: Duration(milliseconds: 1),
          maxDelay: Duration(milliseconds: 20)));
      var completed = false;
      tracker
          .waitBeforeReconnect(false, null, const Duration(seconds: 2))
          .then((_) => completed = true);
      clock.flushMicrotasks();
      clock.elapse(const Duration(milliseconds: 19));
      expect(completed, isFalse);
      clock.elapse(const Duration(milliseconds: 1));
      expect(completed, isTrue);
    });
  });

  test('tracker waits within exponential jitter bounds before retrying', () {
    expect(
        reconnectBackoff(const Duration(milliseconds: 250),
            const Duration(seconds: 5), 1, 1, null),
        const Duration(milliseconds: 250));
    expect(
        reconnectBackoff(const Duration(milliseconds: 250),
            const Duration(seconds: 5), 2, 1, null),
        const Duration(milliseconds: 500));
    expect(
        reconnectBackoff(const Duration(milliseconds: 250),
            const Duration(seconds: 5), 3, 1, null),
        const Duration(seconds: 1));
    fakeAsync((clock) {
      final tracker = ReconnectTracker(const ReconnectOptions(
          initialDelay: Duration(milliseconds: 100),
          maxDelay: Duration(milliseconds: 150)));
      for (var attempt = 1; attempt <= 5; attempt++) {
        var completed = false;
        tracker.waitBeforeReconnect(false).then((_) => completed = true);
        clock.flushMicrotasks();
        final maxMs = attempt == 1 ? 100 : 150;
        clock.elapse(Duration(microseconds: maxMs * 500 - 1));
        expect(completed, isFalse);
        clock.elapse(Duration(microseconds: maxMs * 500 + 1));
        expect(completed, isTrue);
      }
      Object? error;
      tracker.waitBeforeReconnect(false).then<void>((_) {},
          onError: (Object e) {
        error = e;
      });
      clock.flushMicrotasks();
      expect(error, isA<StreamReconnectLimitError>());
    });
  });

  test('backoff doubles, jitters, caps, and honors Retry-After', () {
    const upstreamInitial = Duration(milliseconds: 250);
    expect(
        reconnectBackoff(
            upstreamInitial, const Duration(seconds: 5), 1, 1, null),
        upstreamInitial);
    expect(
        reconnectBackoff(
            upstreamInitial, const Duration(seconds: 5), 2, 1, null),
        const Duration(milliseconds: 500));
    expect(
        reconnectBackoff(
            upstreamInitial, const Duration(seconds: 5), 3, 1, null),
        const Duration(seconds: 1));
    const initial = Duration(milliseconds: 100);
    const max = Duration(milliseconds: 250);
    expect(reconnectBackoff(initial, max, 1, 0, null),
        const Duration(milliseconds: 50));
    expect(reconnectBackoff(initial, max, 2, 1, null),
        const Duration(milliseconds: 200));
    expect(reconnectBackoff(initial, max, 10, 1, null), max);
    expect(reconnectBackoff(initial, max, 10, 0, null),
        const Duration(milliseconds: 125));
    expect(
        reconnectBackoff(initial, max, 10, 0, const Duration(seconds: 2)), max);
    expect(reconnectBackoff(Duration.zero, max, 2000, 1, null), Duration.zero);
  });

  test('defaults to five attempts and resets the ceiling on progress',
      () async {
    final tracker =
        ReconnectTracker(const ReconnectOptions(initialDelay: Duration.zero));
    expect(tracker.maxAttempts, 5);
    for (var i = 0; i < 5; i++) {
      await tracker.waitBeforeReconnect(false);
    }
    await expectLater(tracker.waitBeforeReconnect(false),
        throwsA(isA<StreamReconnectLimitError>()));
    await tracker.waitBeforeReconnect(true);
    await tracker.waitBeforeReconnect(false);
  });

  test('rejects invalid backoff options', () {
    for (final options in [
      const ReconnectOptions(initialDelay: Duration(microseconds: -1)),
      const ReconnectOptions(maxDelay: Duration(microseconds: -1)),
      const ReconnectOptions(budget: Duration.zero),
      const ReconnectOptions(maxAttempts: -1),
    ]) {
      expect(() => ReconnectTracker(options), throwsArgumentError);
    }
  });

  test('budget changes the default attempt ceiling', () async {
    final tracker = ReconnectTracker(const ReconnectOptions(
      initialDelay: Duration.zero,
      budget: Duration(seconds: 1),
    ));
    expect(tracker.maxAttempts, isNull);
    for (var i = 0; i < 8; i++) {
      await tracker.waitBeforeReconnect(false);
    }
    await tracker.waitBeforeReconnect(true);
    await tracker.waitBeforeReconnect(false);
  });

  test('progress resets an exhausted budget', () async {
    final tracker = ReconnectTracker(const ReconnectOptions(
      initialDelay: Duration.zero,
      maxDelay: Duration(milliseconds: 10),
      budget: Duration(microseconds: 1),
    ));
    const retryAfter = Duration(milliseconds: 10);
    await expectLater(tracker.waitBeforeReconnect(false, null, retryAfter),
        throwsA(isA<StreamReconnectLimitError>()));
    await tracker.waitBeforeReconnect(true, null, retryAfter);
    await expectLater(tracker.waitBeforeReconnect(false, null, retryAfter),
        throwsA(isA<StreamReconnectLimitError>()));
  });

  test('a zero-delay reconnect loop still expires its budget', () async {
    final tracker = ReconnectTracker(const ReconnectOptions(
      initialDelay: Duration.zero,
      budget: Duration(microseconds: 1),
    ));
    var expired = false;
    for (var i = 0; i < 2000; i++) {
      try {
        await tracker.waitBeforeReconnect(false);
      } on StreamReconnectLimitError {
        expired = true;
        break;
      }
    }
    expect(expired, isTrue);
  });
}
