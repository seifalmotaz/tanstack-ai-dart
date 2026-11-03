# Migration

The Dart client deliberately does not automatically execute a client tool
from an unbound interrupt, including unsupported 0.x descriptors. A reproducible
upstream probe (`tool/probe_upstream_unbound.test.ts`) shows the pinned upstream
client executes that tool while exposing the interrupt as unbound; the Dart
regression asserts it stays unexecuted. This is a deliberate input boundary,
not a claim of exact behavior for that noncanonical input.


## Migrating to 0.4

The 0.4 API targets TanStack AI 1.0.1 and includes these breaking changes:

- Pass a stable non-empty `threadId` to each modern chat or generation client.
  Persistence options no longer take a second copy of that ID.
- Supply `runContext` when calling a connection adapter's `connect` or `send`
  directly. Direct and RPC stream callbacks receive one `StreamRequest`,
  including the complete wire `input`.
- `ChatHydrationResult` now names the connection hydration result in the root
  import. The older `AssistantTurn`-based hydration value is named
  `LegacyChatHydrationResult`.
- Use `forwardedProps` for chat-wide request values and per-send `body` for
  overrides. The old chat-level `body` is available only through explicitly
  named legacy APIs. Wire payloads no longer duplicate it under `data`.
- Resolve a bound approval with `interrupt.resolveApproval(...)`; unbound
  pre-1.0 interrupts are display-only. The old bare-array persisted chat format
  is not loaded or overwritten; clear or migrate that data before saving again.
- Use `RUN_FINISHED`, not `[DONE]`, to terminate a stream. Legacy STEP-based
  reasoning and custom approval/tool-input events are no longer interpreted as
  the current protocol.
- Direct generation fetchers receive `threadId` and `runId` in their options.
- Chat snapshots expose `resumeState` together with `interruptState` on the
  `states` stream. Interrupt values and their nested JSON are read-only.
- Prefer `getInterrupts()`, `resolveInterrupts()` and `resumeInterruptsUnsafe()`.
  Old call shapes are explicitly named `getLegacyPendingInterrupts()`,
  `resumeInterruptsLegacy()` and `addLegacyToolApprovalResponse()`.
- Reconnects use exponential backoff with jitter and a default five-attempt
  ceiling. A configured time budget removes that default ceiling; the previous
  `delay` option remains supported as an alias for the initial delay.

The explicit pre-0.3 `ChatTransport` path remains a legacy API and is not
evidence of 1.0 server compatibility.

## Migrating to 0.3

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
while migrating older JS-shaped call sites. Their call shapes remain available for existing applications; the legacy
transport is not evidence of 1.0 server compatibility. Legacy `getMessages()` intentionally retains its live
mutable-list contract; the default transcript/snapshot getters are read-only.

The three generation type parameters distinguish input, raw result, and transformed
output. They remain explicit where needed; schema-driven TypeScript inference is
not reproduced. Typed fetchers distinguish results from transport responses even
when an application result itself happens to be a response/stream-like object.

For Flutter, subscribe using `StreamBuilder` or the app's existing state management.
The core package has no Flutter dependency. State streams emit an initial snapshot
per listener, then updates, and close when their owner is disposed.
