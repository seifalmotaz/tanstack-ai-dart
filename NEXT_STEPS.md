# Continue next week

This is a draft checkpoint, not a claim of complete TanStack parity or a pub.dev
release. The baseline is `@tanstack/ai-client` 0.40.0 / `@tanstack/ai` 0.70.0,
commit `7095ebbf1b59175f0cd339c1c477d6af55b312de`.

## 1. Fix mutable generation result snapshots

- [ ] Enable and fix the skipped `GenerationClient notifies subscribe and keeps
  getSnapshot identity until a change` regression in
  `test/interop/byok_snapshot_upstream_test.dart`.
- [ ] Publish read-only copies of plain Map/List generation results, preserving
  internal `getResult()` values and unchanged snapshot identity.
- [ ] Cover generic collection types (`Map<String, int>`, `List<int>`), nested
  containers and opaque custom result objects. Avoid casts that break callers
  whose output type is narrower than `Map<String, dynamic>`.
- [ ] Review the same result path in `VideoGenerationClient`.
- [ ] Update the corresponding mapping from `not-implemented` only after the
  faithful mutation assertion passes. An immutable test model is not a substitute
  for checking mutable JSON payloads.

Files: `lib/src/generation/generation_client.dart`,
`lib/src/generation/video_generation_client.dart`,
`lib/src/platform/snapshot_atom.dart`.

## 2. Settle the Dart typing contract

- [ ] Review every `not-representable` and static adaptation in the mapping JSON
  files. Literal tool-name unions, heterogeneous tuple inference, conditional
  approval fields and schema-derived message types have no direct Dart equivalent.
- [ ] Decide the explicit typed API for caller context. It is currently `Object?`;
  context requirements/intersections are not inferred from registered tools.
- [ ] Strengthen typed activity payloads and interrupt/schema-derived views where
  practical, without pretending runtime checks are compile-time guarantees.
- [ ] Audit the public export inventory in `tool/upstream_api.json` and document
  each renamed, adapted or intentionally unsupported type.

Existing tools retain `ClientTool<TInput, TOutput>` generics; `ui.dart` provides
explicit typed selectors. Negative analyzer fixtures are checked by
`tool/verify_types.dart`.

## 3. Verify the public package independently

- [ ] Review per-case assertions against the pinned upstream source, especially
  entries that combine cases or adapt stream cancellation/JS object semantics.
- [ ] Run the full checks below after the snapshot fix. Keep the one known skip
  visible until it is fixed; do not infer parity from the raw Dart test count.
- [ ] Test the advertised minimum Dart SDK (3.6); current local checks use Dart
  3.13.3. Add CI for the minimum/stable SDKs, analyzer fixtures and Chrome.
- [ ] Verify real host bindings/examples for browser/native audio, WebAuthn,
  WebMCP/MCP and browser storage. These capabilities currently use injected host
  interfaces; mock-host tests do not prove device support.
- [ ] Review documentation/examples, licensing and package metadata; choose a
  release version and run `dart pub publish --dry-run` again before pub.dev.

```sh
dart pub get
dart format --output=none --set-exit-if-changed lib test tool example
dart analyze
dart test --reporter json > .dart_tool/tests.jsonl
dart run tool/verify_types.dart
dart run tool/parity_audit.dart .dart_tool/tests.jsonl .dart_tool/parity.json
# The parity audit intentionally exits nonzero while the snapshot gap remains.
dart run tool/verify_browser.dart
dart pub publish --dry-run
```

`VALIDATION.md` records this checkpoint's actual results. `PARITY.md` explains
scope and language/platform boundaries. Server provider adapters from
`@tanstack/ai` and the PinCRM application are outside this repository.
