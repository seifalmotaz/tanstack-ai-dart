/// Devtools surface for the pure-Dart TanStack AI client 0.40.0 port.
///
/// Faithful port of `packages/ai-client/src/devtools.ts` and
/// `devtools-noop.ts`. Bridges are platform-neutral: an injected event sink
/// carries outgoing events and incoming `devtools:request-state` /
/// `devtools:tool-fixture:apply` messages, while snapshot readers and tool
/// callbacks come from [AIDevtoolsBridgeOptions].
library;

export 'src/devtools/devtools.dart';
export 'src/devtools/generation_client_adapter.dart';
export 'src/devtools/devtools_factories.dart';
export 'src/devtools/devtools_noop.dart';
export 'src/devtools/devtools_types.dart';
