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

The report path is relative to `packages/ai-client`, so the JSON report lands in
`.dart_tool/upstream-ai/.dart_tool/ai-client-vitest.json`. Confirm the file exists
and the commands passed. If candidate scripts or configuration changed, adjust
the commands using that source and record the commands actually executed.

Run relevant protocol/dependency tests too when the reviewed change reaches
those packages. Keep Vitest runtime registrations, Vitest type assertions, and
separate `.test-d.ts` declarations distinct. Record failures and skips rather
than treating a partial upstream run as a new passing baseline.

## 4. Port behavior and update evidence

1. Add or adapt a Dart regression for each changed client behavior.
2. Implement the change using the Dart API's existing types and conventions.
3. Preserve unknown wire fields, cancellation, replay, persistence, and
   approval/interrupt ordering where the upstream contract requires them.
4. Update each affected case mapping with reviewed assertions and the real Dart
   test name. Add analyzer fixtures for representable static guarantees.
5. Describe adaptations and unsupported language/host behavior honestly.

There is no checked-in upstream inventory collector today. Review exports and
executed test results to update `tool/upstream_api.json` and
`tool/upstream_tests.json`. Do not invent a collector command or use
`parity_audit.dart` as one; the audit consumes those inventories and mappings.
A future collector must preserve test identity and prove its output against
actual source/results before replacing this manual step.

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
