# Compatibility and verification

Target: `@tanstack/ai-client` 0.40.0, `@tanstack/ai` 0.70.0.
Upstream commit: `7095ebbf1b59175f0cd339c1c477d6af55b312de`.
Source: <https://github.com/TanStack/ai> (MIT; see THIRD_PARTY_NOTICES).

The pinned JavaScript client suite was executed locally: **1,011 Vitest cases
passed**, with no skipped or failed cases. Its TypeScript compilation also
passed. Of those Vitest registrations, 45 exercise TypeScript types rather
than runtime behavior. The `.test-d.ts` fixtures add further compile assertions;
they are tracked separately from executable Dart cases. Exact conditional type
inference is not claimed where Dart has no corresponding language feature.
`tool/upstream_tests.json` records the exact cases and
`tool/upstream_api.json` records exports. These manifests are the comparison
baseline, not a claim that all Dart behavior already matches.

Current checkpoint results: [VALIDATION.md](VALIDATION.md).
Remaining work: [NEXT_STEPS.md](NEXT_STEPS.md).

## Verification commands

Run from the package directory:

```sh
dart pub get
dart analyze
dart test --reporter json > .dart_tool/tests.jsonl
dart run tool/verify_types.dart
dart run tool/parity_audit.dart .dart_tool/tests.jsonl .dart_tool/parity.json
dart test test/connections --platform chrome
dart run tool/verify_browser.dart
dart pub publish --dry-run
```

`verify_browser.dart` starts a temporary local HTTP server and tests actual
cross-origin XHR cookies, Arabic content, and cancellation in Chrome. It closes
the server afterward. Chrome must be installed. It does not contact production.
The ordinary transport tests also run in the Dart VM and with injected HTTP
clients, including cancellation before headers and durable stream replay.

`verify_types.dart` invokes the Dart analyzer on positive fixtures and checks
negative fixtures against `expect-error` markers. Those intentionally invalid
fixtures are excluded from ordinary package analysis. Dart generics and runtime
validation replace TypeScript conditional/mapped types where no literal Dart
translation exists. A runtime `runtimeType` equality is not a type-level check.

The parity audit consumes explicit per-case mappings and checks that the named
Dart test actually ran and passed. A title-only match remains an uncovered
review candidate. The mappings record the assertion review and any Dart
adaptation. Extra fixture cases, generated parser
prefixes, or repeated platform runs cannot substitute for missing upstream
behavior. Module mappings and actual test results should be considered together.

## Platform boundaries

The Dart SDK includes HTTP/SSE/NDJSON, websocket adapters, message processing,
chat/queue/history/interrupt logic, generation/video orchestration, persistence
contracts, BYOK, tool schemas, and devtools bridges. Server orchestration and
provider/model adapters from `@tanstack/ai` are outside the client-port scope.

Browser-only host capabilities (microphone/media recording, WebAuthn ceremonies,
MCP host messaging, WebMCP registration, browser storage) use explicit injected
platform interfaces. They require a platform implementation in the consuming
application. Missing hardware or host support reports unavailable; tests use
controlled host implementations. Passkey keyring cryptography itself is real
HKDF-SHA256/AES-GCM and is checked against a WebCrypto vector.

JavaScript `Response` is represented by `package:http`'s `StreamedResponse`;
`AsyncIterable` by Dart `Stream`. Extensible wire messages remain JSON maps.
Typed `AssistantTurn`/`AssistantPart` models preserve unknown wire fields.
The legacy transport remains a separate compatibility path for 0.42-era servers.

No package publication is implied by local test success or a publish dry run.
