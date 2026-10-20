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

/// Resolve a static URL or a (possibly async) URL provider.
Future<String> resolveConnectionUrl(Object source) async {
  if (source is String) return source;
  if (source is FutureOr<String> Function()) return await source();
  throw ArgumentError('URL must be a String or a function returning a String');
}

/// Resolve static fetch options or a (possibly async) options provider.
Future<FetchConnectionOptions> resolveFetchOptions(Object? source) async {
  if (source == null) return const FetchConnectionOptions();
  if (source is FetchConnectionOptions) return source;
  if (source is FutureOr<FetchConnectionOptions> Function()) {
    return await source();
  }
  throw ArgumentError(
    'Options must be FetchConnectionOptions or a function returning them',
  );
}

Map<String, String> _mergeHeaders(Map<String, String>? headers) =>
    headers == null ? <String, String>{} : {...headers};

/// Create an SSE connection adapter.
///
/// Resumable: if the server tags events with `id:` offsets, a dropped or
/// rolled-over connection reconnects with `Last-Event-ID` and de-dupes the
/// replayed prefix. Untagged responses behave as a single plain request.
ConnectionAdapter fetchServerSentEvents(Object url, [Object? options]) =>
    createHttpConnection(url: url, options: options, sse: true);

/// Create an NDJSON connection adapter.
///
/// Resumable: `{ id, chunk }` envelopes reconnect with `Last-Event-ID`; bare
/// chunks are a single plain request.
ConnectionAdapter fetchHttpStream(Object url, [Object? options]) =>
    createHttpConnection(url: url, options: options, sse: false);

/// Shared implementation for the fetch- and XHR-named adapters.
///
/// [xhr] changes the non-2xx error wording and selects the real browser XHR
/// seam when no client is injected. An injected `http.Client` is always used
/// unchanged.
ConnectionAdapter createHttpConnection({
  required Object url,
  required Object? options,
  required bool sse,
  bool xhr = false,
}) {
  Future<String> resolveUrl() => resolveConnectionUrl(url);
  Future<FetchConnectionOptions> resolveOptions() =>
      resolveFetchOptions(options);

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

  return ConnectionAdapter(
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
