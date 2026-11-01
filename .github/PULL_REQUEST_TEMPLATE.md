## Summary

Describe the focused change.

## Why

Explain the problem and why this approach is appropriate.

## UI changes

Include before/after screenshots for visual changes and a short recording for
motion or interaction changes. Delete this section when it does not apply.

## Validation

- [ ] I ran the relevant `scripts/test-changes.sh` validation (`--all` across application, package, harness, remote, or build-system boundaries)
- [ ] Remote host changes include the provider-free native host fixtures; an installed Linux host was checked when one was available
- [ ] No provider-consuming or credential-dependent tests were added

## Review notes

- [ ] Security, privacy, persistence, and destructive-action effects are described
- [ ] New third-party code or assets are documented in `THIRD_PARTY_NOTICES.md`
- [ ] No credentials, personal paths, private hosts, generated products, or provider transcripts are included
- [ ] The change is focused and does not mix unrelated work
