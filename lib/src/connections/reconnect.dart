import 'cancellation.dart';
import 'errors.dart';
import 'types.dart';

/// Result of recording an incoming delivery offset.
enum ReconnectNote { fresh, duplicate, reset }

/// Reconnect bookkeeping shared by every resumable-stream driver.
///
/// De-dupes offsets, tracks the last acknowledged offset, honors the SSE
/// empty-id reset convention, and bounds consecutive no-progress reconnects.
class ReconnectTracker {
  final int maxAttempts;
  final Duration delay;
  final Set<String> _seen = <String>{};
  String? _lastEventId;
  int _reconnectAttempts = 0;

  ReconnectTracker([ReconnectOptions? options])
      : maxAttempts = options?.maxAttempts ?? 5,
        delay = options?.delay ?? const Duration(milliseconds: 250) {
    if (maxAttempts < 0) {
      throw ArgumentError(
        'Invalid reconnect.maxAttempts: $maxAttempts. '
        'Must be a non-negative integer.',
      );
    }
    if (delay.isNegative) {
      throw ArgumentError(
        'Invalid reconnect.delay: $delay. Must be a non-negative duration.',
      );
    }
  }

  /// The most recently accepted (non-duplicate, non-empty) offset, if any.
  String? get lastEventId => _lastEventId;

  /// Record an incoming offset.
  ///
  /// Returns [ReconnectNote.reset] for an empty id (SSE resume-cursor reset),
  /// [ReconnectNote.duplicate] for an already-seen id, and
  /// [ReconnectNote.fresh] otherwise (including `null`, which is untracked).
  ReconnectNote note(String? id) {
    if (id == null) return ReconnectNote.fresh;
    if (id.isEmpty) {
      _lastEventId = null;
      _seen.clear();
      return ReconnectNote.reset;
    }
    if (_seen.contains(id)) return ReconnectNote.duplicate;
    _seen.add(id);
    _lastEventId = id;
    return ReconnectNote.fresh;
  }

  /// Throttle before a reconnect attempt.
  ///
  /// Resets the no-progress counter when [madeProgress] is true; otherwise
  /// increments it and throws [StreamReconnectLimitError] once it exceeds the
  /// configured ceiling.
  Future<void> waitBeforeReconnect(
    bool madeProgress, [
    CancellationSignal? signal,
  ]) async {
    if (madeProgress) {
      _reconnectAttempts = 0;
    } else {
      _reconnectAttempts += 1;
      if (_reconnectAttempts > maxAttempts) {
        throw StreamReconnectLimitError(maxAttempts);
      }
    }
    await abortableDelay(delay, signal);
  }
}

/// Create a [ReconnectTracker] bound to [options].
ReconnectTracker createReconnectTracker([ReconnectOptions? options]) =>
    ReconnectTracker(options);
