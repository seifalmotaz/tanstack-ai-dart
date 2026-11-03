import 'dart:async';

/// A state stream with an initial value per listener and independent buffering.
/// Kept internal so clients do not depend on a particular state library.
final class SnapshotStream<T> {
  SnapshotStream(this._current);

  final T Function() _current;
  final _listeners = <MultiStreamController<T>>{};
  bool _closed = false;

  bool get hasListener => _listeners.isNotEmpty;

  late final Stream<T> stream = Stream<T>.multi((listener) {
    if (_closed) {
      listener.close();
      return;
    }
    _listeners.add(listener);
    listener.onCancel = () => _listeners.remove(listener);
    listener.add(_current());
  }, isBroadcast: true);

  void emit(T value) {
    if (_closed) return;
    for (final listener in _listeners.toList()) {
      listener.add(value);
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    for (final listener in _listeners.toList()) {
      listener.close();
    }
    _listeners.clear();
  }
}
