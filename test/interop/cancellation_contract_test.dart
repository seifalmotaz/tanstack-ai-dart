import 'package:tanstack_ai_dart/src/cancellation.dart';
import 'package:test/test.dart';

void main() {
  test('shared cancellation notifies tools and transport once', () async {
    final controller = CancellationController();
    var transportClosed = 0;
    var toolClosed = 0;
    controller.signal.addListener(() => transportClosed++);
    controller.signal.onAbort(() => toolClosed++);
    controller.cancel('stopped');
    controller.cancel('again');
    await controller.signal.whenCancelled;
    await controller.signal.whenAborted;
    expect(controller.signal.isCancelled, isTrue);
    expect(controller.signal.isAborted, isTrue);
    expect(controller.signal.reason, 'stopped');
    expect(transportClosed, 1);
    expect(toolClosed, 1);
  });
  test('a failing host cleanup does not strand other resources', () {
    final signal = CancellationSignal();
    var closed = false;
    signal.addListener(() => throw StateError('host cleanup'));
    signal.addListener(() => closed = true);
    signal.abort();
    expect(closed, isTrue);
  });
  test('removed and late subscribers follow their contract', () async {
    final signal = CancellationSignal();
    var calls = 0;
    final unsubscribe = signal.onAbort(() => calls++);
    unsubscribe();
    signal.abort();
    signal.onAbort(() => calls++);
    expect(calls, 1);
    signal.addListener(() => calls++);
    expect(calls, 1);
    await Future<void>.delayed(Duration.zero);
    expect(calls, 2);
  });
  test('cancellation interrupts reconnect throttling promptly', () async {
    final controller = CancellationController();
    final waiting = abortableDelay(const Duration(days: 1), controller.signal);
    controller.cancel();
    await waiting.timeout(const Duration(seconds: 1));
  });
}
