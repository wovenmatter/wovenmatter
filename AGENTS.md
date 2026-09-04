# AGENTS.md

This repository contains the native macOS app, the remote workspace container,
the shared harness catalog, and their deterministic tests.

- Build and launch with `scripts/build_and_run.sh`.
- Validate changes with `scripts/test-changes.sh`; use `--all` across package,
  app, remote, harness, or build-system boundaries.
- Run `scripts/test-container.sh` only when container lifecycle coverage is in
  scope and Docker is available.
- Preserve unrelated work and reuse build/package caches.
- Never make provider-consuming calls in tests.
- Do not run release, installation, publication, or delivery workflows unless
  the user explicitly requests them.
- For every request to cut or prepare a WovenMatter release, use
  `.agents/skills/cut-release-wovenmatter/SKILL.md`. If the user did not supply
  a version, propose one and wait for confirmation before creating a tag.
  Once the exact version is supplied or confirmed, complete the release through
  public publication unless the user explicitly asks to stop at a draft. After
  verifying the signed private draft, publish only through
  `scripts/publish-release.sh`; do not require a separate browser or Actions
  handoff.
