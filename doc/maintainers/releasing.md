# Release the Dart package

This guide is for maintainers publishing a reviewed Dart release. It does not
publish anything automatically. GitHub source releases and pub.dev publication
are separate steps.

## Prepare the release commit

1. Finish the intended changes and review CI on the exact commit to release.
2. Set the Dart version in `pubspec.yaml` and document changes in `CHANGELOG.md`.
   Do not copy an npm version number into the Dart package version.
3. Review examples and migration instructions for public API changes.
4. Check the upstream pin against the inventories and compatibility records.
   Use the [upstream procedure](upstream-updates.md) if the supported source changed.
5. Preserve [LICENSE](../../LICENSE) and
   [THIRD_PARTY_NOTICES](../../THIRD_PARTY_NOTICES).

Run the applicable checks in [CONTRIBUTING.md](../../CONTRIBUTING.md), then:

```sh
dart run tool/docs.dart generate
dart run tool/docs.dart check
dart doc
dart pub publish --dry-run
```

Keep installation instructions specific to the target release and regenerate
LLM references when they change. Avoid time-sensitive publication claims in an
archive that cannot be edited later. Announce hosted availability only after
publication has been confirmed.

Review the archive listing and warnings. Generated documentation, examples,
license/notice files, and public guides should be included as intended. Local
caches, fixtures with private data, and SDK downloads must stay out of the
archive. Confirm a clean working tree before the final dry run.

`VALIDATION.md` records executed evidence and untested host boundaries. A build,
HTTP status, or successful dry run does not prove real hardware integration or
that publication has occurred.

## Choose a Dart version

Use patch releases for compatible fixes and documentation corrections. Use minor
releases for compatible additions. Before 1.0, put breaking API or backend
protocol requirements in the next minor release and provide migration notes.
After 1.0, use a major release for breaking changes. An upstream pin advance is
not automatically a breaking Dart change; review both the API and wire contract.

## Publish manually

For the first release, confirm package-name availability and the intended
pub.dev publisher/ownership. A maintainer with the appropriate publishing access
must approve and perform the release. CI does not publish packages.

From the reviewed clean release commit:

```sh
dart pub publish
```

Confirm the version, archive, license, and repository link on pub.dev. Only after
that confirmation should release announcements claim hosted availability.

## Create a GitHub source release

A GitHub source release can precede publication to pub.dev. Keep those statuses
separate in the README and release notes. Verify all CI checks on the immutable
source commit before creating its tag. Write reviewed release notes to
`.dart_tool/release-notes.md`, and set `release_commit` to that verified SHA.
For the first source release:

```sh
release_tag=v0.3.0
test -n "$release_commit" || exit 1
git tag -a "$release_tag" "$release_commit" -m "tanstack_ai_dart $release_tag"
git push origin "refs/tags/$release_tag"
gh release create "$release_tag" llms.txt llms-full.txt --verify-tag --title "$release_tag" --notes-file .dart_tool/release-notes.md --latest
```

If a tag already exists, verify its target instead of overwriting it. Derive attached files from that exact source revision.
For versioned LLM copies, rebase only this repository's GitHub/raw URL references
from `main` to the release tag; preserve examples and compatibility data. Include
checksums for attached files. A release's LLM text provides a versioned
reference alongside GitHub's automatic source archives.

## Record the release

When publishing to pub.dev, use the same reviewed source commit as its GitHub
release, or create a new release/version if the source changed.
Include the Dart version, supported upstream versions/SHA, migration notes, and
validation scope. Do not reuse an upstream npm tag as the Dart release tag.

The [application integration checklist](../../NEXT_STEPS.md) covers host-specific
work that consuming applications still own. No mobile store upload or production
application deployment is part of this library release.
