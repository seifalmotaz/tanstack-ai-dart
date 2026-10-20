## Unreleased

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
