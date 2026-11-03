# Documentation

Start with [getting started](getting-started.md), then choose the guide for your
feature. The [package README](../README.md) contains the shortest chat example.

## Application guides

- [Chat and rendering](chat.md): lifecycle, streams, queues, cancellation, and parts.
- [Connections and authentication](connections.md): transports, credentials, and custom fetchers.
- [Persistence and resume](persistence.md): server history and application storage.
- [Tools and interrupts](tools-and-interrupts.md): validation, execution, and approval.
- [Generation](generation.md): typed results, video, and immutable snapshots.
- [Platform support](platform-support.md): Flutter integration and host implementations.
- [API reference map](api-reference.md): public libraries and their entry points.
- [Troubleshooting](troubleshooting.md): common setup and runtime problems.

## Compatibility and maintenance

- [Migration to 0.3](../MIGRATION.md).
- [API compatibility](../API_COMPATIBILITY.md) and [parity methodology](../PARITY.md).
- [Executed validation](../VALIDATION.md).
- [Contribution rules](../CONTRIBUTING.md).
- [Update from official TypeScript changes](maintainers/upstream-updates.md).
- [Prepare a public release](maintainers/releasing.md).

## Edit these docs

Dart examples are extracted from analyzed files under `example/`. Edit the source
example, then run:

```sh
dart run tool/docs.dart generate
dart run tool/docs.dart check
```

The generator refreshes snippet blocks, the compatibility table, `llms.txt`, and
`llms-full.txt`. The check command rejects stale generated content, missing inline local
link targets, and untracked Dart snippets in the new application guides. It does
not verify remote websites or execute requests in examples.
