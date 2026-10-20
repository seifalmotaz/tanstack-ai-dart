import 'package:http/http.dart' as http;

import 'cancellation.dart';

/// One AG-UI / TanStack stream chunk. Kept as a JSON map so new event types do
/// not require a package release.
typedef StreamChunk = Map<String, dynamic>;

/// One AG-UI wire message (`{ id?, role, parts | content, ... }`).
typedef WireMessage = Map<String, dynamic>;

/// A client-declared tool advertised in the RunAgentInput payload.
class ClientToolDeclaration {
  final String name;
  final String description;
  final Object? parameters;

  const ClientToolDeclaration({
    required this.name,
    required this.description,
    this.parameters,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'description': description,
        'parameters': parameters,
      };
}

/// Per-send context supplied to a connection adapter.
class RunAgentInputContext {
  final String threadId;
  final String runId;
  final String? parentRunId;

  /// AG-UI interrupt resume entries returned to the server on a follow-up run.
  final List<Map<String, dynamic>>? resume;

  /// Client-declared tools to advertise in the request payload.
  final List<ClientToolDeclaration>? clientTools;

  /// Arbitrary user-controlled passthrough data.
  final Map<String, dynamic>? forwardedProps;

  /// Extra request headers for this run (e.g. BYOK keys). POST only.
  final Map<String, String>? headers;

  const RunAgentInputContext({
    required this.threadId,
    required this.runId,
    this.parentRunId,
    this.resume,
    this.clientTools,
    this.forwardedProps,
    this.headers,
  });
}

/// Bounding for resumable-stream reconnection.
class ReconnectOptions {
  /// Ceiling on CONSECUTIVE reconnects that deliver no new events.
  final int maxAttempts;

  /// Delay between reconnect attempts.
  final Duration delay;

  const ReconnectOptions({
    this.maxAttempts = 5,
    this.delay = const Duration(milliseconds: 250),
  });
}

/// Options for HTTP/fetch-backed connection adapters.
class FetchConnectionOptions {
  final Map<String, String>? headers;

  /// A signal that applies to every request made by this adapter.
  final CancellationSignal? signal;

  /// Static base payload merged into `forwardedProps` / legacy `data`.
  final Map<String, dynamic>? body;

  /// Injectable HTTP client. Tests and custom runtimes can supply one.
  final http.Client? client;

  /// Browser cookie mode: `omit`, `same-origin` (default), or `include`.
  ///
  /// On web, non-default values use the package:web XHR seam because
  /// package:http 1.6's BrowserClient is fetch-backed and does not expose
  /// `credentials`. Native runtimes delegate cookies to their HTTP stack.
  final String? credentials;

  /// Bounding for resumable reconnection.
  final ReconnectOptions? reconnect;

  const FetchConnectionOptions({
    this.headers,
    this.signal,
    this.body,
    this.client,
    this.credentials,
    this.reconnect,
  });
}

/// Options for the XHR-named adapters.
///
/// Dart has no browser `XMLHttpRequest` on every platform. When a client is
/// injected, these adapters use it unchanged. Otherwise, on the web they use a
/// real package:web XHR seam (with `withCredentials` and abort support); on the
/// VM they use the IO client. Note that package:http 1.6's BrowserClient is
/// fetch-backed, not XHR-backed.
class XhrConnectionOptions extends FetchConnectionOptions {
  /// Kept for API parity. Dart's `http` client has no per-request
  /// `withCredentials` switch.
  final bool withCredentials;

  const XhrConnectionOptions({
    super.headers,
    super.signal,
    super.body,
    super.client,
    super.credentials,
    super.reconnect,
    this.withCredentials = false,
  });
}
