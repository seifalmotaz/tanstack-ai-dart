import 'dart:convert';

import 'package:http/http.dart' as http;

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
  }
  final reason = response.reasonPhrase ?? '';
  final statusText = reason.isEmpty ? '' : reason;
  throw xhr
      ? XhrStatusException(response.statusCode, statusText)
      : HttpStatusException(response.statusCode, statusText);
}

Future<ByokMissingError?> _readByok(http.StreamedResponse response) async {
  try {
    final body = await response.stream.transform(utf8.decoder).join();
    return byokErrorFromBody(jsonDecode(body));
  } catch (_) {
    return null;
  }
}
