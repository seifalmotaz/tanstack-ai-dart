# Connections and authentication

Import `package:tanstack_ai_dart/tanstack_ai_dart.dart`. All examples below are
extracted from [recipes.dart](../example/recipes.dart).

## Choose a transport

| Factory | Response format | Application responsibility |
| --- | --- | --- |
| `fetchServerSentEvents` | SSE carrying TanStack chunks | Compatible HTTP backend |
| `fetchHttpStream` | NDJSON chunks or replay envelopes | Compatible HTTP backend |
| `fetchJson` | JSON polling responses | Backend polling contract |
| `xhrServerSentEvents`, `xhrHttpStream` | SSE or NDJSON | Browser XHR when no client is injected |
| `webSocket` | TanStack WebSocket messages | Injected `WebSocketFactory` |
| `stream`, `rpcStream` | Dart streams of decoded chunks | Custom stream implementation |
| `fetcherToConnectionAdapter` | Typed stream or HTTP response | Custom request function |

Fixed URL factories accept a `String` and named `options`. Their corresponding
`...Provider` factories accept async or synchronous URL/options callbacks.
Providers are read for operations that acquire a URL/options pair. See the
adapter source for exact reconnect behavior; do not assume every replayed HTTP
attempt re-runs application callbacks.

## Refresh authentication

Pass token lookup as an argument, so credential ownership stays in your app:

<!-- example: example/recipes.dart#refresh -->
```dart
ChatClient authenticatedChat(
  String endpoint,
  Future<String> Function() readAccessToken,
) =>
    ChatClient(
      connection: fetchServerSentEventsProvider(
        url: () => endpoint,
        options: () async => FetchConnectionOptions(
          headers: {'Authorization': 'Bearer ${await readAccessToken()}'},
        ),
      ),
    );
```
<!-- /example -->

Server authentication, tenant authorization, provider selection, and endpoint
access rules are backend responsibilities. In a browser, cookies and credentialed
requests also depend on CORS and the server's cookie configuration. Configure
`FetchConnectionOptions.credentials` according to your deployment.

Internally created HTTP clients are closed by the adapter. Injected
`package:http` clients stay caller-owned. Cancellation signals are forwarded to
request implementations. A custom fetcher must cooperate with cancellation for
work outside the SDK's stream ownership.

## Supply a custom fetcher

Return `ChatFetcherResult.response` for a `package:http` SSE response or
`ChatFetcherResult.stream` for decoded `Stream<StreamChunk>` values:

<!-- example: example/recipes.dart#fetcher -->
```dart
ChatClient customHttpChat(
  Future<http.StreamedResponse> Function(
    ChatFetcherInput input,
    CancellationSignal? signal,
    Map<String, String>? headers,
  ) request,
) =>
    ChatClient(
      connection: fetcherToConnectionAdapter(
        (input, {signal, headers}) async => ChatFetcherResult.response(
          await request(input, signal, headers),
        ),
      ),
    );
```
<!-- /example -->

`request` is an application-provided function. The explicit result variant
replaces a runtime union of unrelated return types.

Custom adapters use either `ConnectionAdapter.connect(connect: ...)` or
`ConnectionAdapter.subscription(subscribe: ..., send: ...)`. Required parameters
prevent partial or mixed modes during analysis. Add `hydrate` and `joinRun`
handlers when your backend supports durable history and live replay.

## Match the backend protocol

The HTTP streaming adapter sends JSON run-agent input, including messages and
run context, to your endpoint. SSE responses carry TanStack event chunks and
must have the expected streaming body. Durable replay additionally depends on
the server's run IDs and event offsets. A generic OpenAI-compatible text stream
is not interchangeable with this protocol.

The supported source revision is listed in the [README](../README.md).
Read [parity methodology](../PARITY.md) and the
pinned official source linked by the README compatibility table
when implementing or changing a backend contract.
