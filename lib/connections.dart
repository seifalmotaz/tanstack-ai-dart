/// Connection adapters for the TanStack AI 0.40 wire protocol.
///
/// This is a Dart port of `@tanstack/ai-client`'s `connection-adapters.ts`.
/// It is intentionally separate from the legacy transport barrel so existing
/// `tanstack_ai_dart.dart` consumers keep their current API.
library;

export 'src/connections/cancellation.dart';
export 'src/connections/connection_adapter.dart';
export 'src/connections/errors.dart';
export 'src/connections/fetch_connections.dart';
export 'src/connections/http_common.dart';
export 'src/connections/hydration.dart';
export 'src/connections/json_connection.dart';
export 'src/connections/reconnect.dart';
export 'src/connections/response_stream.dart';
export 'src/connections/resumable_stream.dart';
export 'src/connections/sse_utils.dart';
export 'src/connections/stream_connections.dart';
export 'src/connections/types.dart';
export 'src/connections/web_socket.dart';
export 'src/connections/web_socket_connection.dart';
export 'src/connections/wire.dart';
export 'src/connections/xhr_connections.dart';
