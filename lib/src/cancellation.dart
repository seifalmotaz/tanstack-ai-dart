import 'dart:async';

/// Shared cancellation contract for transports, tools, media and generations.
class CancellationSignal {
  bool _aborted = false;
  Object? _reason;
  final _listeners = <void Function()>{};
  final _completion = Completer<void>();

  bool get isAborted => _aborted;
  bool get isCancelled => _aborted;
  Object? get reason => _reason;
  Future<void> get whenAborted => _completion.future;
  Future<void> get whenCancelled => _completion.future;

  void abort([Object? reason]) {
    if (_aborted) return;
    _aborted = true;
    _reason = reason;
    final listeners = List<void Function()>.of(_listeners);
    _listeners.clear();
    _completion.complete();
    for (final listener in listeners) {
      try {
        listener();
      } catch (_) {
        // One host callback must not prevent other resources from closing.
      }
    }
  }

  void addListener(void Function() listener) {
    if (_aborted) {
      scheduleMicrotask(listener);
    } else {
      _listeners.add(listener);
    }
  }

  void removeListener(void Function() listener) => _listeners.remove(listener);

  /// Subscribes to abort; a late subscriber is called immediately.
  void Function() onAbort(void Function() listener) {
    if (_aborted) {
      listener();
      return () {};
    }
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }
}

class CancellationController {
  final signal = CancellationSignal();
  void cancel([Object? reason]) => signal.abort(reason);
}

Future<void> abortableDelay(Duration delay, [CancellationSignal? signal]) {
  if (delay <= Duration.zero || (signal?.isCancelled ?? false)) {
    return Future<void>.value();
  }
  final completion = Completer<void>();
  late Timer timer;
  void finish() {
    timer.cancel();
    signal?.removeListener(finish);
    if (!completion.isCompleted) completion.complete();
  }

  timer = Timer(delay, finish);
  signal?.addListener(finish);
  return completion.future;
}
