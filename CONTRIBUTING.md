# Contributing

Thank you for helping improve WovenMatter.

## Before opening a change

- Search existing issues and keep each change focused.
- If you do not have write access, fork the repository and create a short-lived
  branch in your fork. Repository collaborators should also use a short-lived
  branch rather than committing directly to `main`.
- Open the pull request directly against `main`.
- Do not include credentials, provider transcripts, personal paths, private
  hosts, generated build products, or proprietary assets.
- Keep the local app useful without Buzz or a remote machine.
- Keep Buzz local and optional. Do not add relay or deployment management.
- Keep one remote container equal to one complete workspace, not one agent.
- Do not bundle third-party harness CLIs or ACP adapters.

## Validate

Run:

```sh
scripts/test-changes.sh --all
```

When remote container behavior changes and Docker is available, also run:

```sh
scripts/test-container.sh
```

Tests must be deterministic, need no provider credentials, and make no real LLM
calls. Describe any platform or environment limitation in the pull request.
Continuous integration runs the same repository-owned validation without
provider, release, deployment, or signing credentials.

Dependency updates are reviewed and opened deliberately by maintainers. Check
the container base-image digest and harness catalog sources as part of that
manual review.

See `docs/MAINTAINER_WORKFLOW.md` for the validation contract and environment
boundaries.

## Pull requests

Explain the product behavior that changed, list validation performed, and call
out security, privacy, persistence, or third-party provenance impacts. Every
pull request targeting `main` requires approval from the repository code owner
before it can be merged.

Pull requests are automatically assigned a `vouch:*` trust label and a `size:*`
change-size label. External contributors begin as `vouch:unvouched`. A
maintainer can add `github:username` to `.github/VOUCHED.td` after establishing
trust; repository collaborators with write access are trusted automatically.
These labels help prioritize review. They do not grant repository access or
guarantee that a pull request will be merged.

By submitting a contribution, you agree that it is licensed under this
project's MIT License.
