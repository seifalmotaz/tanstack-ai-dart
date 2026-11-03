/// Factories that pick the real or no-op devtools bridge.
///
/// Ported from the bottom of `packages/ai-client/src/devtools.ts`. Upstream
/// keys off `NODE_ENV`; Dart hosts can force the choice with [production] for
/// tests or embedders.
library;

import 'devtools.dart';
import 'devtools_noop.dart';
import 'devtools_types.dart';

bool isAIDevtoolsProduction() {
  const nodeEnv = String.fromEnvironment('NODE_ENV');
  if (nodeEnv.isNotEmpty) return nodeEnv == 'production';
  if (const bool.fromEnvironment('dart.vm.product')) return true;
  return false;
}

ChatDevtoolsBridge createChatDevtoolsBridge(
  ChatDevtoolsBridgeOptions options, {
  bool? production,
}) {
  if (production ?? isAIDevtoolsProduction()) {
    return createNoOpChatDevtoolsBridge(options);
  }
  return ChatDevtoolsBridge(options);
}

GenerationDevtoolsBridge<TOutput> createGenerationDevtoolsBridge<TOutput>(
  GenerationDevtoolsBridgeOptions<TOutput> options, {
  bool? production,
}) {
  if (production ?? isAIDevtoolsProduction()) {
    return createNoOpGenerationDevtoolsBridge<TOutput>(options);
  }
  return GenerationDevtoolsBridge<TOutput>(options);
}

VideoDevtoolsBridge<TOutput> createVideoDevtoolsBridge<TOutput>(
  VideoDevtoolsBridgeOptions<TOutput> options, {
  bool? production,
}) {
  if (production ?? isAIDevtoolsProduction()) {
    return createNoOpVideoDevtoolsBridge<TOutput>(options);
  }
  return VideoDevtoolsBridge<TOutput>(options);
}
