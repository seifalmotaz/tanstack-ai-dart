export '../platform/byok/errors.dart'
    show ByokMissingError, isByokMissingBody, isProviderIdLike, byokMissing;

/// Thrown when an SSE/NDJSON response ends with a non-empty unterminated
/// buffer: the connection was cut mid-line (server crash, dropped TCP, proxy
/// timeout), so the partial content cannot be safely parsed.
class StreamTruncatedError implements Exception {
  const StreamTruncatedError();

  @override
  String toString() =>
      'Stream ended with unterminated trailing data — connection was likely cut short.';
}

/// Wraps a transport read failure. A durable (id-tagged) run retries these;
/// a non-durable run surfaces them unchanged.
class StreamReadError implements Exception {
  final Object cause;

  const StreamReadError(this.cause);

  @override
  String toString() => 'Stream response body read failed: $cause';
}

/// A durable run's stream ended without a terminal event and a reconnect made
/// no forward progress, so the run cannot complete.
class DurableStreamIncompleteError implements Exception {
  const DurableStreamIncompleteError();

  @override
  String toString() =>
      'Durable run ended without a terminal event and could not resume — the run did not complete.';
}

/// A durable run exceeded its consecutive no-progress reconnect ceiling.
class StreamReconnectLimitError implements Exception {
  final int attempts;
  final Duration? budget;

  const StreamReconnectLimitError(this.attempts, {this.budget});

  @override
  String toString() => budget == null
      ? 'Durable run exceeded its reconnect ceiling of $attempts attempts — giving up.'
      : 'Durable run did not reconnect within its budget of ${budget!.inMilliseconds} ms ($attempts attempts) — giving up.';
}

/// A non-2xx streaming response. [message] preserves the upstream wording:
/// `HTTP error! status: 500 Internal Server Error`.
class HttpStatusException implements Exception {
  final int status;
  final String statusText;
  final String message;
  final Duration? retryAfter;

  const HttpStatusException(this.status, this.statusText, {this.retryAfter})
      : message = 'HTTP error! status: $status $statusText';

  @override
  String toString() => message;
}

/// A non-2xx response from an XHR-equivalent transport.
class XhrStatusException implements Exception {
  final int status;
  final String statusText;
  final String message;
  final Duration? retryAfter;

  const XhrStatusException(this.status, this.statusText, {this.retryAfter})
      : message = 'XHR error! status: $status $statusText';

  @override
  String toString() => message;
}

/// A malformed `fetchJson` reply (non-JSON body or wrong shape).
class FetchJsonException implements Exception {
  final String message;

  const FetchJsonException(this.message);

  @override
  String toString() => message;
}

/// The optional response-stream feature that is unavailable.
///
/// Dart's `http` package always exposes a response byte stream, so the two
/// JavaScript-only cases (`Response.body`, `Response.body.getReader`) do not
/// occur on this runtime. They exist here so callers that wrap a custom
/// transport can express the same failure.
class UnsupportedResponseStreamError implements Exception {
  static const String responseBody = 'Response.body';
  static const String responseBodyGetReader = 'Response.body.getReader';
  static const String textDecoder = 'TextDecoder';

  final String missingFeature;

  const UnsupportedResponseStreamError(this.missingFeature);

  @override
  String toString() =>
      'Streaming responses are not supported in this runtime because '
      '$missingFeature is unavailable. Supply a transport that can deliver '
      'streaming chunks.';
}
