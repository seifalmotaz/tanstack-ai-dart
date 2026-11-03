# Platform support and application responsibilities

The core SDK uses Dart and has no Flutter dependency. Platform-specific features
are injected interfaces rather than bundled Flutter plugins.

| Feature | SDK responsibility | Application responsibility |
| --- | --- | --- |
| Chat, queues, interrupts, and generation | State and protocol processing | Endpoint, credentials, rendering |
| HTTP streaming | SSE, NDJSON, polling, cancellation | Backend and browser CORS policy |
| WebSocket | Run/message handling and reconnection | `WebSocketFactory` implementation |
| Conversation storage | Storage record and lifecycle contracts | Browser or device store implementation |
| Audio recording | Recorder interface and output conversion | Microphone permissions and media host |
| Realtime sessions | Session state and event handling | Realtime connection and media host |
| BYOK | Keyring contracts, headers, and crypto | Key-entry UI, storage, server policy |
| Passkeys | Keyring cryptography and host interface | WebAuthn ceremony and credential storage |
| MCP and WebMCP | Tool/bridge interfaces | Actual host messaging and registration |
| Devtools | Bridge contracts and snapshots | Panel or host integration |

[Validation evidence](../VALIDATION.md) distinguishes controlled-host tests from
real hardware verification. Missing host support is reported as unavailable or
unsupported by the relevant capability. An interface existing in the package
does not mean a device integration is installed.

## Use the SDK from Flutter

Create a chat client outside widget `build()`. Bind its `states` stream to a
`StreamBuilder<ChatSnapshot>` or the app's existing state-management system.
Use `client.snapshot` for the initial UI. Attach when its owner becomes active,
and release subscriptions and the client when ownership ends.

Flutter `State.dispose()` is synchronous. Handle chat's asynchronous cleanup
through your app's lifecycle rather than declaring an async override. Generation
and video disposal are synchronous. The package provides no UI widgets,
authentication screens, navigation, or permission dialogs.

## Choose credentials and BYOK deliberately

Ordinary backend authentication belongs in connection headers or an options
provider. Read [connections and authentication](connections.md).

For bring-your-own-key integrations, `defineByok` creates a keyring client.
Pass that client through the chat/generation `byok` option and select a provider
with `byokProvider` when needed. Prepared provider keys are forwarded in BYOK
headers for the active operation, not inserted into message text or JSON bodies.
The backend must understand those headers and enforce its own provider policy.

Memory key storage is not durable secure device storage. Supply the required
storage/passkey host for persistence and show the SDK's missing/locked prompt
state in your UI. Never put real keys in examples, issue reports, or application
logs. No provider account or endpoint is bundled with this package.

## Review the public libraries

Use the [API reference map](api-reference.md) to choose an import. Domain imports
can keep application dependencies explicit. Browser storage names do not imply
that `dart:io` implements browser APIs, and XHR factory names do not imply an
`XMLHttpRequest` instance exists on native platforms.
