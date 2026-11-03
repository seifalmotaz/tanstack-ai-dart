/// Ported from `packages/ai/src/byok/providers.ts` and
/// `packages/ai/src/byok/define-provider.ts`.
library;

final RegExp byokProviderIdPattern = RegExp(r'^[a-z][a-z0-9-]{0,63}$');
const String byokHeaderPrefix = 'x-byok-';

bool isProviderId(Object? value) =>
    value is String && byokProviderIdPattern.hasMatch(value);

String resolveProviderId(Object provider) =>
    provider is String ? provider : (provider as dynamic).id as String;

String byokHeaderName(String provider) {
  if (!isProviderId(provider)) {
    throw ArgumentError('Invalid BYOK provider id: $provider');
  }
  return '$byokHeaderPrefix$provider';
}

class ByokProvider {
  final String id;
  final String label;
  final List<String>? env;
  final List<ByokProvider>? withProviders;

  const ByokProvider({
    required this.id,
    required this.label,
    this.env,
    this.withProviders,
  });

  List<ByokProvider> get withCompanions => withProviders ?? const [];
}

ByokProvider defineByokProvider({
  required String id,
  required String label,
  Object? env,
  List<ByokProvider>? withProviders,
}) {
  if (!isProviderId(id)) {
    throw ArgumentError('Invalid BYOK provider id: $id');
  }
  final envList = env == null
      ? null
      : env is String
          ? <String>[env]
          : (env as List).cast<String>();
  return ByokProvider(
    id: id,
    label: label,
    env: envList,
    withProviders: withProviders,
  );
}
