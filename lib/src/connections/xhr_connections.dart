import 'connection_adapter.dart';
import 'fetch_connections.dart';
import 'types.dart';

/// XHR-named SSE adapter.
///
/// Platform distinction: when a client is injected it is used unchanged. With
/// no injected client, the web build uses a real package:web XMLHttpRequest
/// seam (progress, abort, `withCredentials`); the VM uses an IO socket. Note
/// that package:http 1.6's BrowserClient is fetch-backed, not XHR-backed.
ConnectionAdapter xhrServerSentEvents(
  Object url, [
  Object? options,
]) =>
    createHttpConnection(url: url, options: options, sse: true, xhr: true);

/// XHR-named NDJSON adapter. See [xhrServerSentEvents] for the platform note.
ConnectionAdapter xhrHttpStream(
  Object url, [
  Object? options,
]) =>
    createHttpConnection(url: url, options: options, sse: false, xhr: true);

/// Convenience default options for the XHR-named adapters.
const XhrConnectionOptions defaultXhrOptions = XhrConnectionOptions();
