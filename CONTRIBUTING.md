# Contributing

Thank you for helping improve Woven Matter.

## Build from source

Development requires macOS 26, Xcode 26, the Node.js release recorded in
`default-agent/.node-version`, and `jq` for the validation scripts. The Xcode
project is `app/WovenMatter.xcodeproj`; the Swift package is rooted at `app/`.
No provider credentials are needed to build or test.

Build and launch the development app:

```sh
scripts/build_and_run.sh
```

Each worktree gets its own instance, bundle ID, caches, and isolated data. See
[development builds](docs/DEVELOPMENT_BUILDS.md) for the snapshot, client, and
live modes. Development builds are separate from signed production releases;
build and test scripts never publish or notarize a release. Follow the
[style guide](docs/STYLE_GUIDE.md) for UI changes.

## Before opening a change

- Search existing issues and keep each change focused.
- If you do not have write access, fork the repository and work on a
  short-lived branch in your fork. Collaborators also use a short-lived branch
  rather than committing directly to `main`.
- Open the pull request against `main`.
- Do not include credentials, provider transcripts, personal paths, private
  hosts, generated build products, or proprietary assets.
- Keep the Mac app useful on its own, without a Linux host or another device.
- Do not bundle third-party harness CLIs or ACP adapters. Settings installs
  them, or uses the installations people already have.
- Follow the [dependency policy](docs/DEPENDENCIES.md) for any new or updated
  dependency, and record new third-party code or assets in
  [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Validate

```sh
scripts/test-changes.sh          # suites chosen from the files you changed
scripts/test-changes.sh --all    # changes that span components
```

Tests must be deterministic, need no provider credentials, and make no real
model calls. Describe any platform or environment limitation in the pull
request. Pull request CI runs one portable Linux check without provider,
release, deployment, or signing credentials. Native, mobile, and image
workflows run only when a maintainer requests them. See the
[maintainer workflow](docs/MAINTAINER_WORKFLOW.md) for the validation contract.

## Pull requests

Explain the product behavior that changed, list the validation you ran, and
call out security, privacy, persistence, or third-party provenance impacts.
Every pull request targeting `main` needs approval from the code owner before
it can merge.

New and reopened pull requests receive an author label. Verified members of the
Woven Matter GitHub organization, including owners and agent accounts, receive
`author:organization`. Outside contributors and authors whose membership cannot
be verified receive `author:external-or-unverified` for closer review.
Collaborator access or bot status alone does not establish membership. Comment
`/recheck-author` on a pull request to refresh its label after a membership
change. Labels never bypass code-owner approval, branch protections, or
required checks.

## Documentation

The [README](README.md) sets the product story and feature order. The
[documentation index](docs/README.md) shows where new material belongs: user
guides in `docs/guide/`, implementation contracts and references elsewhere in
`docs/`.

- Write guides for someone who knows AI agents and harnesses but may not be an
  engineer. Explain what they can do in the app before any Git or terminal
  workflow.
- Use direct sentences, familiar words, and short headings without periods.
  Describe features through their workflows. Avoid maturity labels and
  promotional claims that lack evidence.
- Call the product "Woven Matter". Check every UI label and behavior against
  the code before writing it down.
- Keep version-specific changes in release notes, not in the README or
  guides.
- Keep one-off audits, coverage inventories, and review evidence out of the
  repository. Put them in the pull request description or a build artifact.
- Legal notices, the security policy, and release instructions keep their own
  plain wording rather than the README's voice.

## License

By submitting a contribution, you agree that it is licensed under this
project's [MIT License](LICENSE).
