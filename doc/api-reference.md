# API reference map

The main import is `package:tanstack_ai_dart/tanstack_ai_dart.dart`. This page
maps tasks to public Dart symbols. It is not a generated declaration reference.
Generate local API documentation with `dart doc`; open `doc/api/index.html`.

## Choose a public library

| Import suffix | Main purpose | Entry points |
| --- | --- | --- |
| `tanstack_ai_dart.dart` | Common application entry point | Chat, generation, connections, platform contracts |
| `chat.dart` | Chat state and orchestration | `ChatClient`, `ChatSnapshot`, `ChatMessageInput`, queue and persistence options |
| `connections.dart` | Transports and run context | `ConnectionAdapter`, HTTP/provider factories, `ChatFetcherResult`, cancellation |
| `generation.dart` | Generation and video | `GenerationClient`, `VideoGenerationClient`, `GenerationFetchResult`, restoration helpers |
| `ui.dart` | Typed rendering selectors | Sealed `ChatPart` views and typed tool/result selectors |
| `byok.dart` | Bring-your-own-key support | `defineByok`, storage/provider contracts, keyring errors |
| `platform.dart` | Host implementations | Audio, realtime, storage, MCP, WebMCP, schema interfaces |
| `processing.dart` | Low-level message processing | `StreamProcessor`, chunk conversion, partial JSON strategies |
| `devtools.dart` | Debugging bridges | Devtools clients, ports, and bridge factories |

Avoid imports from `lib/src`. Public libraries define the supported import paths.
Some imports expose matching hydration names with different message models.
Qualify domain imports when using both chat and wire-level hydration together.

## Common chat operations

| Task | API |
| --- | --- |
| Read state | `snapshot`, `state`, `isLoading`, `messages` |
| Observe state | `states.listen(...)` |
| Restore configured state | `await attach()` |
| Release an attached view | `detach()` |
| End client ownership | `await dispose()` |
| Send text | `await sendText(...)` |
| Send typed parts/metadata | `await sendMessage(ChatMessageInput.parts(...))` |
| Stop current work | `await stop()` |
| Clear conversation and configured storage | `await clear()` |
| Page history | `hasOlderMessages`, `await loadOlderMessages()` |
| Replace transcript | `setMessagesManually(...)` |
| Replace transport | `replaceConnection(...)` |
| Respond to tool approval | `await addToolApprovalResponse(...)` |
| Submit a manual tool result | `await addToolResult(...)` |
| Resolve managed interrupts | `resolveInterrupts(...)`, `cancelInterrupts()`, `retryInterrupts()` |

## Common generation operations

Construct a connected client or use `.fetcher(...)`. Read `snapshot`, `states`,
`state`, `result`, and `error`. Await `generate(input)`. Call synchronous `stop()`
or `dispose()` for cancellation or cleanup. Video adds `jobId` and `videoStatus`.

## Configuration contracts

Use typed options rather than JavaScript-style unions. `ToolSchema` values are
explicit validators or raw schema descriptors. `ClientTool<TInput, TOutput>`
keeps callback types, while wire values remain extensible JSON maps.

The [compatibility inventory](../tool/upstream_api_compatibility.json) records
upstream exports, their Dart representation, and language/platform adaptations.
[API compatibility](../API_COMPATIBILITY.md) explains the decisions.
Legacy constructors/accessors are compatibility paths described in
[MIGRATION.md](../MIGRATION.md).
