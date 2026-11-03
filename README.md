# tanstack_ai_dart

Unofficial, framework-independent Dart client for TanStack AI. It implements
chat, generation/video, client tools, interrupts, persistence/resume, BYOK and
devtools against `@tanstack/ai-client` **0.40.0** / `@tanstack/ai` **0.70.0**,
pinned to `7095ebbf1b59175f0cd339c1c477d6af55b312de`.

This is a Dart API over the TanStack protocol. JavaScript call signatures and
TypeScript inference are not its public API contract. The package is not
maintained by TanStack and does not include server/provider adapters.

## Install

Requires Dart `>=3.6.2 <4.0.0`. Not yet published to pub.dev.

```yaml
dependencies:
  tanstack_ai_dart:
    git:
      url: https://github.com/seifalmotaz/tanstack-ai-dart.git
      ref: main
```

## Chat

```dart
import 'package:tanstack_ai_dart/tanstack_ai_dart.dart';

final client = ChatClient(
  connection: fetchServerSentEvents(
    'https://your-service.example/api/chat',
    options: const FetchConnectionOptions(
      headers: {'Authorization': 'Bearer YOUR_TOKEN'},
    ),
  ),
  threadId: 'conversation-123',
);

final subscription = client.states.listen((snapshot) {
  // Render snapshot.messages and snapshot.state.
  // ChatClientState is an enum, including submitted, streaming, ready, error.
});

await client.attach();
await client.sendText('Hello');
await client.sendMessage(const ChatMessageInput.text('Follow up', id: 'user-2'));

await subscription.cancel();
await client.dispose();
```

`client.snapshot` reads current state. Each `states` listener receives current
state followed by ordered updates, buffers independently while paused, and can
cancel independently. Errors are represented in snapshots rather than emitted
as stream errors. Disposal closes the stream, including for later listeners.
Disposal does not wait for a paused state listener to resume.

The core has no Flutter dependency. In Flutter, pass `client.states` to
`StreamBuilder<ChatSnapshot>` with `initialData: client.snapshot`, and dispose
subscriptions/client when their owner leaves. No widget lifecycle is required
for plain Dart usage.

`client.messages` and published snapshots are read-only. Replace the transcript
with `setMessagesManually(...)` rather than modifying a list or part. Update
configuration with typed setters such as `client.body = null`, `client.context =
myContext`, `client.tools = tools`, and `client.queueConfig = config`.

## Connections and authentication refresh

SSE, NDJSON, polling JSON and WebSocket adapters share `ConnectionAdapter`.
Fixed URLs use named options. Async URL/header refresh uses a provider factory:

```dart
final connection = fetchServerSentEventsProvider(
  url: () async => 'https://your-service.example/api/chat',
  options: () async => FetchConnectionOptions(
    headers: {'Authorization': 'Bearer ${await readAccessToken()}'},
  ),
);
```

Providers run per operation, so reconnect, history and replay can use fresh
credentials. Options can inject a `package:http` client. Injected clients remain
caller-owned; clients created internally are closed by the adapter.

Custom connections use `ConnectionAdapter.connect(connect: ...)` or
`ConnectionAdapter.subscription(subscribe: ..., send: ...)`. Partial and mixed
modes fail analysis. Custom fetchers return explicit variants:

```dart
final connection = fetcherToConnectionAdapter(
  (input, {signal, headers}) async {
    // request() returns package:http's StreamedResponse.
    final response = await request(input, signal, headers);
    return ChatFetcherResult.response(response);
    // Or return ChatFetcherResult.stream(yourChunkStream).
  },
);
```

`fetchHttpStream`, `fetchJson`, `xhrServerSentEvents`, `xhrHttpStream` and
`webSocket` have corresponding `...Provider` factories. WebSocket requires a
platform socket factory. Wire payloads remain extensible JSON maps.

## Persistence and lifecycle

Use one typed persistence choice:

```dart
final client = ChatClient(
  connection: connection,
  persistence: const ChatPersistenceOptions.server(
    threadId: 'conversation-123',
    history: ChatHistoryConfig(pageSize: 20),
  ),
);
```

- `ChatPersistenceOptions.ephemeral(...)` is the default.
- `.server(...)` requires a stable thread ID and uses adapter history/replay.
- `.stored(threadId: ..., adapter: ...)` stores messages and resume state together
  through a `ChatClientPersistence` implementation.

Call `attach()` to restore history/rejoin a live run. Construction alone does
not open a replay connection. `detach()` releases the active view; `dispose()`
ends ownership. Queue policies, history paging, interrupts and cancellation
retain their TanStack behavior.

## Tools

Use ordinary Dart lists and `ClientTool<TInput, TOutput>`. Schemas are explicit
`ToolSchema` objects. `RawJsonSchema` advertises a JSON schema; it does not validate
inputs. `StandardSchema` runs a caller-provided validator/decoder and can return
an application model before execution. No schema-library dependency is required.

```dart
final tool = ClientTool<String, int>(
  name: 'length',
  inputSchema: StandardSchema(
    (value) => value is String
        ? SchemaValidationResult.success(value)
        : const SchemaValidationResult.failure([SchemaIssue('Expected text')]),
    schema: {'type': 'string'},
  ),
  execute: (text, context) => text.length,
);
client.tools = [tool];
```

Tool callbacks use `FutureOr<TOutput>` and receive `ToolCallContext`, including
cancellation and caller context. Caller context remains application-defined;
Dart does not infer TypeScript intersections of heterogeneous tool contexts.
Read `tool.approvalSchema` directly. Client tools, approval/interrupt submissions
and automatic continuations are covered by the upstream behavior mappings.

## Rendering message parts

`message.chatParts` provides immutable sealed variants for exhaustive switches.
For example, `if (part case ChatTextPart(:final content))` extracts text.
Other variants cover thinking, tools/results, activities, structured output,
subagents and media. `ChatUnknownPart` preserves future part types. Every variant
retains deep-frozen wire JSON. Opaque application objects retain their identity.
The mutable `AssistantPart` model remains available for explicit wire/reducer
integration and constructing outgoing parts.

## Generation

Use a connection with the default constructor, or a typed fetcher:

```dart
final generator = GenerationClient<String, Map<String, dynamic>,
    Map<String, dynamic>>.fetcher(
  fetcher: (prompt, options) async => GenerationFetchResult.value(
    await generateImage(prompt, options.signal),
  ),
);
final subscription = generator.states.listen((snapshot) {
  // Render snapshot.result, snapshot.status and snapshot.error.
});
await generator.generate('A house in Cairo');
await subscription.cancel();
generator.dispose();
```

`GenerationFetchResult.value(...)`, `.stream(...)` and `.response(...)` distinguish
application results from protocol streams/HTTP responses. `VideoGenerationClient`
uses the same variants with `VideoGenerateResult`. `GenerationPersistenceOptions`
has `.ephemeral(...)` and `.persistent(threadId: ...)` constructors.

Generation snapshots copy JSON maps/lists and scalar-typed JSON collections
read-only. `result` retains the original result; published unchanged results
retain identity across status updates. Other reified collection shapes need an
explicit copier:

```dart
copySnapshotResult: (Map<String, List<int>> value) =>
    Map<String, List<int>>.unmodifiable({
      for (final entry in value.entries)
        entry.key: List<int>.unmodifiable(entry.value),
    }),
```

Without a compatible copier the error state contains `SnapshotCopyException`.
Opaque class instances retain identity; use immutable application models.

## Compatibility and platform support

Domain imports are available in `chat.dart`, `connections.dart`, `generation.dart`,
`ui.dart`, `byok.dart`, `platform.dart`, `processing.dart`, and `devtools.dart`.
[API_COMPATIBILITY.md](API_COMPATIBILITY.md) records upstream exports and Dart
adaptations. [VALIDATION.md](VALIDATION.md) records executed checks.

Audio, WebAuthn, storage, WebSocket and MCP host capabilities require the
consuming application to supply platform implementations. Their interfaces and
crypto are tested; no Flutter hardware plugin is bundled.

Pre-0.3 JavaScript-shaped construction is available explicitly through
`ChatClient.legacy`, `GenerationClient.legacy`, and `VideoGenerationClient.legacy`.
`sendLegacyMessage`, `updateLegacyOptions`, old `get...()` accessors and identity
helpers exist for migration/upstream compatibility. In particular, legacy
`getMessages()` returns live mutable data; new code should use `messages` or
`snapshot`. The earlier TanStack AI 0.42 `SseChatTransport` remains supported.
See [MIGRATION.md](MIGRATION.md) for the breaking API changes.
