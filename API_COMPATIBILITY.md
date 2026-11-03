# Upstream API compatibility

This package targets `@tanstack/ai-client` 1.0.1 and `@tanstack/ai` 1.0.1 at
[commit `a7eb58459ebd528bbcc4166cc68377b777989462`](https://github.com/TanStack/ai/tree/a7eb58459ebd528bbcc4166cc68377b777989462).
It is an unofficial Dart client, not the JavaScript package. Dart uses named
arguments, state streams, enums and sealed fetcher results. See
[MIGRATION.md](MIGRATION.md) for the 0.4 breaking changes.

The executed-source inventory covers all four official package export paths:

| Upstream path | Dart barrel | Runtime | Type | Total |
| --- | --- | ---: | ---: | ---: |
| `.` | `lib/tanstack_ai_dart.dart` | 50 | 135 | 185 |
| `./byok` | `lib/byok.dart` | 11 | 10 | 21 |
| `./ui` | `lib/ui.dart` | 6 | 35 | 41 |
| `./devtools` | `lib/devtools.dart` | 8 | 21 | 29 |
| Total | | 75 | 201 | 276 |

[`tool/upstream_api_compatibility.json`](tool/upstream_api_compatibility.json)
records a Dart symbol and evidence or an explicit limitation for each slot.
It classifies 103 as Dart equivalents, 126 as Dart adaptations, 10 as platform
interfaces, 35 as TypeScript type-level limitations, one as server-side and one
as a legacy name collision. These classifications describe the API shape;
[PARITY.md](PARITY.md) and [VALIDATION.md](VALIDATION.md) describe the separate
behavioral evidence. Four devtools core-state and patch types use an
`AIDevtools` prefix in Dart; the public-barrel analyzer fixture checks all 29
entry-point equivalents.

Modern constructors require one non-empty `threadId`. Connection `connect` and
`send` callbacks require a `RunAgentInputContext`; stream and RPC callbacks
receive a `StreamRequest` containing the full wire input. Generation fetcher
options carry the thread ID, run ID and cancellation signal. Persistence
variants carry storage and history configuration, not a duplicate identity.
`ChatHydrationResult` and `ChatHydrateOptions` are public connection types;
`LegacyChatHydrationResult` names the older transcript-based value.

`ChatInterrupt` is an immutable Dart value with a string `kind`, rather than
upstream's statically discriminated TypeScript union. Dart callers check the
kind at runtime; `selectRegisteredInterrupt` supplies a typed registered
payload/response view. Published interrupt data and errors are read-only.
Calling `resolveInterrupt` on an unbound item returns null. Dart deliberately
does not automatically execute a client tool from an unbound interrupt,
including unsupported 0.x descriptors. The pinned upstream client does execute
that noncanonical input while exposing the interrupt as unbound; the separate
reproducible `tool/probe_upstream_unbound.test.ts` demonstrates the difference.

The Dart `ChatTransport` name retains its explicit legacy stream contract;
modern clients use `ConnectionAdapter` and `fetcherToConnectionAdapter`.
`RealtimeAdapter` and `RealtimeConnection` remain Dart platform interfaces
used by realtime support, although the 1.0.1 client package no longer re-exports
the corresponding upstream core types.

Microphone, WebAuthn, browser storage, WebMCP, MCP host messaging and websocket
capabilities require an injected host implementation. Tests use controlled
hosts; real devices and host integrations have not been exercised. The injected
HTTP-client XHR cleanup test observes response cancellation, not native handler
removal. Separate Chrome HTTP tests cover real XHR streaming, credentials and
abort before headers. Provider adapters, server orchestration, server devtools
middleware and server command execution are outside this client SDK.
