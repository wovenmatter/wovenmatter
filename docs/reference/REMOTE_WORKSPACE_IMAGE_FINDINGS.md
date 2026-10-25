# Remote workspace image findings — 2026-10-25

Fresh Node 26 / Debian 13.7 image, rebuilt with current package indexes and
security upgrades. Scanned from a Docker image export with the checksummed
official Trivy 0.76.1 release, OS and library vulnerability scanners enabled.
No advisories were suppressed and no severity or unfixed filter was applied.

## Results

- Node/npm packages: **zero detected vulnerabilities** after replacing npm’s affected bundled undici and ip-address modules.
- Debian package findings: **1 critical, 103 high, 249 medium, 332 low, 14 unknown**.
- The high/critical package findings represent **33 distinct CVEs**; one source-library issue may appear against several binary packages.
- GitHub CLI 2.103.2: one additional unknown-severity Go-module finding, GO-2026-5932, concerning deprecated `golang.org/x/crypto/openpgp`. The scanner lists no fixed version; module presence alone does not establish reachable vulnerable code. It remains open for upstream/call-graph assessment.

The image is **not vulnerability-free**. These distribution findings remain
visible even after current stable/security packages and available supported curl
backports are installed. A missing vendor fix in this report does not mean no
upstream fix exists; distribution backports and upstream release versions differ.
Changing unrelated libraries to testing/unstable packages or carrying an
unreviewed collection of local ABI-sensitive patches is outside this hardening
change. Review residual exposure before deploying the image.

The critical finding is [CVE-2026-6653](https://security-tracker.debian.org/tracker/CVE-2026-6653)
in libxml2. Debian classifies it as a minor denial-of-service issue and does not
offer a trixie security update; its current stable library remains affected.
The workspace control API handles JSON rather than XML, but the library remains
part of the browser/tool dependency graph. No claim of complete non-reachability
or risk elimination is made.

Container capabilities, UID, filesystem, private bridges, process limits, and
optional user-configured memory limits reduce impact; they do not patch these
libraries. Hosts, Docker administrators, workspace agents, and provider access
retain the trust model described in the [audit](REMOTE_WORKSPACE_SECURITY_AUDIT.md).

## Remaining high and critical distribution advisories

“Reported status” is the scanner/vendor status, not an independent exploitability
assessment. The links lead directly to Debian’s current source-package tracking.

| Advisory | Severity | Reported status | Affected installed packages |
| --- | --- | --- | --- |
| [CVE-2026-6653](https://security-tracker.debian.org/tracker/CVE-2026-6653) | CRITICAL | affected | `libxml2` |
| [CVE-2022-4055](https://security-tracker.debian.org/tracker/CVE-2022-4055) | HIGH | fix_deferred | `xdg-utils` |
| [CVE-2025-69720](https://security-tracker.debian.org/tracker/CVE-2025-69720) | HIGH | affected | `libncursesw6`, `libtinfo6`, `ncurses-base`, `ncurses-bin` |
| [CVE-2026-12064](https://security-tracker.debian.org/tracker/CVE-2026-12064) | HIGH | affected | `curl`, `libcurl3t64-gnutls`, `libcurl4-gnutls`, `libcurl4t64` |
| [CVE-2026-15308](https://security-tracker.debian.org/tracker/CVE-2026-15308) | HIGH | affected | `libpython3.13-minimal`, `libpython3.13-stdlib`, `python3.13`, `python3.13-minimal`, `python3.13-venv` |
| [CVE-2026-16742](https://security-tracker.debian.org/tracker/CVE-2026-16742) | HIGH | affected | `libpam-systemd`, `libsystemd-shared`, `libsystemd0`, `libudev1`, `systemd`, `systemd-sysv` |
| [CVE-2026-19445](https://security-tracker.debian.org/tracker/CVE-2026-19445) | HIGH | affected | `libpython3.13-minimal`, `libpython3.13-stdlib`, `python3.13`, `python3.13-minimal`, `python3.13-venv` |
| [CVE-2026-19553](https://security-tracker.debian.org/tracker/CVE-2026-19553) | HIGH | affected | `libpython3.13-minimal`, `libpython3.13-stdlib`, `python3.13`, `python3.13-minimal`, `python3.13-venv` |
| [CVE-2026-23949](https://security-tracker.debian.org/tracker/CVE-2026-23949) | HIGH | affected | `python3-setuptools-whl` |
| [CVE-2026-34980](https://security-tracker.debian.org/tracker/CVE-2026-34980) | HIGH | affected | `libcups2t64` |
| [CVE-2026-36849](https://security-tracker.debian.org/tracker/CVE-2026-36849) | HIGH | will_not_fix | `libtiff6` |
| [CVE-2026-37555](https://security-tracker.debian.org/tracker/CVE-2026-37555) | HIGH | affected | `libsndfile1` |
| [CVE-2026-52490](https://security-tracker.debian.org/tracker/CVE-2026-52490) | HIGH | affected | `libtiff6` |
| [CVE-2026-54369](https://security-tracker.debian.org/tracker/CVE-2026-54369) | HIGH | affected | `libacl1` |
| [CVE-2026-55453](https://security-tracker.debian.org/tracker/CVE-2026-55453) | HIGH | affected | `libcups2t64` |
| [CVE-2026-7210](https://security-tracker.debian.org/tracker/CVE-2026-7210) | HIGH | affected | `libpython3.13-minimal`, `libpython3.13-stdlib`, `python3.13`, `python3.13-minimal`, `python3.13-venv` |
| [CVE-2026-74860](https://security-tracker.debian.org/tracker/CVE-2026-74860) | HIGH | affected | `libxml2` |
| [CVE-2026-76642](https://security-tracker.debian.org/tracker/CVE-2026-76642) | HIGH | affected | `bsdutils`, `libblkid1`, `liblastlog2-2`, `libmount1`, `libsmartcols1`, `libuuid1`, `login`, `mount`, `util-linux` |
| [CVE-2026-78408](https://security-tracker.debian.org/tracker/CVE-2026-78408) | HIGH | affected | `bsdutils`, `libblkid1`, `liblastlog2-2`, `libmount1`, `libsmartcols1`, `libuuid1`, `login`, `mount`, `util-linux` |
| [CVE-2026-78409](https://security-tracker.debian.org/tracker/CVE-2026-78409) | HIGH | affected | `bsdutils`, `libblkid1`, `liblastlog2-2`, `libmount1`, `libsmartcols1`, `libuuid1`, `login`, `mount`, `util-linux` |
| [CVE-2026-78410](https://security-tracker.debian.org/tracker/CVE-2026-78410) | HIGH | affected | `bsdutils`, `libblkid1`, `liblastlog2-2`, `libmount1`, `libsmartcols1`, `libuuid1`, `login`, `mount`, `util-linux` |
| [CVE-2026-82049](https://security-tracker.debian.org/tracker/CVE-2026-82049) | HIGH | affected | `libpython3.13-minimal`, `libpython3.13-stdlib`, `python3.13`, `python3.13-minimal`, `python3.13-venv` |
| [CVE-2026-8458](https://security-tracker.debian.org/tracker/CVE-2026-8458) | HIGH | affected | `curl`, `libcurl3t64-gnutls`, `libcurl4-gnutls`, `libcurl4t64` |
| [CVE-2026-86138](https://security-tracker.debian.org/tracker/CVE-2026-86138) | HIGH | affected | `libxml2` |
| [CVE-2026-86139](https://security-tracker.debian.org/tracker/CVE-2026-86139) | HIGH | affected | `libxml2` |
| [CVE-2026-86140](https://security-tracker.debian.org/tracker/CVE-2026-86140) | HIGH | affected | `libxml2` |
| [CVE-2026-86142](https://security-tracker.debian.org/tracker/CVE-2026-86142) | HIGH | affected | `libxml2` |
| [CVE-2026-86143](https://security-tracker.debian.org/tracker/CVE-2026-86143) | HIGH | affected | `libxml2` |
| [CVE-2026-86144](https://security-tracker.debian.org/tracker/CVE-2026-86144) | HIGH | affected | `libxml2` |
| [CVE-2026-88806](https://security-tracker.debian.org/tracker/CVE-2026-88806) | HIGH | affected | `libx11-6`, `libx11-data`, `libx11-xcb1` |
| [CVE-2026-88807](https://security-tracker.debian.org/tracker/CVE-2026-88807) | HIGH | affected | `libxrender1` |
| [CVE-2026-94286](https://security-tracker.debian.org/tracker/CVE-2026-94286) | HIGH | affected | `libxtst6` |
| [CVE-2026-9538](https://security-tracker.debian.org/tracker/CVE-2026-9538) | HIGH | fix_deferred | `libperl5.40`, `perl`, `perl-base`, `perl-modules-5.40` |

## Reproduction

Build with `--pull --no-cache`, save the resulting image with `docker save`, then
run `trivy image --scanners vuln --format json --input image.tar` against that
export. Review OS findings against Debian’s security tracker and language
findings against the actual installed/resolved module versions. Repeat after
upstream security updates; these counts are point-in-time evidence, not a waiver.
