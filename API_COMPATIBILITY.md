# Upstream API compatibility

This reference records the reviewed public exports and the Dart-specific type
contract. Test results and supported toolchains are in [VALIDATION.md](VALIDATION.md).

Target: `@tanstack/ai-client` 0.40.0 and `@tanstack/ai` 0.70.0, commit
`7095ebbf1b59175f0cd339c1c477d6af55b312de`. Pinned upstream source:
[ai-client source](https://github.com/TanStack/ai/tree/7095ebbf1b59175f0cd339c1c477d6af55b312de/packages/ai-client/src).

The machine-readable inventory is
[`tool/upstream_api_compatibility.json`](tool/upstream_api_compatibility.json).
The executable inventory check is
[`test/interop/public_export_inventory_test.dart`](test/interop/public_export_inventory_test.dart).

## Method

Every export listed in `tool/upstream_api.json` was reviewed: 185 root, 21 BYOK
and 41 UI, for 247 total. For each export this audit:

1. Resolved the corresponding public barrel recursively, honoring every
   `export ... show` and `export ... hide` directive:
   - root (`index`): `lib/tanstack_ai_dart.dart`
   - BYOK: `lib/byok.dart`
   - UI: `lib/ui.dart`
2. Located the actual Dart declaration or runtime implementation in `lib/`, not
   merely a matching substring or a similarly named file.
3. Distinguished runtime exports from type-only exports and checked that every
   runtime export is reachable and usable from its public barrel.
4. Recorded either a concrete Dart equivalent or a concrete TypeScript-only,
   platform, or server-out-of-scope reason.

`dart-equivalent` in the JSON means "a public Dart symbol exists and is usable
from the corresponding barrel"; it does not by itself claim behavioral parity.
Behavioral coverage remains tracked by the separate upstream-test mapping audit.

## Counts

| Surface | Upstream barrel | Runtime | Type | Total | Dart equivalent | Dart adapted | Platform interface | Language limitation | Server out of scope | Name collision |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `index` | `lib/tanstack_ai_dart.dart` | 50 | 135 | 185 | 88 | 74 | 7 | 15 | 0 | 1 |
| `byok` | `lib/byok.dart` | 11 | 10 | 21 | 17 | 0 | 3 | 0 | 1 | 0 |
| `ui` | `lib/ui.dart` | 6 | 35 | 41 | 13 | 8 | 0 | 20 | 0 | 0 |
| **Total** | | **67** | **180** | **247** | **118** | **82** | **10** | **35** | **1** | **1** |

Status meanings:

- `dart-equivalent`: same-name public Dart symbol with the same role.
- `dart-adapted`: public Dart symbol exists but the contract differs in shape
  (renamed, collapsed union, explicit generic, or literal union replaced by
  `String`/an enum).
- `platform-interface`: public runtime symbol exists, but the capability needs
  an injected host implementation and reports unavailable without one.
- `language-limitation`: TypeScript conditional, mapped, literal-union, tuple or
  utility type with no direct Dart type; the JSON records the Dart workaround
  when one exists.
- `server-out-of-scope`: export belongs to the `@tanstack/ai` server/provider
  package, not this client SDK.
- `name-collision`: an exported Dart name exists but has a different contract
  from the upstream export.

No upstream runtime export is missing from the three public barrels: 67/67
runtime exports are reachable. The JSON still records 35 language limitations
and 1 name collision for type/semantic review.

## Runtime exports

All 67 runtime exports are referenced by the inventory test and are usable from
their public barrel. This includes the 50 root exports, 11 BYOK exports and 6 UI
selectors.

Ten of them are marked `platform-interface` because they require a host seam:

- `AudioRecorder` requires an `AudioRecorderPlatform` backed by browser media
  APIs.
- `getWebMCPTools`, `registerWebMCPTools`, `subscribeWebMCPTools` require a
  WebMCP host context.
- `localStoragePersistence`, `sessionStoragePersistence`,
  `indexedDBPersistence` require browser storage and raise
  `StorageUnavailableError` otherwise.
- `defaultByokStorage`, `isPasskeyStorageSupported`, `passkeyStorage` require a
  WebAuthn/passkey host; the keyring HKDF/AES-GCM cryptography itself is real
  Dart.

The remaining runtime exports are ordinary Dart implementations. `clientTools`
was confirmed directly in `lib/src/platform/tool_types.dart:184` and through the
root export chain; it is public despite being missed by a naive declaration
scan.

## Type contract

The Dart port intentionally does not emulate TypeScript's type system. The
current contract is:

- **Caller context is `Object?`.** `ChatClientOptions.context`,
  `ToolCallContext.context`, WebMCP options and strategy inputs carry `Object?`.
  Context requirements are not inferred from registered tools or schemas.
  Callers must cast or validate it themselves.
- **Inputs and outputs are explicit generics.** `ClientTool<TInput, TOutput>`,
  `GenerationClient<TInput, TResult, TOutput>` and
  `VideoGenerationClient<TOutput>` support explicit types and ordinary Dart
  callback inference. There is no schema-to-type inference.
- **No heterogeneous tuple, literal, conditional or mapped inference.** The
  upstream `Infer*`, `Extract*`, `ChatUI*Of`, `DistributedOmit` and similar
  helpers have no Dart equivalent. `clientTools` returns a list, not a tuple;
  tool names are `String`, not literal unions.
- **Literal unions become `String` or enums.** Examples: `ConnectionStatus` and
  `PersistedArtifactRole` are `String`; `WhenBusy` is `QueueWhenBusy`;
  `InterruptItemStatus` is `ChatInterruptStatus`.
- **Unions become one concrete class.** `UIMessage` maps to `AssistantTurn`;
  every message part maps to `AssistantPart` discriminated by `type`;
  interrupt variants map to `ChatInterrupt` discriminated by `kind`.
- **UI selectors are concrete, with explicit typed helpers.** `ui.dart` exposes
  concrete selected-part classes. `typed_ui.dart` adds explicit
  `ChatTyped*` helpers for callers that want tool input/output typing without
  pretending Dart inferred it.

These are documented as adaptations, not as parity with TypeScript's
compile-time inference. Runtime presence is not a substitute for a type-level
guarantee.

## Notable adaptations

- `UIMessage` / `MessagePart` / part interfaces -> `AssistantTurn` /
  `AssistantPart`.
- `ChatClientSnapshot` -> `ChatSnapshot`; `ConnectionStatus` -> `String`.
- `ChatPendingInterrupt` and the bound/generic/approval interrupt unions ->
  `ChatInterrupt`; `InterruptItemStatus` -> `ChatInterruptStatus`.
- `WhenBusy` -> `QueueWhenBusy`; `QueueConfig` -> `ChatQueueConfig`;
  `SendMessageOptions` -> `ChatSendOptions`.
- `MultimodalContent` -> `ChatMessageInput`; `ChatRequestBody` ->
  `Map<String, dynamic>`.
- `AudioGenerateInput`, `SpeechGenerateInput`,
  `TranscriptionGenerateInput` and `SummarizeGenerateInput` have no named Dart
  model. `GenerationClient<TInput, TResult, TOutput>` accepts a `Map<String, dynamic>` with the
  documented wire fields or any object exposing `toJson()`.
- `WebMCP*` type names map to Dart `WebMcp*`; runtime function names keep the
  upstream `WebMCP` spelling.
- `ChatFetcherOptions` is represented by named `signal`/`headers` parameters on
  the `ChatFetcher` typedef.

## Name collision

`ChatTransport` is the one exported name whose Dart contract is not the
upstream contract. Upstream `ChatTransport` is the 0.40 XOR union of
`{ connection }` or `{ fetcher }`. The exported Dart `ChatTransport` is the
legacy 0.42-era stream transport. The 0.40 contract is represented by
`ChatClientOptions.connection` / `ChatClientOptions.fetcher` and
`ConnectionAdapter`. Do not treat the Dart `ChatTransport` symbol as the
upstream 0.40 union; see the gaps file.

## Server and platform scope

`ByokProviderInit` comes from the `@tanstack/ai/byok` server package and is
outside this client port. Provider/model adapters and server orchestration from
`@tanstack/ai` are likewise out of scope. This package is a client SDK, not a
provider/server adapter and not a Flutter hardware plugin.

## Verification

Check the public export references:

```sh
dart analyze test/interop/public_export_inventory_test.dart
dart test test/interop/public_export_inventory_test.dart
```

The test references every runtime export from the public barrels, every
same-name type export, and the principal adapted types. It also exercises
representative runtime behavior (`partTypeToKey`, `collectInlineToolNames`,
`parsePartialJSON`, `generateMessageId`, `clientTools`, `defineByok`,
`memoryStorage`, `defineByokProvider`, and UI selection).

## Compatibility decisions

`ChatTransport` keeps its existing legacy stream-transport meaning for callers
using the 0.42 protocol. Use `ChatClientOptions.connection` or `.fetcher` for the
modern transport selection. The constructor rejects conflicting connection and
fetcher options at runtime. No alias claims to provide the TypeScript XOR type.

Caller context remains `Object?` by design. A consuming application should
validate it as its own model before using it. Adding wrapper clients would not
provide TypeScript's automatic intersection of heterogeneous tool contexts.

Generation snapshots copy JSON containers and JSON scalar collections read-only.
Other reified collection shapes use `copySnapshotResult`; see the example and
migration note in [README.md](README.md). Opaque class instances retain identity,
so their mutability is the responsibility of their model implementation.

Host-dependent capabilities require implementations supplied by the consuming
application, including a WebSocket factory for WebSocket connections.
This package does not claim to implement a Flutter audio,
WebAuthn, native-storage, or MCP host plugin.
