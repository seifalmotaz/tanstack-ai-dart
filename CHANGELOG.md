## 0.3.0

- Add public usage guides, generated LLM references, contribution rules, and a
  reviewed upstream-update/release procedure with documentation checks.

- Make typed named configuration the default chat/generation API; retain explicit
  `legacy` entry points for previous call signatures.
- Add state streams with an initial snapshot per listener, typed lifecycle enums,
  read-only transcripts, typed message input and configuration setters.
- Split static connection factories from async providers; enforce valid connection
  modes and explicit fetcher response variants through Dart types.
- Add immutable sealed message-part views with unknown-field preservation.
- Make tool schema parameters typed; replace approval reflection/side tables with
  a real field and prefer ordinary Dart tool lists.
- Add API rejection fixtures and modern client flow tests. Suppress analytics in
  analyzer subprocess checks so those checks do not depend on telemetry services.
- Update the runnable example and add MIGRATION.md for breaking API changes.

## 0.2.0

- Freeze published generation and video snapshots, preserving internal results,
  nested data, aliases, cycles and unchanged snapshot identity.
- Add `copySnapshotResult` for other typed collection shapes and report
  `SnapshotCopyException` instead of exposing mutable snapshot aliases.
- Remove the quarantined generation snapshot regression.
- Add public-export compatibility records, minimum/stable Dart CI and Chrome
  test coverage. See VALIDATION.md for the exact checks.

- Expand the client toward `@tanstack/ai-client` 0.40.0 / `@tanstack/ai` 0.70.0.
- Add connection adapters, shared stream processing, client tools, interrupts,
  queue/history support, generation/video clients, BYOK, persistence contracts,
  platform seams, and devtools bridges.
- Preserve modern message fields and distinguish absent and null tool outputs.
- Add WebCrypto-compatible keyring encryption and real HTTP/Chrome checks.
- Pin the upstream API/test inventory and add static analyzer fixture checks.
  See PARITY.md for verification status and scope.
- Keep the original legacy transport and approval helpers available.

## 0.1.0

- Initial extraction from the ZACRM mobile assistant.
- Pure-Dart protocol models: `AssistantApproval`, `AssistantPart`,
  `AssistantTurn`, and `AssistantStreamReducer`.
- Legacy wire helpers: `assistantWireMessages`, `assistantApprovalPayload`,
  `assistantChatBody`, `assistantTurnsFromThread`,
  `generateAssistantThreadTitle`.
- `SseChatTransport` with incremental UTF-8/CRLF/lone-CR/BOM/multiline SSE
  parsing, single 401 refresh, typed HTTP errors, and prompt cancellation.
- `RUN_FINISHED` is forwarded without closing; the stream completes on
  `[DONE]`, EOF, or `RUN_ERROR`, preserving all model iterations.
- Optional `ChatClient` for send / stop / approval continuation.
- Tested against the legacy `@tanstack/ai` ^0.42.0 and
  `@tanstack/ai-react` ^0.18.1 parts + tool-result approval protocol.

- Send UI-message parts so approval IDs survive TanStack server extraction; omit absent output fields.
- Prevent repeated approval decisions and implicit replay of interrupted approved calls.
- Verified against the official 0.42.0 message converter and a production TanStack endpoint.
