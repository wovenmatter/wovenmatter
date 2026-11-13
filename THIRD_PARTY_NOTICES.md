# Third-party notices

Woven Matter includes, adapts, or installs the third-party software and assets
below. Each keeps its own license. Where a component ships its own license and
notice files (for example inside bundled `node_modules`, `Resources/BrowserLicenses`,
or a container image), those files are retained unchanged. The app's own copy
of these attributions is `app/App/ThirdPartyNotices.txt`.

## Executor

Woven Matter integrates [Executor](https://executor.sh), created by Rhys Sullivan,
through its public API. The local and remote installers use the unmodified
`executor` npm package, selected from its supported V2 release line at installation,
and retain its upstream license and bundled dependency notices. Those dependencies remain subject to their own
licenses.

Source: [UsefulSoftwareCo/executor](https://github.com/UsefulSoftwareCo/executor).

Executor is licensed under the MIT License, reproduced below.

MIT License

Copyright (c) 2026 Rhys Sullivan

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Pi Durable runtime

Pi Durable bundles `@earendil-works/pi-durable` 1.5.2 from
[Earendil Works Pi](https://github.com/earendil-works/pi/tree/v1.5.2/packages/durable)
for native execution and persistence. The format-1 JSONL migration reader in
`default-agent/src/legacy-jsonl-migration.mjs` adapts its recovery and reclamation
rules under the same license. Its
[upstream license](https://github.com/earendil-works/pi/blob/v1.5.2/LICENSE)
is MIT, with `Copyright (c) 2025 Mario Zechner`.

The Mac and Linux runtime (`default-agent/`) also bundles `@earendil-works/pi-ai`,
`@earendil-works/chord`, and `@earendil-works/pi-coding-agent` from the same
project and license, and `typebox` (MIT). The iPhone app (beta) bundles Pi
Durable, Pi AI, Pi Schema, Chord, Pi Telemetry, and `partial-json` into one
script, with their licenses in its `THIRD_PARTY_LICENSES.txt`.

Native store ownership uses `proper-lockfile` from
[Made With MOXY](https://github.com/moxystudio/node-proper-lockfile).
It is MIT licensed, with
`Copyright (c) 2018 Made With MOXY Lda <hello@moxy.studio>`.
The MIT permission and disclaimer terms reproduced above apply to these packages.
Bundled dependencies retain their own upstream licenses and notices.

Pi Durable's Claude model-client transport follows the replay, inert tool
inventory, and single-request admission design of
[Hermes Claude Subscription DirectSDK](https://github.com/NousResearch/hermes-plugin-claude-subscription-directsdk)
at reviewed revision `f1c1220778c7864fe4c1494baf9b1566e7c95bd2`. It is MIT
licensed, with `Copyright (c) 2026 Nous Research and contributors`; the full
notice is in `default-agent/src/claude-hermes-LICENSE.txt`.

Pi Durable can use Claude models through the
[Claude Agent SDK](https://github.com/anthropics/claude-agent-sdk-typescript),
which is © Anthropic PBC and used under
[Anthropic's terms](https://code.claude.com/docs/en/legal-and-compliance). Its
native runtime keeps Anthropic's original signature and is never modified.

## Lucide

The dashboard icon assets are derived from `lucide-static` 1.72.0.
Published tarball integrity and per-asset hashes are recorded in
`docs/assets/lucide-provenance.json`.

Copyright (c) 2022 Lucide Contributors
Copyright (c) 2026 Lucide Icons and Contributors

The complete upstream license, including Feather-derived icons and their MIT
notice, is preserved in [LUCIDE_LICENSE.txt](docs/assets/LUCIDE_LICENSE.txt) and
both apps’ bundled `LUCIDE_LICENSE.txt`.

Permission to use, copy, modify, and/or distribute this software for any
purpose with or without fee is hereby granted, provided that the above
copyright notice and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION
OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN
CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

## Usage discovery and presentation

The local usage transcript discovery, de-duplication, fork suppression, and
analytics presentation are adapted from
[T3 Code](https://github.com/pingdotgg/t3code/tree/afa83098064e7dca524a1e42dea3de03a883a0b6)
at revision `afa83098064e7dca524a1e42dea3de03a883a0b6`.

Provider-specific account limit retrieval and OpenCode Go local accounting are
adapted from
[Codex Bar](https://github.com/steipete/codexbar/tree/27c7f334e3c46c96ff8c063afbe0c7944ba5e0b7)
at revision `27c7f334e3c46c96ff8c063afbe0c7944ba5e0b7`.

The paragraph-level streaming of assistant text
(`app/Sources/WovenMatterCore/AssistantStreamingText.swift`) adapts T3 Code's
algorithm at revision `611132c171f3a821bd2e32f22261135cef6330ac`.

Both projects are licensed under the MIT License. T3 Code carries copyright
`Copyright (c) 2026 T3 Tools Inc.` Codex Bar carries copyright
`Copyright (c) 2025 Peter Steinberger`. The MIT terms printed below apply.

## Harness identity marks

The app displays third-party marks only to identify the harness used by an
agent. The marks remain trademarks of their respective owners and are not
Woven Matter branding.

| Asset | Source | Terms and modifications |
|---|---|---|
| Codex | [Lobe Icons `Codex`](https://github.com/lobehub/lobe-icons/tree/master/src/Codex) | MIT-licensed color SVG retained at `docs/assets/harness-logos/codex.svg`; the app uses a transparent high-resolution PNG rendered from that source because AppKit deforms its compact compound SVG path |
| OpenAI | [T3 Code `openai_dark.svg`](https://github.com/pingdotgg/t3code/blob/afa83098064e7dca524a1e42dea3de03a883a0b6/apps/marketing/public/harnesses/openai_dark.svg) | T3 Code is MIT licensed; white fill changed to a template-compatible black fill and offered as the alternate Codex harness mark |
| Claude | [Anthropic press kit](https://www.anthropic.com/press-kit) | Official `Claude Spark - Clay.svg`; unmodified |
| Grok | [xAI brand guidelines](https://x.ai/legal/brand-guidelines) | Official `Grok_Logomark_Dark.svg`; unmodified and used referentially as required by xAI |
| Pi | [Pi press kit](https://pi.dev/press-kit), [primary color SVG](https://pi.dev/logo-auto.svg) | Official color pixel mark from the MIT-licensed Pi project retained at `docs/assets/harness-logos/pi-color.svg`; the app places it on the same circular black badge as the black-and-white variant, preserving matching canvas dimensions, padding, and mark bounds, and uses it by default for Pi Durable. The existing circular black-and-white badge remains an alternate Pi Durable icon |
| OpenCode | [OpenCode brand guidelines](https://opencode.ai/brand) | Official pixel logomark reconstructed from the published brand “O”; two-tone fills retained |

An open-source repository license does not transfer ownership of the underlying
brand marks. The Codex-specific terminal mark above is retained with its
community-source provenance and must be used only to identify the Codex harness.

The MIT-licensed sources above carry these copyright notices:

- Copyright (c) 2023 LobeHub
- Copyright (c) 2026 T3 Tools Inc.
- Copyright (c) 2025 Mario Zechner

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Chromium Embedded Framework

The built-in browser bundles the
[Chromium Embedded Framework](https://github.com/chromiumembedded/cef) (CEF)
`156.0.30+g6028375+chromium-156.0.8078.96`, as recorded in
`app/Browser/cef-version.json`, with its checksummed upstream binary
distribution. CEF is licensed under the BSD 3-Clause License, copyright
Marshall A. Greenblatt with portions copyright Google Inc. Chromium and its
components are licensed under the BSD 3-Clause License and the licenses listed
in Chromium's credits. CEF's `LICENSE.txt` and Chromium's `CREDITS.html` ship
unchanged in the app under `Resources/BrowserLicenses`.

## Browser and computer automation

Woven Matter bundles [Cua Driver](https://github.com/trycua/cua) 0.49.3
(`cua-driver-rs-v0.49.3`, source `63bd9cdb82d6160b05a965d2d0e26e0a3c17cdc2`),
under MIT, copyright 2025 Cua AI, Inc., as recorded in
`app/Automation/cua-version.json`. The upstream signed universal executable is
retained unchanged.
Its license and third-party notices are included in `app/Automation` and shipped
under `Resources/Cua` in the app. No Cua Spaces or perception/model extension is bundled.

Browser automation bundles `playwright-core` from
[Microsoft Playwright](https://github.com/microsoft/playwright) under Apache-2.0
and `ws` from [websockets/ws](https://github.com/websockets/ws) under MIT.
Their upstream licenses remain in the bundled Node dependencies. Playwright
connects to Woven Matter’s bundled CEF rather than installing another browser.

The automation server and Executor client bundle the v2
`@modelcontextprotocol/server` and `@modelcontextprotocol/client` packages from
[the MCP TypeScript SDK](https://github.com/modelcontextprotocol/typescript-sdk)
under Apache-2.0. Their complete upstream licenses and notices remain in the
bundled Node dependencies.

## Bots runtime

The bots runtime (`bots/`, shipped under `Resources/bots` and in Linux host
releases) is ported from Woven Matter's Pi Bot server. It bundles the locked
production dependencies in `bots/package-lock.json`, installed unmodified with
`npm ci --omit=dev`: `@earendil-works/pi-durable`, `@earendil-works/pi-ai` and
`@earendil-works/chord` from
[Earendil Works Pi](https://github.com/earendil-works/pi) (MIT,
`Copyright (c) 2025 Mario Zechner`), `typebox` (MIT), `undici` (MIT), `ws`
(MIT) and `zod` (MIT), and their dependencies under MIT, Apache-2.0, BSD-2-Clause,
BSD-3-Clause, ISC, 0BSD and Unlicense terms. The
[Claude Agent SDK](https://github.com/anthropics/claude-agent-sdk-typescript)
and its native runtime are © Anthropic PBC and used under
[Anthropic's terms](https://code.claude.com/docs/en/legal-and-compliance); the
runtime keeps Anthropic's original signature and is never modified. Each
package's license and notice files remain in the bundled `node_modules`.

The in-container helper (`bots/helper/`) adapts Pi Bot's environment agent.
Bot containers are built at run time from `bots/image` on Ubuntu 26.04 LTS,
with Chromium, Playwright, Node.js, Python, git, build tools and tini installed
from their official distributions inside the bot engine; their licenses and
notices remain in each image under `/usr/share/doc` and the installed packages.
No container image is shipped in the app.

## Woven VM guest and bot engines

On Apple silicon Macs, the Woven VM downloads the pinned
[Ubuntu 26.04 LTS server cloud image](https://cloud-images.ubuntu.com/releases/resolute/)
for arm64 from Canonical on first run (`app/VMHelper/guest-version.json`
records its URL, serial, size and SHA-256, which is checked before use). The
image is not redistributed in the app. Ubuntu is a trademark of Canonical Ltd.;
the image's packages remain under their own licenses, listed in the guest under
`/usr/share/doc/*/copyright`. Woven Matter converts the image to a raw disk and
configures it through cloud-init; it does not modify the packages in the image.

Inside the guest, Docker Engine (Docker CE, containerd, runc and their plugins)
is installed unmodified from [Docker's signed apt repository](https://download.docker.com/linux/ubuntu)
at the versions pinned in `guest-version.json`. The app bundles only Docker's
public repository signing key (`Resources/WovenVM/docker-archive-keyring.asc`),
verified by fingerprint and SHA-256. On Linux hosts, `remote/host/bots-engine.py`
installs Docker's official static binaries, pinned with SHA-256 in
`remote/host/runtime-versions.json`. Docker Engine (Moby) is licensed under
Apache-2.0, containerd and runc under Apache-2.0; their licenses ship with the
packages and archives. Docker is a trademark of Docker, Inc.

## Sparkle 2.10.1

https://github.com/sparkle-project/Sparkle

Copyright (c) 2006-2013 Andy Matuschak.
Copyright (c) 2009-2013 Elgato Systems GmbH.
Copyright (c) 2011-2014 Kornel Lesiński.
Copyright (c) 2015-2017 Mayur Pawashe.
Copyright (c) 2014 C.W. Betts.
Copyright (c) 2014 Petroules Corporation.
Copyright (c) 2014 Big Nerd Ranch.
All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

=================
EXTERNAL LICENSES
=================

bspatch.c and bsdiff.c, from bsdiff 4.3 <http://www.daemonology.net/bsdiff/>:

Copyright 2003-2005 Colin Percival
All rights reserved

Redistribution and use in source and binary forms, with or without
modification, are permitted providing that the following conditions
are met:
1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.

--

sais.c and sais.h, from sais-lite (2010/08/07) <https://sites.google.com/site/yuta256/sais>:

The sais-lite copyright is as follows:

Copyright (c) 2008-2010 Yuta Mori All Rights Reserved.

Permission is hereby granted, free of charge, to any person
obtaining a copy of this software and associated documentation
files (the "Software"), to deal in the Software without
restriction, including without limitation the rights to use,
copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the
Software is furnished to do so, subject to the following
conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
OTHER DEALINGS IN THE SOFTWARE.

--

Portable C implementation of Ed25519, from https://github.com/orlp/ed25519

Copyright (c) 2015 Orson Peters <orsonpeters@gmail.com>

This software is provided 'as-is', without any express or implied warranty. In no event will the
authors be held liable for any damages arising from the use of this software.

Permission is granted to anyone to use this software for any purpose, including commercial
applications, and to alter it and redistribute it freely, subject to the following restrictions:

1. The origin of this software must not be misrepresented; you must not claim that you wrote the
   original software. If you use this software in a product, an acknowledgment in the product
   documentation would be appreciated but is not required.

2. Altered source versions must be plainly marked as such, and must not be misrepresented as
   being the original software.

3. This notice may not be removed or altered from any source distribution.

--

SUSignatureVerifier.m:

Copyright (c) 2011 Mark Hamlin.

All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted providing that the following conditions
are met:
1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.

## Swift packages

The Linux library (`wovenmatter-library`, shipped in Linux host releases) uses
[Swift Crypto](https://github.com/apple/swift-crypto) 5.1.1 and its dependency
[Swift ASN.1](https://github.com/apple/swift-asn1) 1.7.4 in place of Apple's
CryptoKit, as recorded in `app/Package.resolved`. Both are licensed under the
Apache License 2.0, copyright Apple Inc. and the SwiftCrypto and SwiftASN1
project authors. The Mac app uses CryptoKit and does not link them.

## Executor container image

The standalone Executor image (`remote/Executor.Dockerfile`) installs
Archive::Tar 3.14 from its checksummed CPAN release under the same terms as
Perl; its module documentation is retained. It replaces the Executor runtime's
bundled sharp selection with locked sharp 0.35.5 and the corresponding prebuilt
libvips packages. Their Apache-2.0, LGPL-3.0-or-later, and dependency notices
remain in the installed packages. The replacement changes dependency selection
and does not modify upstream source.

## Debian security rebuilds

The Executor image rebuilds selected Debian runtime libraries from authenticated
Debian source packages. Reviewed Ubuntu or upstream security patches are
applied where Debian stable has not yet published a fixed binary. Package
copyright files remain under `/usr/share/doc`; exact source versions, patch
origins, hashes, and Debian build provenance are retained under
`/usr/local/share/wovenmatter/security/provenance` in the image and in
`remote/security/backports.json` in this repository.
