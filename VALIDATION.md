# Validation

The 0.4.0 working tree was validated on 2026-11-03 on macOS arm64. It targets
`@tanstack/ai-client` and `@tanstack/ai` 1.0.1 at commit
`a7eb58459ebd528bbcc4166cc68377b777989462`. This records local validation of the 0.4.0 source candidate; GitHub CI and
release status are tracked separately.

| Check | Result |
| --- | --- |
| Dart 3.13.3 VM | 2,493 visible tests passed; no failures or skips |
| Dart 3.6.2 VM | 2,493 visible tests passed; no failures or skips |
| Chrome, Dart 3.13.3 | 1,754 visible tests passed; no failures or skips |
| Static analyzer fixtures | 61 rejection assertions checked on both SDKs; positive fixtures passed |
| Package analyzer | No issues on both SDKs |
| Formatter and platform test policy | Passed |
| Real Chrome HTTP checks | 2 passed: streaming/credentials and abort before headers |
| Documentation generation/check | Passed; 20 source pages |
| Dartdoc | 9 public libraries, zero warnings or errors |

Counts exclude hidden test-loader events. The minimum-SDK run used an isolated
copy refreshed with `rsync -a --delete` for the owned source/test/tool/doc
folders, its own package configuration, Dart 3.6.2 and a separate pub cache.
The stable and minimum JSON reports, full Chrome report and parity report were
produced with `dart test -r json` and `dart run tool/parity_audit.dart`.

The official 1.0.1 client runtime suite passed 1,014 registrations with no
failures or skips; its separate TypeScript suite passed. Focused core tests passed
38 interrupt/wire cases and 357 stream, subagent, protocol, resume and request
parameter cases. The published npm source files were compared to the pinned
checkout: all 35 client and 168 core source files matched. See
[upstream-1.0.1-review.md](validation/upstream-1.0.1-review.md) for the
identity delta and review method.

The Dart audit maps all 1,014 client registrations: 971 have a passing Dart
runtime test, 43 are classified non-runtime, and there are no unmapped cases,
runtime gaps or orphan mappings. Its 46 compile mappings, 177 adaptation
entries and 25 nonrepresentable entries can overlap and are not extra test
counts. [parity-summary.json](validation/parity-summary.json) records the
machine-readable result. The API inventory covers 276 slots across the root,
BYOK, UI and devtools paths; [API_COMPATIBILITY.md](API_COMPATIBILITY.md)
describes the boundaries.

The pre-commit `dart pub publish --dry-run` exited 65 with two warnings: the intentionally
uncommitted modified tree and the tracked, deleted
`test/connections/sse_done_model_test.dart` being ignored while still tracked by
Git. The archive inspection found the archived prior inventory and review tools
needed to reproduce the comparison; no production data or credentials were
used. Re-run the dry run after an authorized commit removes that tracked file.

Dart deliberately does not automatically execute a client tool for an unbound
interrupt; a separate upstream probe confirms that the pinned JavaScript client
does. Dart's immutable `ChatInterrupt` uses a runtime kind rather than a
statically discriminated TypeScript union. Native XHR handler teardown is not
directly observable through the injected-client cleanup test. Microphone,
WebAuthn, device storage and real MCP/WebMCP host integration were not tested;
websocket use requires an injected platform implementation.
