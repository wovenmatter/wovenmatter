# Contributing

Thank you for helping improve Woven Matter.

## Before opening a change

- Search existing issues and keep each change focused.
- Fork the repository, create a short-lived branch, and open a pull request
  against `main`.
- Do not include credentials, provider transcripts, personal paths, private
  hosts, generated build products, or proprietary assets.
- Keep the local app useful without Buzz or a remote machine.
- Keep Buzz local and optional. Do not add relay or deployment management.
- Keep one remote container equal to one complete workspace, not one agent.
- Do not bundle third-party harness CLIs or ACP adapters.

## Validate

Run the repository-owned validation documented by the codebase. Tests must be
deterministic, need no provider credentials, and make no real LLM calls.
Describe any platform or environment limitation in the pull request.

Dependency updates are reviewed and opened deliberately by maintainers. Review
base-image digests and harness catalog sources when updating them.

## Pull requests

Explain the product behavior that changed, list validation performed, and call
out security, privacy, persistence, or third-party provenance impacts.

Pull requests are automatically assigned a `vouch:*` trust label and a `size:*`
change-size label. External contributors begin as `vouch:unvouched`. A
maintainer can add `github:username` to `.github/VOUCHED.td` after establishing
trust; repository collaborators with write access are trusted automatically.
These labels help prioritize review. They do not grant repository access or
guarantee that a pull request will be merged.

By submitting a contribution, you agree that it is licensed under this
project's MIT License.
