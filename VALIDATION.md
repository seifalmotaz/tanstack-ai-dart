# Validation

Dart API revision 0.3.0 validated on 2026-11-03 on macOS arm64. The official
TanStack client baseline remains pinned; no CRM credentials or production calls
are needed for these checks.

| Check | Dart 3.13.3 | Minimum Dart 3.6.2 |
| --- | --- | --- |
| Full VM suite | 2,457 passed; no failures or skips | 2,457 passed; no failures or skips |
| Full Chrome suite | 1,722 passed; no failures or skips | Not repeated for API revision 0.3 |
| Static rejection assertions | 56 checked; positive fixtures clean | 56 checked; positive fixtures clean |
| Package analysis | No issues | No issues |

Stable SDK checks also include clean formatting, the platform test policy and two
real Chrome HTTP checks covering Arabic/cookies and cancellation before headers.
The runnable modern example was checked without an endpoint, so it prints usage
without making a request. CI repeats minimum/stable VM, analyzer fixtures, full
Chrome and real browser HTTP checks on Linux.

## Upstream comparison

The pinned baseline contains 1,011 Vitest registrations, including 45
TypeScript type-assertion cases, plus separate `.test-d.ts` assertions. All are
mapped. The audit links 966 to actual passing Dart tests, with zero missing,
failed, skipped, title-only or orphan runtime mappings.

The other 45 registrations have explicit static/language adaptations. Two were
runtime-invalid JavaScript connection configurations: required named Dart
constructors now reject them during analysis. Actual negative fixtures verify
both partial and mixed modes; metadata/test names alone are not evidence.
Mapping categories overlap and are not additional test counts.
See [parity-summary.json](validation/parity-summary.json).

The existing upstream scenarios retain their assertions through explicit legacy
entry points where the JavaScript signature itself is under test. New Dart API
tests exercise the same engine through typed construction, state streams, typed
message input, immutable state and configuration setters. Generation tests cover
value/stream/HTTP variants, persistence metadata, bad HTTP status and cancellation
of a quiet stream. Part-view tests cover exhaustive switching, unknown wire fields
and nested read-only data.

[API_COMPATIBILITY.md](API_COMPATIBILITY.md) records all 247 upstream exports;
all 67 runtime exports remain reachable through public package barrels. This is
behavior/protocol compatibility, not identical JavaScript call signatures or
TypeScript conditional/literal/tuple inference.

Host interfaces are tested with controlled implementations. Real microphone,
WebAuthn, device storage and MCP host integration were not exercised. WebSocket
connections require an injected platform factory. No pub.dev publication was
performed. [MIGRATION.md](MIGRATION.md) lists the pre-publication breaking changes.
