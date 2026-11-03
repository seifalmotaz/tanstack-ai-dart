/// Ported from `packages/ai/src/byok/errors.ts`.
library;

class ByokMissingError implements Exception {
  final String provider;

  ByokMissingError(this.provider);

  String get message => 'Missing $provider API key';

  @override
  String toString() => 'ByokMissingError: $message';
}

class ByokBlockedError implements Exception {
  final String provider;
  final String reason;

  ByokBlockedError(this.provider, this.reason);

  String get message => reason == 'locked'
      ? '$provider key is locked'
      : 'Missing $provider API key';

  @override
  String toString() => 'ByokBlockedError: $message';
}

class ByokUnresolvedProviderError implements Exception {
  static const String message =
      'BYOK is enabled but no provider slug was resolved. Pass byokProvider '
      'or forwardedProps.provider.';

  @override
  String toString() => 'ByokUnresolvedProviderError: $message';
}

String maskKey(String key) {
  if (key.length <= 4) return '••';
  return key.substring(key.length - 4);
}

String scrubSecrets(String input, List<String> secrets) {
  var next = input;
  for (final secret in secrets) {
    if (secret.isEmpty) continue;
    next = next.split(secret).join('[redacted]');
  }
  return next;
}

bool isByokMissingBody(Object? value) {
  if (value is! Map) return false;
  final error = value['error'];
  if (error is! Map || error['type'] != 'byok_missing') return false;
  return isProviderIdLike(error['provider']) && error['message'] is String;
}

bool isProviderIdLike(Object? value) =>
    value is String && RegExp(r'^[a-z][a-z0-9-]{0,63}$').hasMatch(value);

Map<String, dynamic> byokMissing(String provider) {
  if (!isProviderIdLike(provider)) {
    throw ArgumentError('Invalid BYOK provider id: $provider');
  }
  return {
    'error': {
      'type': 'byok_missing',
      'provider': provider,
      'message': 'Missing $provider API key',
    },
  };
}
