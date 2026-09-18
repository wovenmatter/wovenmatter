# Repository guidance

- Use the repository-configured GitHub SSH identity; never use the GitHub connector.
- Never initiate or operate account login, device authorization, or authentication
  UI. Release authorization does not authorize authentication recovery. Use only
  existing credentials; never run `gh auth login`, `refresh`, `logout`, or `switch`.
  A sandboxed `gh` failure does not prove a missing or invalid credential. Retry
  the read-only `scripts/check-release-access.sh` through the approved execution
  permission path; if it still fails, stop and report the blocker to the user.
- Build and launch: `scripts/build_and_run.sh`.
- For UI work, follow [the style guide](docs/STYLE_GUIDE.md).
- Validate: `scripts/test-changes.sh`; use `--all` for changes spanning components.
  Tests must not consume provider services. Container lifecycle tests use
  `scripts/test-container.sh` when in scope and Docker is available.
- Release, installation, publication, and delivery require an explicit request.
  For releases, use `.agents/skills/cut-release-wovenmatter/SKILL.md`.
