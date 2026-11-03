# Compatibility and verification

The Dart client targets `@tanstack/ai-client` 1.0.1 and `@tanstack/ai` 1.0.1
at [upstream commit `a7eb58459ebd528bbcc4166cc68377b777989462`](https://github.com/TanStack/ai/tree/a7eb58459ebd528bbcc4166cc68377b777989462).
The pinned official client suite passed 1,014 runtime registrations and its
separate TypeScript suite passed. Focused core protocol, stream and interrupt
suites passed 395 tests. The checked-in inventory and per-case mappings are
based on the executed report; the removed-case ledger preserves 39 old client
identities and nine removed core cases.

The latest Dart audit maps all 1,014 client registrations, with 971 linked to
passing Dart tests and zero unmapped cases, runtime gaps or orphan mappings.
The remaining registrations have documented static or other adaptations;
classification totals overlap and are not additional test counts. A passing
mapping shows that its named Dart test ran and passed, and should be read with
the assertion review and the stated limits in [API_COMPATIBILITY.md](API_COMPATIBILITY.md).
It is not a claim of identical JavaScript and Dart APIs or behavior on every
noncanonical input.

The Dart client deliberately does not execute an unbound client-tool interrupt.
The pinned upstream client does execute the same unsupported input while
exposing it as unbound. The checked-in probe and Dart regression demonstrate
both sides. Dart's `ChatInterrupt` uses a runtime kind rather than a statically
discriminated TypeScript union. The legacy `ChatTransport` path retains its
older call shape and is not evidence of compatibility with a 1.0 server.

Run the local checks from the package directory:

```sh
dart pub get
dart analyze
dart run tool/verify_platform_test_policy.dart
dart test --platform vm --reporter json > .dart_tool/tests.jsonl
dart run tool/verify_types.dart
dart run tool/parity_audit.dart .dart_tool/tests.jsonl .dart_tool/parity.json
dart test --platform chrome
dart run tool/verify_browser.dart
dart run tool/docs.dart check
dart pub publish --dry-run
```

The browser check uses a temporary local HTTP server and actual Chrome XHR;
it makes no production requests. Hardware and host interfaces require injected
platform implementations. Server orchestration, providers, server middleware
and command execution are outside the client port. See [VALIDATION.md](VALIDATION.md)
for the executed checks and [MIGRATION.md](MIGRATION.md) for breaking changes.
