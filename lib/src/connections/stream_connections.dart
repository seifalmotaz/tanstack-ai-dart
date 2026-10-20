import 'http_common.dart';
import 'dart:async';

import 'package:http/http.dart' as http;

import 'cancellation.dart';
import 'connection_adapter.dart';
import 'response_stream.dart';
import 'resumable_stream.dart';
import 'types.dart';

/// Direct stream factory (`stream()`).
typedef StreamFactory = Stream<StreamChunk> Function(
  List<WireMessage> messages,
  Map<String, dynamic>? data,
  CancellationSignal? signal,
);

/// RPC stream call (`rpcStream()`).
typedef RpcStreamCall = Stream<StreamChunk> Function(
  List<WireMessage> messages,
  Map<String, dynamic>? data,
  CancellationSignal? signal,
);

/// Optional persistence handlers for request-scoped adapters.
class StreamConnectionHandlers {
  final HydrateFunction? hydrate;
  final HydrateGenerationFunction? hydrateGeneration;
  final JoinRunFunction? joinRun;

  const StreamConnectionHandlers({
    this.hydrate,
    this.hydrateGeneration,
    this.joinRun,
  });
}

/// Create a direct stream connection adapter.
ConnectionAdapter stream(
  StreamFactory streamFactory, [
  StreamConnectionHandlers? handlers,
]) {
  return ConnectionAdapter(
    connect: (messages, {data, signal, runContext}) async* {
      yield* _abortableStream(streamFactory(messages, data, signal), signal);
    },
    hydrate: handlers?.hydrate,
    hydrateGeneration: handlers?.hydrateGeneration,
    joinRun: handlers?.joinRun,
  );
}

/// Create an RPC stream connection adapter.
ConnectionAdapter rpcStream(
  RpcStreamCall rpcCall, [
  StreamConnectionHandlers? handlers,
]) {
  return ConnectionAdapter(
    connect: (messages, {data, signal, runContext}) async* {
      yield* _abortableStream(rpcCall(messages, data, signal), signal);
    },
    hydrate: handlers?.hydrate,
    hydrateGeneration: handlers?.hydrateGeneration,
    joinRun: handlers?.joinRun,
  );
}

/// Input passed to a [ChatFetcher].
class ChatFetcherInput {
  final List<WireMessage> messages;
  final Map<String, dynamic>? data;
  final String threadId;
  final String runId;
  final String? parentRunId;
  final List<Map<String, dynamic>>? resume;

  const ChatFetcherInput({
    required this.messages,
    required this.threadId,
    required this.runId,
    this.data,
    this.parentRunId,
    this.resume,
  });
}

/// A fetcher may return a streaming HTTP response or a chunk stream.
typedef ChatFetcher = FutureOr<Object> Function(
  ChatFetcherInput input, {
  CancellationSignal? signal,
  Map<String, String>? headers,
});

/// Wrap a [ChatFetcher] as a [ConnectionAdapter].
///
/// A returned [http.StreamedResponse] is parsed as SSE; a returned
/// `Stream<StreamChunk>` is yielded directly.
ConnectionAdapter fetcherToConnectionAdapter(ChatFetcher fetcher) {
  return ConnectionAdapter(
    connect: (messages, {data, signal, runContext}) async* {
      if (signal == null) {
        throw ArgumentError(
          'fetcherToConnectionAdapter requires a CancellationSignal — the '
          'chat client always supplies one.',
        );
      }
      if (runContext == null) {
        throw ArgumentError(
          'fetcherToConnectionAdapter requires a RunAgentInputContext — the '
          'chat client always supplies one.',
        );
      }
      final result = await fetcher(
        ChatFetcherInput(
          messages: messages,
          data: data,
          threadId: runContext.threadId,
          runId: runContext.runId,
          parentRunId: runContext.parentRunId,
          resume: runContext.resume,
        ),
        signal: signal,
        headers: runContext.headers,
      );
      if (result is http.StreamedResponse) {
        await assertResponseOk(result);
        final lines = readResponseLines(result.stream, signal: signal);
        await for (final event in linesToSseEvents(
          lines,
          fallbackThreadId: runContext.threadId,
          fallbackRunId: runContext.runId,
        )) {
          yield event.chunk;
        }
      } else if (result is Stream<StreamChunk>) {
        yield* _abortableStream(result, signal);
      } else {
        throw ArgumentError(
          'ChatFetcher must return an http.StreamedResponse or a '
          'Stream<StreamChunk>',
        );
      }
    },
  );
}

Stream<T> _abortableStream<T>(
  Stream<T> source,
  CancellationSignal? signal,
) async* {
  if (signal?.isCancelled ?? false) return;
  final iterator = StreamIterator<T>(source);
  try {
    while (true) {
      final next = iterator.moveNext();
      if (signal == null) {
        if (!await next) return;
      } else {
        final hasNext = await Future.any<bool>([
          next,
          signal.whenCancelled.then((_) => false),
        ]);
        if (!hasNext) return;
      }
      yield iterator.current;
    }
  } finally {
    await iterator.cancel();
  }
}
