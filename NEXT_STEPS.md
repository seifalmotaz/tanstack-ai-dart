# Release and integration checklist

The client SDK implementation and pinned upstream mapping are complete within
the Dart/platform boundaries in [API_COMPATIBILITY.md](API_COMPATIBILITY.md).
The snapshot regression and Dart API revision are implemented; minimum/stable
SDK checks, migration documentation and CI are included.
See [VALIDATION.md](VALIDATION.md) for executed checks.

Use the [maintainer release guide](doc/maintainers/releasing.md) for the full
procedure. Before a public pub.dev release:

- Review the package name/version and publication ownership.
- Run `dart pub publish --dry-run` from the final release commit.
- Publish only with explicit release authorization.

For consuming applications:

- Supply platform implementations for audio, WebAuthn, storage, WebSocket and
  MCP host capabilities that the application uses; verify them on real devices.
- Migrate pre-0.3 call sites using [MIGRATION.md](MIGRATION.md).
- Use an explicit `copySnapshotResult` for generation output collection types
  outside JSON containers/scalar collections.
- Treat caller context as an application model; Dart does not infer TypeScript
  context intersections or schema-derived literal types.

Follow the [upstream update guide](doc/maintainers/upstream-updates.md) to
refresh pinned manifests, review changed assertions, and rerun the mapping audit. Server provider adapters from
`@tanstack/ai` and the PinCRM application are outside this repository's scope.
