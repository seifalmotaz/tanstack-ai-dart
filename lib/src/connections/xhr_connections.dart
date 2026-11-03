import 'connection_adapter.dart';
import 'fetch_connections.dart';
import 'types.dart';

/// XHR-named SSE adapter for a static [url].
///
/// [options] is read on every request. For a dynamic URL or options, use
/// [xhrServerSentEventsProvider].
///
/// Platform distinction: when a client is injected it is used unchanged. With
/// no injected client, the web build uses a real package:web XMLHttpRequest
/// seam (progress, abort, `withCredentials`); the VM uses an IO socket. Note
/// that package:http 1.6's BrowserClient is fetch-backed, not XHR-backed.
ConnectionAdapter xhrServerSentEvents(
  String url, {
  XhrConnectionOptions options = const XhrConnectionOptions(),
}) =>
    createHttpConnection(
      url: url,
      options: options,
      sse: true,
      xhr: true,
    );

/// XHR-named SSE adapter with a dynamic URL and options.
///
/// Exact signature:
/// ```dart
/// ConnectionAdapter xhrServerSentEventsProvider({
///   required ConnectionUrlProvider url,
///   ConnectionOptionsProvider<XhrConnectionOptions>? options,
/// });
/// ```
ConnectionAdapter xhrServerSentEventsProvider({
  required ConnectionUrlProvider url,
  ConnectionOptionsProvider<XhrConnectionOptions>? options,
}) =>
    createHttpConnectionProvider(
      url: url,
      options: options,
      sse: true,
      xhr: true,
    );

/// XHR-named NDJSON adapter for a static [url].
///
/// See [xhrServerSentEvents] for the platform note and the provider variant
/// [xhrHttpStreamProvider].
ConnectionAdapter xhrHttpStream(
  String url, {
  XhrConnectionOptions options = const XhrConnectionOptions(),
}) =>
    createHttpConnection(
      url: url,
      options: options,
      sse: false,
      xhr: true,
    );

/// XHR-named NDJSON adapter with a dynamic URL and options.
///
/// Exact signature:
/// ```dart
/// ConnectionAdapter xhrHttpStreamProvider({
///   required ConnectionUrlProvider url,
///   ConnectionOptionsProvider<XhrConnectionOptions>? options,
/// });
/// ```
ConnectionAdapter xhrHttpStreamProvider({
  required ConnectionUrlProvider url,
  ConnectionOptionsProvider<XhrConnectionOptions>? options,
}) =>
    createHttpConnectionProvider(
      url: url,
      options: options,
      sse: false,
      xhr: true,
    );

/// Convenience default options for the XHR-named adapters.
const XhrConnectionOptions defaultXhrOptions = XhrConnectionOptions();
