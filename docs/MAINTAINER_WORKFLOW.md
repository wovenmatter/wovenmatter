# Maintainer workflow

Woven Matter keeps validation behavior in repository-owned scripts so the same
checks can run locally and in continuous integration.

## Branch model

- `main` is the stable branch.
- Public contributors work in forks and open pull requests against `main`.
- Only maintainers with write access can merge or push to the repository.
- Required checks protect `main`; a mandatory human approval is not part of the
  merge rule.
- Do not create a permanent `dev` integration branch.

The vouch workflow classifies pull requests for review. Add a contributor to
`.github/VOUCHED.td` as `github:username` after establishing trust. Prefix the
entry with `-` to mark a contributor as denounced. Updating the list on `main`
reclassifies open pull requests, and `/recheck-vouch` in a pull-request comment
rechecks one pull request. Vouch status never grants write access.

## Continuous integration

Keep hosted validation small, path-filtered, and on standard GitHub-hosted
runners. Use read-only `contents` permission, reasonable timeouts, native path
filters, and no ambient credentials. Code from forks is untrusted; run it only
on disposable, whole-job-isolated workers with clean checkouts and no persistent
host state.

Do not provide CI with provider credentials, signing materials, SSH access,
Keychain contents, deployment tokens, or development or staging host access.
Do not add paid runners, preview deployments, release automation, signing,
notarization, staging automation, or another CI provider without a separate
maintainer decision.

The `pull_request_target` classification workflows may inspect metadata or
fetch a pull-request commit as inert Git data. They must never check out or
execute contributor-controlled code.

## Environments

Development, staging, and release use separate builds, credentials, data, and
hosts. No repository script automatically promotes between them. Deployment,
signing, notarization, and release publication remain explicit maintainer
actions performed from an exact accepted commit.
