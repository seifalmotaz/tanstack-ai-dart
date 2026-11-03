# Troubleshooting

## The endpoint returns text but no assistant message

Confirm that the endpoint implements the supported TanStack client protocol.
A provider's raw token stream or an arbitrary JSON response is not a TanStack
chunk stream. Check the response status, streaming content type, terminal events,
and the transport factory. See [connections](connections.md).

## Awaiting send succeeds but the run has an error

Inspect `client.error` and `snapshot.error`. Network/model failures are represented
in state, so completion of the send future alone is not a success signal.
Configuration errors and invalid operations can throw. Keep cleanup in `finally`.

## Authentication works natively but fails in a browser

Review server CORS rules, cookies, credential mode, and allowed request headers.
Do not send a real bearer token in a bug report. The SDK cannot grant cross-origin
access that the server refuses. Use provider options for refreshed credentials.

## History or replay does not restore

Check the stable thread ID, persistence mode, and backend hydration/join support.
Construction alone does not restore history; call `attach()`. A memory store
cannot survive an application restart. Read [persistence](persistence.md).

## Sending is blocked by an interrupt

Resolve or cancel the actual pending approval/interrupt before sending a normal
message. Keep the original interrupt IDs and run context. Read
[tools and interrupts](tools-and-interrupts.md).

## A mutation throws UnsupportedError

Published state and typed part views are read-only. Use explicit client actions,
such as `setMessagesManually(...)`, instead of editing a snapshot. Copy data into
an application-owned model if it needs independent editing.

## Generation reports SnapshotCopyException

The output collection type cannot be copied without losing its reified Dart type.
Supply `copySnapshotResult` for that shape, including nested mutable collections.
The [generation guide](generation.md) includes a typed copier example.

## The compiler rejects an old example

Check that the example targets the Dart 0.3 API. Use named options, typed fetcher
results, and required connection modes. Read [MIGRATION.md](../MIGRATION.md).
Do not paste a TypeScript example directly into Dart.

## A platform capability is unavailable

Supply the required host implementation and permissions. Package interfaces and
mock-host tests do not install a microphone, WebAuthn service, socket, database,
or MCP host. See [platform support](platform-support.md).

## Report a remaining problem

Open a [GitHub issue](https://github.com/seifalmotaz/tanstack-ai-dart/issues) with
the Dart/package versions, platform, transport, sanitized stack trace, and a
minimal reproduction. State whether it reproduces against the pinned official
client. Keep private data, credentials, and production account access out of the
report.
