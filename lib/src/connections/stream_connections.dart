import 'dart:async';

import 'package:http/http.dart' as http;

import 'cancellation.dart';
import 'connection_adapter.dart';
import 'http_common.dart';
import 'response_stream.dart';
import 'resumable_stream.dart';
import 'types.dart';
import 'wire.dart';

/// Request passed to a direct or RPC stream factory.
class StreamRequest {
  final List<WireMessage> messages;
  final Map<String, dynamic>? data;
  final CancellationSignal? signal;
  final Map<String, dynamic> input;

  const StreamRequest(
      {required this.messages, this.data, this.signal, required this.input});
}

typedef StreamFactory = Stream<StreamChunk> Function(StreamRequest request);
typedef RpcStreamCall = Stream<StreamChunk> Function(StreamRequest request);

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
  return ConnectionAdapter.connect(
    connect: (messages, {data, signal, required runContext}) async* {
      yield* _abortableStream(
          streamFactory(StreamRequest(
              messages: messages,
              data: data,
              signal: signal,
              input: buildRunAgentInputBody(messages, data, runContext))),
          signal);
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
  return ConnectionAdapter.connect(
    connect: (messages, {data, signal, required runContext}) async* {
      yield* _abortableStream(
          rpcCall(StreamRequest(
              messages: messages,
              data: data,
              signal: signal,
              input: buildRunAgentInputBody(messages, data, runContext))),
          signal);
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

/// The typed result of a [ChatFetcher].
///
/// Construct with [ChatFetcherResult.stream] to yield already-decoded chunks,
/// or [ChatFetcherResult.response] to let this package parse an SSE response.
/// The sealed hierarchy makes consumers exhaustive.
sealed class ChatFetcherResult {
  const ChatFetcherResult._();

  factory ChatFetcherResult.stream(Stream<StreamChunk> stream) =
      ChatFetcherStreamResult;

  factory ChatFetcherResult.response(http.StreamedResponse response) =
      ChatFetcherResponseResult;
}

/// A [ChatFetcherResult] carrying a chunk stream.
final class ChatFetcherStreamResult extends ChatFetcherResult {
  final Stream<StreamChunk> stream;

  const ChatFetcherStreamResult(this.stream) : super._();
}

/// A [ChatFetcherResult] carrying an HTTP response whose body is parsed as SSE.
final class ChatFetcherResponseResult extends ChatFetcherResult {
  final http.StreamedResponse response;

  const ChatFetcherResponseResult(this.response) : super._();
}

/// A fetcher returns either a chunk stream or a streaming HTTP response.
///
/// Return `ChatFetcherResult.stream(...)` for chunks you already parsed, or
/// `ChatFetcherResult.response(...)` for an SSE body this package should parse.
/// The result may be synchronous or asynchronous.
typedef ChatFetcher = FutureOr<ChatFetcherResult> Function(
  ChatFetcherInput input, {
  CancellationSignal? signal,
  Map<String, String>? headers,
});

/// Wrap a [ChatFetcher] as a [ConnectionAdapter].
///
/// A [ChatFetcherResponseResult] is parsed as SSE; a
/// [ChatFetcherStreamResult] is yielded directly.
ConnectionAdapter fetcherToConnectionAdapter(ChatFetcher fetcher) {
  return ConnectionAdapter.connect(
    connect: (messages, {data, signal, required runContext}) async* {
      if (signal == null) {
        throw ArgumentError(
          'fetcherToConnectionAdapter requires a CancellationSignal — the '
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
      switch (result) {
        case ChatFetcherResponseResult(:final response):
          await assertResponseOk(response);
          final lines = readResponseLines(response.stream, signal: signal);
          await for (final event in linesToSseEvents(
            lines,
          )) {
            yield event.chunk;
          }
        case ChatFetcherStreamResult(:final stream):
          yield* _abortableStream(stream, signal);
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
