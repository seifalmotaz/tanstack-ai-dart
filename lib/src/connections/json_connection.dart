import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'cancellation.dart';
import 'connection_adapter.dart';
import 'errors.dart';
import 'fetch_connections.dart';
import 'hydration.dart';
import 'http_common.dart';
import 'native_http_client.dart';
import 'reconnect.dart';
import 'types.dart';
import 'wire.dart';

/// Options for [fetchJson].
class FetchJsonOptions extends FetchConnectionOptions {
  /// Delay between follow-up requests while the server says `done: false`.
  final Duration pollInterval;

  const FetchJsonOptions({
    super.headers,
    super.signal,
    super.body,
    super.client,
    super.credentials,
    super.reconnect,
    this.pollInterval = const Duration(milliseconds: 250),
  });
}

class _JsonRunBody {
  final List<StreamChunk> chunks;
  final String? offset;
  final bool done;

  const _JsonRunBody(this.chunks, this.offset, this.done);
}

Future<FetchJsonOptions> _resolveJsonOptions(Object? source) async {
  if (source == null) return const FetchJsonOptions();
  if (source is FetchJsonOptions) return source;
  if (source is FetchConnectionOptions) {
    return FetchJsonOptions(
      headers: source.headers,
      signal: source.signal,
      body: source.body,
      client: source.client,
      credentials: source.credentials,
      reconnect: source.reconnect,
    );
  }
  if (source is FutureOr<FetchJsonOptions> Function()) return await source();
  throw ArgumentError(
    'Options must be FetchJsonOptions or a function returning them',
  );
}

class _JsonPollOptions {
  final http.Client client;
  final String url;
  final String runId;
  final CancellationSignal? signal;
  final Duration pollInterval;
  final ReconnectOptions? reconnect;

  const _JsonPollOptions({
    required this.client,
    required this.url,
    required this.runId,
    required this.signal,
    required this.pollInterval,
    required this.reconnect,
  });
}

/// Create a connection adapter for a server that replies with one JSON body
/// per request (`{ chunks, offset?, done }`) instead of a stream.
///
/// While `done` is false the adapter waits [FetchJsonOptions.pollInterval] and
/// asks for the rest with `GET url?runId=<id>&offset=<offset>`. A failed
/// follow-up GET is retried with the `reconnect` bounds; a failed first POST is
/// not retried.
ConnectionAdapter fetchJson(Object url, [Object? options]) {
  Future<String> resolveUrl() => resolveConnectionUrl(url);
  Future<FetchJsonOptions> resolveOptions() => _resolveJsonOptions(options);

  return ConnectionAdapter(
    connect: (messages, {data, signal, runContext}) async* {
      final target = await resolveUrl();
      final resolved = await resolveOptions();
      final client = resolved.client ??
          createNativeHttpClient(credentials: resolved.credentials);
      final requestBody = buildRunAgentInputBody(
        messages,
        data,
        runContext,
        body: resolved.body,
      );
      final runId = requestBody['runId'] as String;
      final active = _JsonPollOptions(
        client: client,
        url: target,
        runId: runId,
        signal: signal ?? resolved.signal,
        pollInterval: resolved.pollInterval,
        reconnect: resolved.reconnect,
      );
      final postRequest = http.AbortableRequest(
        'POST',
        Uri.parse(target),
        abortTrigger: active.signal?.whenCancelled,
      )
        ..headers.addAll({
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          ...?resolved.headers,
          ...?runContext?.headers,
          if (runContext != null) 'X-Run-Id': runContext.runId,
        })
        ..body = jsonEncode(requestBody);
      try {
        yield* _pollJsonRun(
          active,
          () => _requestJsonRunBody(client, postRequest, active.signal),
        );
      } finally {
        if (resolved.client == null) client.close();
      }
    },
    joinRun: (runId, {signal}) async* {
      final target = await resolveUrl();
      final resolved = await resolveOptions();
      final client = resolved.client ??
          createNativeHttpClient(credentials: resolved.credentials);
      final active = _JsonPollOptions(
        client: client,
        url: target,
        runId: runId,
        signal: signal ?? resolved.signal,
        pollInterval: resolved.pollInterval,
        reconnect: resolved.reconnect,
      );
      try {
        yield* _pollJsonRun(
          active,
          () => _getJsonRunBody(active, '-1'),
        );
      } finally {
        if (resolved.client == null) client.close();
      }
    },
    hydrate: (threadId, {options}) async {
      final target = await resolveUrl();
      final resolved = await resolveOptions();
      final client = resolved.client ??
          createNativeHttpClient(credentials: resolved.credentials);
      try {
        return await fetchThreadHydration(
          client,
          target,
          resolved.headers ?? const <String, String>{},
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
          createNativeHttpClient(credentials: resolved.credentials);
      try {
        return await fetchGenerationHydration(
          client,
          target,
          resolved.headers ?? const <String, String>{},
          threadId,
          signal: resolved.signal,
        );
      } finally {
        if (resolved.client == null) client.close();
      }
    },
  );
}

http.Request _getRequest(_JsonPollOptions options, String offset) {
  final request = http.AbortableRequest(
    'GET',
    Uri.parse(
      withSearchParams(options.url, {
        'runId': options.runId,
        'offset': offset,
      }),
    ),
    abortTrigger: options.signal?.whenCancelled,
  );
  request.headers['Accept'] = 'application/json';
  return request;
}

Future<_JsonRunBody> _requestJsonRunBody(
  http.Client client,
  http.Request request,
  CancellationSignal? signal,
) async {
  http.StreamedResponse response;
  try {
    response = await client.send(request);
  } catch (error) {
    throw StreamReadError(error);
  }
  await assertResponseOk(response);

  String text;
  try {
    text = await response.stream.transform(utf8.decoder).join();
  } catch (error) {
    throw StreamReadError(error);
  }
  if (signal?.isCancelled ?? false) {
    throw StreamReadError(StateError('cancelled'));
  }

  Object? parsed;
  try {
    parsed = jsonDecode(text);
  } catch (_) {
    final contentType = response.headers['content-type'] ?? 'none';
    throw FetchJsonException(
      'fetchJson expected a JSON body from ${request.url}, but the response '
      'is not JSON (content-type: $contentType).',
    );
  }
  if (parsed is! Map ||
      parsed['chunks'] is! List ||
      parsed['done'] is! bool ||
      (parsed.containsKey('offset') &&
          parsed['offset'] != null &&
          parsed['offset'] is! String)) {
    throw FetchJsonException(
      'fetchJson expected a { chunks, done, offset? } body from '
      '${request.url}.',
    );
  }
  final chunks = <StreamChunk>[];
  for (final chunk in parsed['chunks'] as List) {
    if (chunk is! Map) {
      throw FetchJsonException(
        'fetchJson expected a { chunks, done, offset? } body from '
        '${request.url}.',
      );
    }
    chunks.add(chunk.map((key, value) => MapEntry('$key', value)));
  }
  return _JsonRunBody(
    chunks,
    parsed['offset'] is String ? parsed['offset'] as String : null,
    parsed['done'] as bool,
  );
}

/// GET the run from [offset]. A read-only GET retries transport drops with the
/// same bounds as a resumable stream reconnect.
Future<_JsonRunBody> _getJsonRunBody(
  _JsonPollOptions options,
  String offset,
) async {
  final tracker = ReconnectTracker(options.reconnect);
  for (;;) {
    try {
      return await _requestJsonRunBody(
        options.client,
        _getRequest(options, offset),
        options.signal,
      );
    } catch (error) {
      final isTransportDrop =
          error is StreamReadError && !(options.signal?.isCancelled ?? false);
      if (!isTransportDrop) rethrow;
      await tracker.waitBeforeReconnect(false, options.signal);
      if (options.signal?.isCancelled ?? false) rethrow;
    }
  }
}

/// Yield each JSON reply's chunks in order, polling from the last offset while
/// `done` is false.
Stream<StreamChunk> _pollJsonRun(
  _JsonPollOptions options,
  Future<_JsonRunBody> Function() firstReply,
) async* {
  var nextReply = firstReply;
  for (;;) {
    _JsonRunBody body;
    try {
      body = await nextReply();
    } catch (error) {
      if (options.signal?.isCancelled ?? false) return;
      rethrow;
    }
    for (final chunk in body.chunks) {
      yield restoreInboundChunk(chunk);
    }
    if (body.done) return;
    final offset = body.offset;
    if (offset == null) {
      throw FetchJsonException(
        'fetchJson got done: false without an offset from ${options.url}, so '
        'it cannot ask for the rest of the run.',
      );
    }
    await abortableDelay(options.pollInterval, options.signal);
    if (options.signal?.isCancelled ?? false) return;
    nextReply = () => _getJsonRunBody(options, offset);
  }
}
