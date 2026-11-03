# Contributing

Contributions to the Dart client are welcome. Start with a small reproduction or
a focused proposal in [GitHub issues](https://github.com/seifalmotaz/tanstack-ai-dart/issues).
Search existing issues and pull requests before starting overlapping work.

## Keep the API idiomatic Dart

Preserve the official client's behavior and wire protocol while using Dart
constructors, named parameters, enums, sealed types, and streams. Avoid untyped
unions or inference wrappers added only to reproduce JavaScript syntax.
Keep unknown JSON fields intact and update public imports when adding an API.

The supported upstream revision comes from
[upstream_api.json](tool/upstream_api.json),
[upstream_tests.json](tool/upstream_tests.json), and
[compatibility records](tool/upstream_api_compatibility.json). The Dart release
version is independent of the npm versions. Read
[the upstream update procedure](doc/maintainers/upstream-updates.md) before
changing a baseline.

## Set up

You need Git, Dart at the minimum version in [pubspec.yaml](pubspec.yaml), and
Chrome for browser tests. Ordinary SDK work does not require Node, pnpm, or model
provider credentials. Node and pnpm are needed only when running the official
TypeScript project for an upstream comparison.

```sh
git clone https://github.com/seifalmotaz/tanstack-ai-dart.git
cd tanstack-ai-dart
dart pub get
```

## Verify a change

Run focused tests while developing. Before requesting review, run the relevant
checks below and state which commands you actually executed:

```sh
dart format --output=none --set-exit-if-changed lib test tool example
dart analyze
dart run tool/verify_platform_test_policy.dart
dart test --platform vm --reporter json > .dart_tool/tests.jsonl
dart run tool/verify_types.dart
dart run tool/parity_audit.dart .dart_tool/tests.jsonl .dart_tool/parity.json
dart test --platform chrome
dart run tool/verify_browser.dart
dart run tool/docs.dart check
```

CI tests the minimum and stable Dart SDKs on the VM. Browser checks run on
stable. `verify_browser.dart` uses a local HTTP server, not production.
Tests that import `dart:io` must declare `@TestOn('vm')`.

Positive and negative analyzer fixtures live under `test/types`. Negative files
are intentionally invalid, excluded from normal analysis, and verified by
`tool/verify_types.dart`. Add one when an API promises a new static guarantee.

## Preserve behavioral evidence

For a bug, add a deterministic regression test that fails before the fix.
For an upstream case, keep its identity in the appropriate mapping JSON and
review its assertions against the pinned source.

A runtime mapping must name a Dart test that ran and passed. Test counts and
matching titles are not proof. Record language adaptations separately, with real
analyzer fixtures where Dart enforces a contract statically. Keep unimplemented
behavior visible instead of changing its status to make an audit green.

Use local fixtures and controlled hosts. Sanitize bug reports and avoid live
provider calls, customer data, or credentials in tests and logs.

## Update documentation and examples

Start at [doc/README.md](doc/README.md). Edit Dart examples under `example/`,
then refresh the generated documentation:

```sh
dart run tool/docs.dart generate
dart run tool/docs.dart check
```

Only marked snippet/compatibility blocks and `llms.txt`/`llms-full.txt` are
generated. Edit the surrounding Markdown normally. Register a new guide in
`tool/docs.dart` and link it from `doc/README.md`. The check command validates
inline local link targets and generated content; it does not test remote websites.

For API changes, update examples, public compatibility records, type fixtures,
`CHANGELOG.md`, and affected guides. Add migration instructions when callers must
change usage. Change upstream inventories only when reviewing a new upstream
baseline, not to describe a Dart-only API refactor.

## Submit a pull request

Keep one change or closely related set of changes per PR. Explain the resulting
behavior, include the reproduction or motivation, and report executed checks and
remaining limits. Use the [PR template](.github/PULL_REQUEST_TEMPLATE.md).

AI assistance is welcome. Contributors remain responsible for understanding,
reviewing, and verifying submitted work. Describe material AI assistance in the
PR, and do not submit unreviewed bulk changes.

The project uses the [MIT license](LICENSE). Preserve upstream attribution in
[THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES) when adapting code or tests.
Maintainers review releases using the [release guide](doc/maintainers/releasing.md).
