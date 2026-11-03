# Update the port from TypeScript

Use this procedure when the official [TanStack AI repository](https://github.com/TanStack/ai)
changes. An npm release or new commit is a review candidate, not an automatic
compatibility upgrade. The Dart package version and upstream npm versions are
separate.

The checked-in [test inventory](../../tool/upstream_tests.json),
[export inventory](../../tool/upstream_api.json), and
[compatibility records](../../tool/upstream_api_compatibility.json) identify the
current baseline. The README's generated table displays that pin.

## 1. Capture an immutable candidate

Use an isolated checkout. On the first review:

```sh
mkdir -p .dart_tool
git clone https://github.com/TanStack/ai.git .dart_tool/upstream-ai
```

On subsequent reviews, inspect the checkout and stop if it contains work you
need to preserve. From the Dart package root:

```sh
test -z "$(git -C .dart_tool/upstream-ai status --porcelain)" || exit 1
git -C .dart_tool/upstream-ai fetch origin
upstream_candidate=$(git -C .dart_tool/upstream-ai rev-parse origin/main)
printf '%s\n' "$upstream_candidate"
git -C .dart_tool/upstream-ai checkout --detach "$upstream_candidate"
```

To target a release instead, fetch its tag and resolve that tag to a full commit
SHA before checkout. Record both the tag and SHA. Do not assume the current npm
dist-tag and the current `main` branch point to the same source.

Read `.nvmrc`, `package.json`'s `packageManager`, and `CONTRIBUTING.md` at the
candidate. Install the Node/pnpm versions that candidate specifies. Do not reuse
an old guide's toolchain versions without checking them.

## 2. Review the changed surface

With Node available, obtain the current pin from the Dart repository's manifest:

```sh
upstream_baseline=$(node -p "require('./tool/upstream_api.json').commit")
git -C .dart_tool/upstream-ai diff --stat "$upstream_baseline" "$upstream_candidate"
git -C .dart_tool/upstream-ai diff "$upstream_baseline" "$upstream_candidate" -- packages/ai-client/src packages/ai-client/tests packages/ai/src packages/ai-event-client packages/ai-utils
```

Read relevant changes rather than limiting the review to version numbers.
Include dependency/protocol changes outside `ai-client` when they alter client
behavior. Server provider implementations remain outside this Dart client's
scope, but their wire/protocol changes may affect it.

Record added, removed, and renamed exports and test cases. Review source files
and declarations behind re-exports, including `src/index.ts`, `src/byok.ts`, and
`src/ui.ts`. Explain whether removed upstream functionality should remain as a
Dart compatibility path or requires a breaking migration.

## 3. Run the official checks

From the isolated upstream checkout, follow that candidate's contributing guide.
For the currently pinned repository, the relevant commands are:

```sh
cd .dart_tool/upstream-ai
pnpm install --frozen-lockfile
pnpm run build:all
mkdir -p .dart_tool
pnpm --filter @tanstack/ai-client test:lib --run --reporter=json --outputFile=../../.dart_tool/ai-client-vitest.json
pnpm --filter @tanstack/ai-client test:types
cd ../..
```

For the 0.40.0 to 1.0.1 comparison, pass the archived baseline explicitly
when collecting or classifying the executed candidate report:

```sh
node tool/collect_upstream_inventory.cjs .dart_tool/upstream-ai .dart_tool/upstream-ai/.dart_tool/ai-client-vitest.json tool/upstream_tests_0_40_0.json > .dart_tool/candidate-inventory.json
node tool/review_upstream_mechanical.cjs .dart_tool/upstream-ai .dart_tool/candidate-inventory.json tool/upstream_tests_0_40_0.json > .dart_tool/mechanical-review.json
node tool/prepare_candidate_audit.cjs .dart_tool/candidate-inventory.json .dart_tool/candidate-audit
```

The preparer writes only to an owned child of `.dart_tool`. Run the parity
audit from that directory against a VM JSON report. Its provisional results
are review evidence and do not automatically update the supported manifests.

The report path is relative to `packages/ai-client`, so the JSON report lands in
`.dart_tool/upstream-ai/.dart_tool/ai-client-vitest.json`. Confirm the file exists
and the commands passed. If candidate scripts or configuration changed, adjust
the commands using that source and record the commands actually executed.

Run relevant protocol/dependency tests too when the reviewed change reaches
those packages. Keep Vitest runtime registrations, Vitest type assertions, and
separate `.test-d.ts` declarations distinct. Record failures and skips rather
than treating a partial upstream run as a new passing baseline.

To reproduce the mixed server/client tool stream fixture at the pinned 1.0.1
candidate, from the Dart package root with the candidate's Node and pnpm on
`PATH` and its dependencies installed:

```sh
cp tool/capture_upstream_mixed.test.ts .dart_tool/upstream-ai/.dart_tool/capture-mixed.test.ts
cp tool/capture_upstream_mixed.config.mts .dart_tool/upstream-ai/.dart_tool/capture.config.mts
(cd .dart_tool/upstream-ai && pnpm exec vitest --run --config .dart_tool/capture.config.mts)
node tool/verify_upstream_mixed.cjs .dart_tool/upstream-ai/.dart_tool/mixed-chunks.json
```

To reproduce the separate unbound-interrupt behavior probe, copy
`tool/probe_upstream_unbound.test.ts` to the same `capture-mixed.test.ts` path
and run the same Vitest command. It is outside the official suite inventory.

To reproduce the captured child-agent approval streams, run:

```sh
node tool/capture_upstream_subagent.cjs
cp tool/capture_upstream_subagent.config.mts .dart_tool/upstream-ai/.dart_tool/capture-subagent.config.mts
(cd .dart_tool/upstream-ai && pnpm exec vitest --run --config .dart_tool/capture-subagent.config.mts)
node tool/verify_upstream_subagent.cjs .dart_tool/upstream-ai/.dart_tool/subagent-chunks.json
```

The upstream integration test itself checks server tool execution. The Dart test
replays its normalized wire chunks and checks approval, continuation and child
card state; it does not run a Dart server.

The comparison normalizes generated identifiers, timestamps, and creation
dates; the fixture retains the remaining upstream event content. These files
stay under the upstream checkout's ignored `.dart_tool`, outside its sources
and normal test inventory.

## 4. Port behavior and update evidence

1. Add or adapt a Dart regression for each changed client behavior.
2. Implement the change using the Dart API's existing types and conventions.
3. Preserve unknown wire fields, cancellation, replay, persistence, and
   approval/interrupt ordering where the upstream contract requires them.
4. Update each affected case mapping with reviewed assertions and the real Dart
   test name. Add analyzer fixtures for representable static guarantees.
5. Describe adaptations and unsupported language/host behavior honestly.

The candidate collector reads the executed Vitest report and source exports.
It requires TypeScript 5.9.3 in an isolated local toolchain:

```sh
npm install --prefix .dart_tool/toolchain typescript@5.9.3
node tool/collect_upstream_inventory_test.cjs
node tool/collect_upstream_inventory.cjs .dart_tool/upstream-ai .dart_tool/upstream-ai/.dart_tool/ai-client-vitest.json > .dart_tool/candidate-inventory.json
```

It reports added and removed identities, flags retained cases in changed files,
and compares literal test bodies where it can resolve them. Dynamic or
ambiguous cases remain unresolved; matching bodies still require review of
their surrounding fixtures. This output is a review aid, not proof of Dart
coverage; `parity_audit.dart` consumes the separately reviewed inventories and
mappings. Review re-export declarations and case bodies before advancing them.

Do not silently discard renamed or deleted cases. Record the change in the PR
and changelog. Keep gaps explicit. If the port is incomplete, retain the old
supported baseline and open a draft/partial update rather than publish a claim
for the candidate.

## 5. Advance the pin in one reviewed change

Once relevant behavior is implemented and tested, update together:

- The commit and package versions in both upstream inventories and compatibility
  records. Read npm versions from the candidate's package files.
- The relevant mapping JSON, declared fixture/source hashes, and type fixtures.
- `API_COMPATIBILITY.md`, the aggregate `validation/parity-summary.json`, and
  `VALIDATION.md` with actual evidence. Copy aggregate values from the new audit
  report; do not label historical results as a fresh run.
- `PARITY.md`, `CHANGELOG.md`, and `MIGRATION.md` where behavior or public usage changed.
- `THIRD_PARTY_NOTICES` when adapted source attribution changes.

Run the [contribution checks](../../CONTRIBUTING.md#verify-a-change), including
minimum/stable SDK CI, Chrome, static fixtures, and the mapping audit. Then run:

```sh
dart run tool/docs.dart generate
dart run tool/docs.dart check
```

The docs check rejects mismatched manifest pins and stale generated compatibility
or LLM content. It does not prove behavioral parity on its own.

## 6. Request review and release separately

Include old/candidate SHAs, npm versions, changed exports/cases, assertion
reviews, actual test commands/results, and any remaining adaptations in the PR.
Changes to the pin require the same review as runtime changes. Test totals or
matching names cannot replace evidence.

Merge the reviewed port before preparing a release using the
[release guide](releasing.md). This procedure changes no upstream repository,
creates no scheduled update bot, and does not publish to pub.dev.
