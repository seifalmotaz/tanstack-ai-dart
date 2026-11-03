import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart' show parseHttpDate;

import '../platform/byok/errors.dart' as byok;
import 'errors.dart';

/// Parse the JSON body of a 401 and return a [ByokMissingError] when it matches
/// `{ error: { type: 'byok_missing', provider, message } }`.
ByokMissingError? byokErrorFromBody(Object? value) {
  if (!byok.isByokMissingBody(value)) return null;
  final error = (value as Map)['error'] as Map;
  return byok.ByokMissingError(error['provider'] as String);
}

/// Throw for a non-2xx response. A 401 whose body is a BYOK-missing payload
/// becomes [ByokMissingError]; everything else becomes a status exception.
Future<void> assertResponseOk(
  http.StreamedResponse response, {
  bool xhr = false,
}) async {
  if (response.statusCode >= 200 && response.statusCode < 300) return;
  if (response.statusCode == 401) {
    final missing = await _readByok(response);
    if (missing != null) throw missing;
  } else {
    try {
      await response.stream.listen(null).cancel();
    } catch (_) {
      // Preserve the HTTP status if transport cleanup fails.
    }
  }
  final reason = response.reasonPhrase ?? '';
  final statusText = reason.isEmpty ? '' : reason;
  final retryAfter = _parseRetryAfter(response.headers['retry-after']);
  throw xhr
      ? XhrStatusException(response.statusCode, statusText,
          retryAfter: retryAfter)
      : HttpStatusException(response.statusCode, statusText,
          retryAfter: retryAfter);
}

Duration? _parseRetryAfter(String? value) {
  if (value == null) return null;
  final seconds = num.tryParse(value);
  if (seconds != null && seconds.isFinite && seconds >= 0) {
    const maxMicros = 0x1fffffffffffff;
    final micros = seconds * Duration.microsecondsPerSecond;
    return Duration(
        microseconds: micros >= maxMicros ? maxMicros : micros.round());
  }
  try {
    final wait = parseHttpDate(value).difference(DateTime.now().toUtc());
    return wait.isNegative ? Duration.zero : wait;
  } on FormatException {
    return null;
  }
}

Future<ByokMissingError?> _readByok(http.StreamedResponse response) async {
  try {
    final body = await response.stream.transform(utf8.decoder).join();
    return byokErrorFromBody(jsonDecode(body));
  } catch (_) {
    return null;
  }
}
