# Remote workspace image findings — 2026-10-26

Both Linux images were rebuilt from scratch with current package indexes and
scanned from Docker image exports with the checksum-verified official Trivy
0.76.1 release. OS and language vulnerability scanners were enabled. No
advisory, severity, or unfixed record was suppressed.

## Results

| Image | Raw critical | Raw high | Medium | Low | Unknown |
| --- | ---: | ---: | ---: | ---: | ---: |
| Workspace | 1 | 81 | 201 | 312 | 10 |
| Executor | 0 | 54 | 114 | 209 | 5 |

These are scanner records, not the count of exploitable vulnerabilities left in
the running images. Trivy compares Debian package version strings and embedded
base-image SBOMs; it cannot recognize Woven Matter's reviewed `+wmsecurity1`
source backports, a fixed module overlaid inside a distribution package, or an
absent vulnerable executable. The raw records are retained because hiding them
would make future maintenance harder.

After checking every raw high/critical family against the installed files,
upstream affected ranges, source patches, and runtime tests, there are **no known
unmitigated high or critical findings in the live runtime**. This is not a claim
that either image is vulnerability-free: medium, low, unknown, undisclosed, and
future issues remain possible, and the local source repairs require maintenance.

The initial scan that prompted this work reported **1 critical and 103 high**
Debian-package records. The critical record was CVE-2026-6653 in Debian's
libxml2 package. It is an XML parser out-of-bounds read/denial-of-service bug,
not a vulnerability in the Debian operating system itself. Debian stable had no
fixed binary. This change applies the reviewed upstream/Ubuntu repair while
retaining the stable ABI. The build proves the original fixture triggers under
AddressSanitizer before the patch and passes afterward. Trivy still emits the
critical record because its Debian database does not understand the local
`+wmsecurity1` revision.

## High and critical disposition

| Raw finding family | Disposition in the images |
| --- | --- |
| libxml2: CVE-2026-6653, CVE-2026-74860, CVE-2026-86138 through CVE-2026-86144 | Rebuilt from authenticated Debian stable source with each missing reviewed repair. The stable 2.9 source already contains the equivalent CVE-2026-86139 zero-length guard, so the newer 2.15 patch is not reapplied. CVE-2026-6653 has a vulnerable/fixed ASan control. |
| ncurses CVE-2025-69720; libsndfile CVE-2026-37555; X11/Xrender/Xtst CVE-2026-88806, CVE-2026-88807, CVE-2026-94286 | Rebuilt against the stable ABI with checksum-pinned upstream or Ubuntu security patches. |
| util-linux CVE-2026-76642, CVE-2026-78408, CVE-2026-78410 | Debian stable 2.41.5 rebuilt with the 2.41.6 fixes and the later stable-branch correction that uses the correct `RESOLVE_NO_SYMLINKS` value. Targeted libmount, mount, and nsenter integration suites pass. CVE-2026-78409 begins with the 2.42 line and does not apply to the retained 2.41.5 base. |
| libtiff CVE-2026-36849/CVE-2026-52490; libacl CVE-2026-54369 | Rebuilt from current authenticated Debian sources, libtiff 4.7.2 and acl 2.4.0. The separately vulnerable `tiffcrop` tool is not installed. |
| curl advisories through CVE-2026-107929 | Rebuilt from authenticated Debian curl 8.23.0 source against the stable ABI. Upstream lists no published vulnerability affecting 8.23.0; this also removes the HTTP/2 upload use-after-free and the other advisories affecting the former 8.21.0 selection. |
| Perl Archive::Tar CVE-2026-9538 | The affected Debian source package remains visible to the OS scanner, but runtime module resolution is replaced by checksum-pinned Archive::Tar 3.14 after its upstream tests pass. The vulnerable range ends before 3.10. |
| systemd CVE-2026-16742 | The issue is in `systemd-homed`. No init system or `systemd-homed` service/binary runs in either container. The shared libraries remain transitive runtime dependencies. |
| CUPS CVE-2026-34980/CVE-2026-55453 | Both issues require CUPS server/backend code. Neither `cupsd` nor the affected IPP backend is present; only the browser's client library dependency remains. |
| xdg-utils CVE-2022-4055 | The vulnerable `xdg-email` entry point is deleted and Thunderbird is absent. |
| setuptools 70.3.0, urllib3 2.7.0, msgpack 1.1.2 | Stale build-package entries in the official Python image's embedded SPDX SBOM. Live metadata proves setuptools 84.2.1 is installed and urllib3/msgpack are absent. These records have no filesystem path; adding unused packages would increase attack surface. |
| npm brace-expansion, http-cache-semantics, undici; Executor-bundled sharp | Executor now upgrades npm to 12.2.1, replaces npm's vulnerable undici/ip-address copies from a committed integrity lock, and replaces the embedded sharp runtime with locked sharp 0.35.5/libvips 1.3.4. A clean rescan contains no high/critical language-package findings. |

The workspace's Node/npm scan likewise contains no high/critical language
finding. GitHub CLI 2.103.2 still produces unknown-severity GO-2026-5932 for the
deprecated `golang.org/x/crypto/openpgp` module. The scanner lists no fixed
version, and module presence does not establish a reachable vulnerable call;
this remains an upstream/call-graph maintenance item rather than a hidden pass.

## Reproduction and maintenance boundary

Build each image with `--pull --no-cache`, save it with `docker save`, and run
`trivy image --scanners vuln --format json --input image.tar`. Review raw results
against the live filesystem and the provenance under
`/usr/local/share/wovenmatter/security/provenance`; never suppress the raw scan
solely because a local repair exists.

Exact source versions, patch origins, and SHA-256 values are recorded in
`remote/security/backports.json`. Image construction fails on a checksum or
patch-context mismatch. Remove a local repair once Debian stable ships an equal
or newer fix, and repeat native amd64/arm64 image validation after every refresh.
