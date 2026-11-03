import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'connection_adapter.dart';
import 'cancellation.dart';
import 'errors.dart';
import 'hydration.dart';
import 'http_common.dart';
import 'native_http_client.dart';
import 'response_stream.dart';
import 'resumable_stream.dart';
import 'types.dart';
import 'wire.dart';

/// Produces the request URL for each operation.
///
/// Called once per connect, join, hydrate, or reconnect, so a provider may
/// refresh the URL (and read current app state) dynamically. It may return a
/// [String] or a `Future<String>`.
typedef ConnectionUrlProvider = FutureOr<String> Function();

/// Produces options for each operation.
///
/// Called once per connect, join, hydrate, or reconnect, so a provider may
/// refresh headers or other option values dynamically. It may return [T] or a
/// `Future<T>`.
typedef ConnectionOptionsProvider<T> = FutureOr<T> Function();

Map<String, String> _mergeHeaders(Map<String, String>? headers) =>
    headers == null ? <String, String>{} : {...headers};

/// Create an SSE connection adapter for a static [url].
///
/// [options] is read on every request. For a dynamic URL or options, use
/// [fetchServerSentEventsProvider].
///
/// Resumable: if the server tags events with `id:` offsets, a dropped or
/// rolled-over connection reconnects with `Last-Event-ID` and de-dupes the
/// replayed prefix. Untagged responses behave as a single plain request.
ConnectionAdapter fetchServerSentEvents(
  String url, {
  FetchConnectionOptions options = const FetchConnectionOptions(),
}) =>
    createHttpConnection(url: url, options: options, sse: true);

/// Create an SSE connection adapter with a dynamic URL and options.
///
/// Exact signature:
/// ```dart
/// ConnectionAdapter fetchServerSentEventsProvider({
///   required ConnectionUrlProvider url,
///   ConnectionOptionsProvider<FetchConnectionOptions>? options,
/// });
/// ```
///
/// [url] is required and may be synchronous or asynchronous. [options] is
/// optional; when supplied it may also be synchronous or asynchronous, and is
/// re-read for every request so headers can refresh.
ConnectionAdapter fetchServerSentEventsProvider({
  required ConnectionUrlProvider url,
  ConnectionOptionsProvider<FetchConnectionOptions>? options,
}) =>
    createHttpConnectionProvider(url: url, options: options, sse: true);

/// Create an NDJSON connection adapter for a static [url].
///
/// [options] is read on every request. For a dynamic URL or options, use
/// [fetchHttpStreamProvider].
///
/// Resumable: `{ id, chunk }` envelopes reconnect with `Last-Event-ID`; bare
/// chunks are a single plain request.
ConnectionAdapter fetchHttpStream(
  String url, {
  FetchConnectionOptions options = const FetchConnectionOptions(),
}) =>
    createHttpConnection(url: url, options: options, sse: false);

/// Create an NDJSON connection adapter with a dynamic URL and options.
///
/// Exact signature:
/// ```dart
/// ConnectionAdapter fetchHttpStreamProvider({
///   required ConnectionUrlProvider url,
///   ConnectionOptionsProvider<FetchConnectionOptions>? options,
/// });
/// ```
ConnectionAdapter fetchHttpStreamProvider({
  required ConnectionUrlProvider url,
  ConnectionOptionsProvider<FetchConnectionOptions>? options,
}) =>
    createHttpConnectionProvider(url: url, options: options, sse: false);

/// Shared typed implementation for the static fetch- and XHR-named adapters.
///
/// [options] is typed and named. For a dynamic URL or options, use
/// [createHttpConnectionProvider] (or one of the named provider factories).
ConnectionAdapter createHttpConnection({
  required String url,
  FetchConnectionOptions options = const FetchConnectionOptions(),
  required bool sse,
  bool xhr = false,
}) =>
    createHttpConnectionProvider(
      url: () => url,
      options: () => options,
      sse: sse,
      xhr: xhr,
    );

/// Shared typed implementation for adapters with a dynamic URL and options.
///
/// [url] and [options] are typed providers, called once per operation.
/// [xhr] changes the non-2xx error wording and selects the real browser XHR
/// seam when no client is injected. An injected `http.Client` is always used
/// unchanged.
ConnectionAdapter createHttpConnectionProvider({
  required ConnectionUrlProvider url,
  ConnectionOptionsProvider<FetchConnectionOptions>? options,
  required bool sse,
  bool xhr = false,
}) {
  Future<String> resolveUrl() async => await url();
  Future<FetchConnectionOptions> resolveOptions() async =>
      options == null ? const FetchConnectionOptions() : await options();

  StreamEventSource eventSource({
    required http.Client client,
    required String method,
    required String target,
    required Map<String, String> headers,
    String? body,
    String? fallbackThreadId,
    String? fallbackRunId,
  }) {
    return (extraHeaders, signal) async* {
      final request = http.AbortableRequest(
        method,
        Uri.parse(target),
        abortTrigger: signal?.whenCancelled,
      );
      request.headers.addAll(headers);
      request.headers.addAll(extraHeaders);
      if (method != 'GET') request.body = body ?? '';

      http.StreamedResponse response;
      try {
        response = await client.send(request);
      } catch (error) {
        if (signal?.isCancelled ?? false) return;
        throw StreamReadError(error);
      }
      await assertResponseOk(response, xhr: xhr);
      final lines = readResponseLines(response.stream, signal: signal);
      if (sse) {
        yield* linesToSseEvents(
          lines,
          fallbackThreadId: fallbackThreadId,
          fallbackRunId: fallbackRunId,
        );
      } else {
        yield* linesToNdjsonEvents(lines);
      }
    };
  }

  return ConnectionAdapter.connect(
    connect: (messages, {data, signal, runContext}) =>
        _requestStream((localSignal) async* {
      final target = await resolveUrl();
      final resolved = await resolveOptions();
      final client = resolved.client ??
          createNativeHttpClient(
            credentials: resolved.credentials,
            withCredentials:
                resolved is XhrConnectionOptions && resolved.withCredentials,
            xhr: xhr,
          );
      final activeSignal = localSignal.signal;
      void abort() => localSignal.cancel();
      resolved.signal?.addListener(abort);
      try {
        final headers = <String, String>{
          'Content-Type': 'application/json',
          if (sse) 'Accept': 'text/event-stream',
          ..._mergeHeaders(resolved.headers),
          ..._mergeHeaders(runContext?.headers),
          if (runContext != null) 'X-Run-Id': runContext.runId,
        };
        final body = buildRunAgentInputBody(
          messages,
          data,
          runContext,
          body: resolved.body,
        );
        yield* resumableStream(
          eventSource(
            client: client,
            method: 'POST',
            target: target,
            headers: headers,
            body: jsonEncode(body),
            fallbackThreadId: runContext?.threadId,
            fallbackRunId: runContext?.runId,
          ),
          activeSignal,
          resolved.reconnect,
        );
      } finally {
        resolved.signal?.removeListener(abort);
        if (resolved.client == null) client.close();
      }
    }, signal),
    joinRun: (runId, {signal}) => _requestStream((localSignal) async* {
      final target = await resolveUrl();
      final resolved = await resolveOptions();
      final client = resolved.client ??
          createNativeHttpClient(
            credentials: resolved.credentials,
            withCredentials:
                resolved is XhrConnectionOptions && resolved.withCredentials,
            xhr: xhr,
          );
      final activeSignal = localSignal.signal;
      void abort() => localSignal.cancel();
      resolved.signal?.addListener(abort);
      try {
        final joinUrl = withSearchParams(target, {
          'offset': '-1',
          'runId': runId,
        });
        yield* resumableStream(
          eventSource(
            client: client,
            method: 'GET',
            target: joinUrl,
            headers: _mergeHeaders(resolved.headers),
            fallbackRunId: runId,
          ),
          activeSignal,
          resolved.reconnect,
        );
      } finally {
        resolved.signal?.removeListener(abort);
        if (resolved.client == null) client.close();
      }
    }, signal),
    hydrate: (threadId, {options}) async {
      final target = await resolveUrl();
      final resolved = await resolveOptions();
      final client = resolved.client ??
          createNativeHttpClient(
            credentials: resolved.credentials,
            withCredentials:
                resolved is XhrConnectionOptions && resolved.withCredentials,
            xhr: xhr,
          );
      try {
        return await fetchThreadHydration(
          client,
          target,
          _mergeHeaders(resolved.headers),
          threadId,
          options,
          signal: resolved.signal,
        );
      } finally {
        if (resolved.client == null) client.close();
      }
    },
    hydrateGeneration: (threadId) async {
      final target = await resolveUrl();
      final resolved = await resolveOptions();
      final client = resolved.client ??
          createNativeHttpClient(
            credentials: resolved.credentials,
            withCredentials:
                resolved is XhrConnectionOptions && resolved.withCredentials,
            xhr: xhr,
          );
      try {
        return await fetchGenerationHydration(
          client,
          target,
          _mergeHeaders(resolved.headers),
          threadId,
          signal: resolved.signal,
        );
      } finally {
        if (resolved.client == null) client.close();
      }
    },
  );
}

/// Eagerly abort before awaiting generator cleanup, including on Dart web.
Stream<StreamChunk> _requestStream(
  Stream<StreamChunk> Function(CancellationController cancellation) open,
  CancellationSignal? upstream,
) {
  final cancellation = CancellationController();
  StreamSubscription<StreamChunk>? subscription;
  late StreamController<StreamChunk> controller;
  void abort() => cancellation.cancel();
  Future<void> cancel() async {
    upstream?.removeListener(abort);
    cancellation.cancel();
    final active = subscription;
    subscription = null;
    if (active != null) {
      await Future.any<void>([
        Future<void>.sync(active.cancel).catchError((Object _) {}),
        Future<void>.delayed(Duration.zero),
      ]);
    }
  }

  controller = StreamController<StreamChunk>(
    onListen: () {
      upstream?.addListener(abort);
      if (upstream?.isCancelled ?? false) abort();
      subscription = open(cancellation).listen(
        controller.add,
        onError: controller.addError,
        onDone: () {
          upstream?.removeListener(abort);
          unawaited(controller.close());
        },
      );
    },
    onPause: () => subscription?.pause(),
    onResume: () => subscription?.resume(),
    onCancel: cancel,
  );
  return controller.stream;
}
