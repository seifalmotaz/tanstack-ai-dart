import 'dart:async';
import 'processing_scheduler_stub.dart'
    if (dart.library.js_interop) 'processing_scheduler_web.dart' as host;

final _clock = Stopwatch()..start();

/// Host scheduling hooks. Browser defaults use scheduler.yield when available.
class StreamProcessingScheduler {
  final num Function() now;
  final bool Function() isHidden;
  final Future<void> Function() yieldToHost;

  StreamProcessingScheduler({
    num Function()? now,
    bool Function()? isHidden,
    Future<void> Function()? yieldToHost,
  })  : now = now ?? (() => _clock.elapsedMicroseconds / 1000),
        isHidden = isHidden ?? host.isHidden,
        yieldToHost = yieldToHost ?? host.yieldToHost;
}

Stream<T> budgetStreamProcessing<T>(
    Stream<T> source, StreamProcessingScheduler scheduler) {
  StreamSubscription<T>? subscription;
  late StreamController<T> controller;
  num processingTime = 0;
  controller = StreamController<T>(
    sync: true,
    onListen: () {
      subscription = source.listen(
        (event) {
          final start = scheduler.now();
          controller.add(event);
          processingTime += scheduler.now() - start;
          if (processingTime < 8) return;
          processingTime = 0;
          if (!scheduler.isHidden()) {
            final yielded = Future<void>.sync(scheduler.yieldToHost)
                .catchError((Object error, StackTrace stack) {
              controller.addError(error, stack);
            });
            subscription?.pause(yielded);
          }
        },
        onError: controller.addError,
        onDone: controller.close,
      );
    },
    onPause: () => subscription?.pause(),
    onResume: () => subscription?.resume(),
    onCancel: () => subscription?.cancel(),
  );
  return controller.stream;
}
