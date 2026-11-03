import 'dart:convert';

import 'package:http/http.dart' as http;

import 'cancellation.dart';
import 'errors.dart';
import 'http_common.dart';
import 'response_stream.dart';
import 'types.dart';
import 'wire.dart';

/// Strip the `data:` field prefix and one optional leading space.
///
/// Lines without the prefix are treated as bare JSON, matching the upstream
/// parser used by the SSE connection adapters.
String parseSseDataLine(String line) {
  if (!line.startsWith('data:')) return line;
  final data = line.substring(5);
  return data.startsWith(' ') ? data.substring(1) : data;
}

/// Parse a response body as Server-Sent Events into stream chunks.
///
/// This is the generation-friendly variant (same as upstream `sse-parser.ts`):
/// malformed JSON and the legacy `[DONE]` marker are skipped instead of
/// failing the stream. The connection adapters use the stricter event parser
/// in `resumable_stream.dart`, which reports malformed JSON and synthesizes a
/// terminal for `[DONE]`.
Stream<StreamChunk> parseSseResponse(
  http.StreamedResponse response, {
  CancellationSignal? signal,
  void Function(String message)? onWarning,
}) async* {
  await assertResponseOk(response);
  try {
    await for (final line in readResponseLines(
      response.stream,
      signal: signal,
    )) {
      final data = parseSseDataLine(line);
      if (data == '[DONE]') {
        onWarning?.call(
          'Received [DONE] sentinel. This is deprecated — RUN_FINISHED is the '
          'stream terminator.',
        );
        continue;
      }
      try {
        final decoded = jsonDecode(data);
        if (decoded is Map) {
          yield restoreInboundChunk(
            decoded.map((key, value) => MapEntry('$key', value)),
          );
        } else {
          onWarning?.call('Failed to parse SSE chunk: $data');
        }
      } catch (_) {
        onWarning?.call('Failed to parse SSE chunk: $data');
      }
    }
  } catch (error) {
    // The generation parser preserves reader errors; the connection adapters
    // are the layer that wraps them as StreamReadError for resume decisions.
    if (error is StreamReadError) throw error.cause;
    rethrow;
  }
}
