import 'dart:async';
import 'dart:convert';

import 'cancellation.dart';
import 'errors.dart';

/// Require a byte stream from a custom transport.
///
/// Dart's `package:http` always returns a response stream, so the adapters in
/// this package never hit the null case. It exists for callers wrapping their
/// own transport so they can surface the same actionable error JavaScript's
/// `getResponseStreamReader` raises for `Response.body` /
/// `Response.body.getReader`.
Stream<List<int>> requireResponseBody(Stream<List<int>>? body) {
  if (body == null) {
    throw const UnsupportedResponseStreamError(
      UnsupportedResponseStreamError.responseBody,
    );
  }
  return body;
}

/// Read a response body as newline-delimited lines.
///
/// Uses the JavaScript `TextDecoder` replacement mode (`allowMalformed`), so a
/// connection cut mid-UTF-8 character flushes U+FFFD into the trailing buffer
/// and surfaces [StreamTruncatedError] rather than a decoder error. A
/// non-empty trailing buffer at EOF is always truncation. CRLF line endings
/// are normalized away; lone CR is not a separator (matching upstream).
Stream<String> readResponseLines(
  Stream<List<int>>? body, {
  CancellationSignal? signal,
}) async* {
  final bytes = requireResponseBody(body);
  final iterator = StreamIterator<String>(
      bytes.transform(const Utf8Decoder(allowMalformed: true)));
  var buffer = '';
  try {
    while (true) {
      if (signal?.isCancelled ?? false) return;
      final hasNext = signal == null
          ? await iterator.moveNext()
          : await Future.any<bool>([
              iterator.moveNext(),
              signal.whenCancelled.then((_) => false),
            ]);
      if (!hasNext) break;
      if (signal?.isCancelled ?? false) return;
      buffer += iterator.current;
      var newline = buffer.indexOf('\n');
      while (newline != -1) {
        var line = buffer.substring(0, newline);
        buffer = buffer.substring(newline + 1);
        if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
        if (line.trim().isNotEmpty) yield line;
        newline = buffer.indexOf('\n');
      }
    }
  } catch (error) {
    if (signal?.isCancelled ?? false) return;
    if (error is StreamTruncatedError) rethrow;
    throw StreamReadError(error);
  } finally {
    try {
      unawaited(iterator.cancel().catchError((Object _) {}));
    } catch (_) {
      // Preserve the original error if cancellation throws synchronously.
    }
  }
  if (signal?.isCancelled ?? false) return;
  if (buffer.trim().isNotEmpty) throw const StreamTruncatedError();
}
