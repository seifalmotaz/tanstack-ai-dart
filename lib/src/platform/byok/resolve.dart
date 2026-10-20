import 'dart:async';

import 'client.dart';
import 'errors.dart';
import 'providers.dart';

/// Ported from `packages/ai-client/src/byok/resolve.ts`.

String? resolveByokProviderId(
  FutureOr<String?> Function()? byokProvider,
  List<Object?> candidates,
) {
  final fromFn = byokProvider?.call();
  if (fromFn is Future) return null;
  if (isProviderId(fromFn)) return fromFn as String;
  for (final candidate in candidates) {
    if (isProviderId(candidate)) return candidate as String;
  }
  return null;
}

/// Prepare and stamp headers for one resolved slug. Throws instead of attaching
/// every stored key when the slug is missing.
Future<Map<String, String>> prepareResolvedByokHeaders(
  ByokClient byok,
  String? provider,
) async {
  if (provider == null) throw ByokUnresolvedProviderError();
  await byok.prepare(provider);
  return byok.headers(provider);
}
