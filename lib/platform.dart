/// Standalone platform-library barrel for the pure-Dart port of the TanStack
/// AI client 0.40.0 platform surfaces.
///
/// Native/browser-only capabilities are injected through the `*Platform`
/// interfaces in each module. Passkey keyring cryptography has a real Dart
/// implementation by default; the WebAuthn ceremony and record store are
/// host-supplied. Other absent platform implementations are explicitly
/// unavailable rather than silently emulated.
library;

export 'src/platform/audio_recorder.dart';
export 'src/platform/byok/byok.dart';
export 'src/platform/client_persistor.dart';
export 'src/platform/events.dart';
export 'src/platform/interrupt_schema.dart';
export 'src/platform/mcp_app_bridge.dart';
export 'src/platform/message_date_normalizer.dart';
export 'src/platform/persistence_types.dart';
export 'src/platform/realtime_client.dart';
export 'src/platform/realtime_types.dart';
export 'src/platform/snapshot_atom.dart';
export 'src/platform/storage_adapters.dart';
export 'src/platform/tool_types.dart';
export 'src/platform/web_mcp_tools.dart';
