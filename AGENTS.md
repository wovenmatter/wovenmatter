# Repository guidance

- Use the repository-configured GitHub SSH identity; never use the GitHub connector.
- Build and launch: `scripts/build_and_run.sh`.
- For UI work, follow [the style guide](docs/STYLE_GUIDE.md).
- Validate: `scripts/test-changes.sh`; use `--all` for changes spanning components.
  Tests must not consume provider services. Container lifecycle tests use
  `scripts/test-container.sh` when in scope and Docker is available.
- Release, installation, publication, and delivery require an explicit request.
  For releases, use `.agents/skills/cut-release-wovenmatter/SKILL.md`.
