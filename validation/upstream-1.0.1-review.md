# Upstream 1.0.1 review

The supported inventory targets `@tanstack/ai-client@1.0.1` and `@tanstack/ai@1.0.1`, both at
`a7eb58459ebd528bbcc4166cc68377b777989462`; the prior source is
`7095ebbf1b59175f0cd339c1c477d6af55b312de`.

With Node 24.8.0 and pnpm 11.9.0, the filtered client and workspace dependency
build passed. The official client runtime report contains 1,014 passing cases,
no failures or skips; its TypeScript check passed. Selected core interrupt and
wire-normalization tests passed 38 cases; separate stream processor, subagent,
stream chunk, interrupt resume, chat parameters, and generation parameters
suites passed 357 cases. These results are upstream evidence, not Dart parity.
The published 1.0.1 npm source was independently compared against the pinned
checkout: 35 client and 168 core source files were byte-identical.

The candidate collector compares case identities against the previous inventory:
972 retained, 42 added, 39 removed. Its `sourceReview` reports 384 retained
literal test bodies changed, 283 text-identical, and 71 unresolved in changed
files. An unchanged test body can still have changed setup or helpers. The mapping review also considered changed setup and shared helpers.
`tool/upstream_removed_cases.json` records removed case identities separately.

The candidate client index adds `ChatHydrateOptions` and `ChatHydrationResult`
and removes its re-exports of `RealtimeAdapter` and `RealtimeConnection`.
The latter types remain in Dart's platform layer because its realtime client
uses them; this is a Dart-specific surface, not a claim they remain upstream
client exports. The previous inventory omitted the `devtools` entry point; the
collector now inventories its 29 declarations for individual review.
Four declarations use Dart names with an `AIDevtools` prefix:
`GenerationDevtoolsCoreState`, `GenerationRunPatch`, `VideoDevtoolsCoreState`,
and `VideoRunPatch` correspond to `AIDevtoolsGenerationCoreState`,
`AIDevtoolsGenerationRunPatch`, `AIDevtoolsVideoCoreState`, and
`AIDevtoolsVideoRunPatch`, respectively. Bridge options and `upsertRun` use
those typed values directly; no additional aliases are needed for callers.

The new tests exercise identity, hydration, persistence protection, stream
input, reconnects, interrupt ownership and child approval. The separate
upstream probe confirms that upstream executes an unbound client-tool
interrupt while Dart deliberately does not. See [API_COMPATIBILITY.md](../API_COMPATIBILITY.md)
for that boundary and the statically different interrupt representation.

The 71 dynamically named retained registrations in changed files were reviewed
by family: 42 generation cases add the required constructor identity; 14 cleanup
cases add run context to the shared stream factory (the obsolete DONE case is
in the removal ledger); four SSE cleanup cases add generation identity; two
reasoning rejoin cases retain text/activity variants after step signature was
removed; and two persistence cases use the typed combined async store. Seven
interrupt cases comprise three malformed V2 hydration fixtures adding identity
and four Stop timing cases changing the tool-input CUSTOM event to a bound
1.0 interrupt. The Dart Stop fixture now uses that 1.0 event shape. These
source-family observations do not by themselves verify each Dart mapping.

A subsequent AST/token comparison classifies 284 changed literal bodies as
constructor identity additions only and 47 as required run-context additions
(with existing identity values preserved); 53 remain outside those mechanical
classes. Manual review of the remaining families found renamed interrupt
getters, removed wire aliases, combined persistence records, stricter thread and
run context, and per-send body forwarding changes. It uncovered several weak
older Dart mappings, which now use modern connection streams for queueing,
context updates, unsafe resume, run ownership, and the captured child approval.
The changed server-side assertions are not assumed to pass merely because an
old Dart test name exists. The promoted audit prunes old entries only through
`tool/upstream_removed_cases.json`. Current counts and the final platform matrix
are in [VALIDATION.md](../VALIDATION.md); compile-only and other classified
adaptations are counted separately.
