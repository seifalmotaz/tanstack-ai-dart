# Validation

Validated on 2026-11-03 on macOS arm64 against the pinned upstream baseline.

| Check | Dart 3.13.3 | Minimum Dart 3.6.2 |
| --- | --- | --- |
| Full VM suite | 2,429 passed; no failures or skips | 2,429 passed; no failures or skips |
| Full Chrome suite | 1,703 passed; no failures or skips | 1,703 passed; no failures or skips |
| Analyzer fixtures | 34 expected rejections; positive fixtures clean | Same |
| Package analysis | No issues | No issues |

Stable SDK checks also include formatting, the platform test policy (119 test
files, 12 direct `dart:io` imports), and two real browser HTTP checks covering
Arabic content/cookies and cancellation before headers. CI repeats VM tests on
minimum/stable SDKs and browser/static checks on stable.

## Upstream comparison

The pinned baseline contains 1,011 Vitest registrations, including 45
TypeScript type-assertion cases, plus separate `.test-d.ts` assertions.
All registrations are mapped. The audit verifies 968 against actual passing
Dart tests, with no runtime gaps, missing tests, skips, title-only matches, or
orphan mappings. The remaining 43 registrations have explicit static/language
adaptations. Mapping categories overlap; their counts are not additional tests.
See [parity-summary.json](validation/parity-summary.json).

The formerly skipped mutable generation snapshot regression now runs and passes.
Additional cases cover typed scalar collections, nested JSON, cycles, opaque
models, video generation, and explicit result copiers. Unsupported reified
collection shapes require `copySnapshotResult`; they fail explicitly otherwise.

[API_COMPATIBILITY.md](API_COMPATIBILITY.md) records all 247 upstream exports.
Tests reference all 67 runtime exports through public package barrels. Dart does
not reproduce TypeScript conditional, literal, or heterogeneous tuple inference.

Host interfaces are tested with controlled implementations. Real microphone,
WebAuthn, device storage and MCP host integration were not exercised. WebSocket
connections require an injected platform factory. No production credentials or
CRM checkout are needed for these checks. No pub.dev publication was performed.
