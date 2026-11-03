import 'dart:math' as math;

import 'cancellation.dart';
import 'errors.dart';
import 'types.dart';

/// Result of recording an incoming delivery offset.
enum ReconnectNote { fresh, duplicate, reset }

bool isTemporaryStatusError(Object error) {
  final status = switch (error) {
    HttpStatusException(:final status) => status,
    XhrStatusException(:final status) => status,
    _ => null,
  };
  return const {408, 429, 502, 503, 504}.contains(status);
}

Duration? retryAfterForError(Object error) => switch (error) {
      HttpStatusException(:final retryAfter) => retryAfter,
      XhrStatusException(:final retryAfter) => retryAfter,
      _ => null,
    };

Duration reconnectBackoff(Duration initial, Duration maximum, int attempts,
    double random, Duration? retryAfter) {
  final backoff = initial.inMicroseconds == 0
      ? 0
      : math.min(maximum.inMicroseconds.toDouble(),
          initial.inMicroseconds * math.pow(2, math.max(0, attempts - 1)));
  final micros = retryAfter == null
      ? (backoff * (0.5 + random / 2)).round()
      : math.min(retryAfter.inMicroseconds, maximum.inMicroseconds);
  return Duration(microseconds: micros);
}

/// Reconnect bookkeeping shared by every resumable-stream driver.
///
/// De-dupes offsets, tracks the last acknowledged offset, honors the SSE
/// empty-id reset convention, and bounds consecutive no-progress reconnects.
class ReconnectTracker {
  final int? maxAttempts;
  final Duration initialDelay;
  final Duration maxDelay;
  final Duration? budget;
  final Set<String> _seen = <String>{};
  String? _lastEventId;
  int _reconnectAttempts = 0;
  DateTime? _failingSince;

  ReconnectTracker([ReconnectOptions? options])
      : maxAttempts =
            options?.maxAttempts ?? (options?.budget == null ? 5 : null),
        initialDelay = options?.initialDelay ??
            options?.delay ??
            const Duration(milliseconds: 250),
        maxDelay = options?.maxDelay ??
            Duration(
                microseconds: math.max(
                    5000000,
                    (options?.initialDelay ??
                            options?.delay ??
                            const Duration(milliseconds: 250))
                        .inMicroseconds)),
        budget = options?.budget {
    if (maxAttempts != null && maxAttempts! < 0) {
      throw ArgumentError(
        'Invalid reconnect.maxAttempts: $maxAttempts. '
        'Must be a non-negative integer.',
      );
    }
    if (initialDelay.isNegative || maxDelay.isNegative) {
      throw ArgumentError(
        'Reconnect delays must be non-negative.',
      );
    }
    if (budget != null && budget! <= Duration.zero) {
      throw ArgumentError('Reconnect budget must be positive.');
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
    Duration? retryAfter,
  ]) async {
    if (madeProgress) {
      _reconnectAttempts = 0;
      _failingSince = null;
    } else {
      _reconnectAttempts += 1;
      _failingSince ??= DateTime.now();
      if (maxAttempts != null && _reconnectAttempts > maxAttempts!) {
        throw StreamReconnectLimitError(maxAttempts!);
      }
    }
    final delay = reconnectBackoff(initialDelay, maxDelay, _reconnectAttempts,
        math.Random().nextDouble(), retryAfter);
    if (budget != null &&
        _failingSince != null &&
        DateTime.now().difference(_failingSince!) + delay > budget!) {
      throw StreamReconnectLimitError(_reconnectAttempts - 1, budget: budget);
    }
    await abortableDelay(delay, signal);
  }
}

/// Create a [ReconnectTracker] bound to [options].
ReconnectTracker createReconnectTracker([ReconnectOptions? options]) =>
    ReconnectTracker(options);
