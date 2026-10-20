# Checkpoint validation

Validated on 2026-10-21 with Dart 3.13.3 on macOS arm64. These checks ran from
this standalone repository, without the CRM checkout or production credentials.

| Check | Result |
| --- | --- |
| Dart VM suite | 2,406 passed, 0 failed, 1 known skip |
| Browser-compatible suites in Chrome | 1,680 passed, 0 failed, 1 known skip |
| Real browser HTTP/XHR checks | 2 passed: Arabic/cookies and pre-header abort |
| Static negative fixtures | 32 expected analyzer rejections verified; positive fixtures clean |
| `dart analyze` | No issues |
| `dart format --output=none --set-exit-if-changed lib test tool example` | Clean |
| `dart pub publish --dry-run` | Validation only; no publication authorized or performed |

## The known skip is a real failure

The generation result map mutation regression in
`test/interop/byok_snapshot_upstream_test.dart` was also executed with its skip
removed. It failed because assigning `published['id'] = 'mutated'` succeeded,
where the expected behavior is a read-only published snapshot. The quarantine
was restored, and the remaining work is described in `NEXT_STEPS.md`.

Do not describe the green suite as complete parity: one regression is explicitly
skipped, and TypeScript-only inference guarantees have documented adaptations.

## Upstream comparison

The pinned baseline contains 1,011 passing Vitest registrations, including 45
TypeScript type-assertion cases, plus separate `.test-d.ts` assertions.

The explicit mapping audit reports:

- 1,011 baseline registrations mapped; no unmapped or title-only entries.
- 967 cases linked to Dart tests that actually passed.
- One runtime case marked `not-implemented`: the generation snapshot regression.
- The remaining cases are tracked as static/language adaptations. Their mapping
  records describe the absent conditional/literal inference rather than claiming
  that runtime checks provide those compile-time guarantees.

See `validation/parity-summary.json` and the per-case mapping files under `test/`.
The audit intentionally exits nonzero while the known regression remains open.
`NEXT_STEPS.md` contains the continuation checklist and reproduction commands.

Browser hardware/host capabilities use injected interfaces. These tests do not
prove real microphone, WebAuthn, native storage, or MCP host integration. The
minimum advertised Dart SDK (3.6) has not yet been exercised.
