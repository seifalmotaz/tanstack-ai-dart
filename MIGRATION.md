# Migrating to 0.3

The wire protocol and TanStack client behavior remain pinned to the same upstream
commit. The default Dart API changes before the first pub.dev publication.

| Previous usage | Dart API |
| --- | --- |
| `ChatClient(options: ChatClientOptions(...))` | `ChatClient(connection: ..., namedParameter: ...)` |
| `fetchServerSentEvents(url, options)` | `fetchServerSentEvents(url, options: options)` |
| URL/options as either values or callbacks | Static factory or named `...Provider(url: callback, options: callback)` |
| Optional connect/subscribe/send fields | `ConnectionAdapter.connect(...)` or `.subscription(...)` |
| Fetcher returns arbitrary `Object` | `ChatFetcherResult.stream(...)` or `.response(...)` |
| Generation fetcher returns arbitrary `Object` | `GenerationClient.fetcher` and `GenerationFetchResult.value/stream/response` |
| `subscribeSnapshot` plus unsubscribe callback | `states.listen(...)` and `StreamSubscription.cancel()` |
| `getSnapshot()`, `getState()`, `getIsLoading()` | `snapshot`, `state`, `isLoading` |
| Chat status strings | `ChatClientState` and `ChatConnectionState` enums |
| `sendMessage` accepts text/map/parts | `sendText(String)` or `sendMessage(ChatMessageInput.text/parts(...))` |
| Boolean/storage persistence union | `ChatPersistenceOptions.ephemeral/server/stored` |
| Generation boolean persistence | `GenerationPersistenceOptions.ephemeral/persistent` |
| Mutable `client.messages` | Read-only transcript; use `setMessagesManually(...)` |
| `updateOptions` with untyped optional values | Typed setters; assigning `null` explicitly clears nullable configuration |
| Raw input/output schema passed to a tool | `RawJsonSchema(...)` or a validating `StandardSchema(...)` |
| `clientTools([...])` | A normal Dart list |
| Approval schema reflection/side table | `tool.approvalSchema` field |
| String-discriminated mutable parts for rendering | Sealed immutable `message.chatParts` / `part.chatPart` views |

`ChatClient.status` and `ChatSnapshot.status` expose `ChatClientState`; the legacy
`getStatus()` method still returns the wire string. `ChatSnapshot.connectionStatus`
is a `ChatConnectionState`. Serialize enum `.name` when a wire string is needed.

Use `ChatClient.legacy(...)` for previous constructor options/aliases and raw
fetcher unions. Use `sendLegacyMessage(...)` and `updateLegacyOptions(...)` only
while migrating older JS-shaped call sites. Their behavior remains tested against
the pinned upstream suite. Legacy `getMessages()` intentionally retains its live
mutable-list contract; the default transcript/snapshot getters are read-only.

The three generation type parameters distinguish input, raw result, and transformed
output. They remain explicit where needed; schema-driven TypeScript inference is
not reproduced. Typed fetchers distinguish results from transport responses even
when an application result itself happens to be a response/stream-like object.

For Flutter, subscribe using `StreamBuilder` or the app's existing state management.
The core package has no Flutter dependency. State streams emit an initial snapshot
per listener, then updates, and close when their owner is disposed.
