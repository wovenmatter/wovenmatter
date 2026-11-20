# Contributing

Thank you for helping improve Woven Matter.

## Build from source

Development requires an Apple silicon Mac with macOS 26 and Xcode 27, and the
Node.js release recorded in `default-agent/.node-version`. No provider
credentials are needed to build or test. Read the
[architecture](docs/ARCHITECTURE.md) first: it describes the parts below and
the rules every change keeps.

| Path | What it is |
| --- | --- |
| `protocol/` | The wire types every client and server speaks |
| `library/` | The library: schema, writer, reads and sync |
| `server/` | The background server, for macOS and Linux |
| `app/` | The Mac app (`app/WovenMatter.xcodeproj`) |
| `default-agent/` | Pi Durable, a Node child process of the server |
| `bots/` | The bots runtime, a Node child process of the server |
| `harnesses/` | The harness catalog and adapters |

Build and launch a development instance:

```sh
scripts/build_and_run.sh --instance NAME
```

Each instance has its own bundle identifier, its own data folder and its own
server, and never reads or changes the data of an installed app. Development
builds are separate from signed production releases; build and test scripts
never publish or notarize a release. Follow the
[style guide](docs/STYLE_GUIDE.md) for UI changes.

## Before opening a change

- Search existing issues and keep each change focused.
- If you do not have write access, fork the repository and work on a
  short-lived branch in your fork. Collaborators also use a short-lived branch
  rather than committing directly to `main`.
- Open the pull request against `main`.
- Do not include credentials, provider transcripts, personal paths, private
  hosts, generated build products, or proprietary assets.
- Keep the Mac app useful on its own, without a Linux host or another machine.
- Do not bundle third-party harness CLIs or ACP adapters. Settings installs
  them, or uses the installations people already have.
- Follow the [dependency policy](docs/DEPENDENCIES.md) for any new or updated
  dependency, and record new third-party code or assets in
  [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Validate

```sh
scripts/test-changes.sh
```

It runs the static checks, the server package's tests (which cover the
library and the protocol) and the Pi Durable and bots tests. Tests must be
deterministic, use a stand-in runtime, need no provider credentials, and make
no real model calls. Keep the suite small: one test for each behaviour that
would hurt if it broke. Pull request CI runs the same suite on Linux
(`scripts/test-changes.sh --ci`) without provider, release, deployment, or
signing credentials. Describe any platform limitation in the pull request.

## Pull requests

Explain the product behavior that changed, list the validation you ran, and
call out security, privacy, persistence, or third-party provenance impacts.
Every pull request targeting `main` needs approval from the code owner before
it can merge.

Comment `/recheck-author` on a pull request to give it an author label.
Verified members of the Woven Matter GitHub organization, including owners and
agent accounts, receive `author:organization`. Outside contributors and
authors whose membership cannot be verified receive
`author:external-or-unverified` for closer review. Collaborator access or bot
status alone does not establish membership. Labels never bypass code-owner approval, branch protections, or
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
