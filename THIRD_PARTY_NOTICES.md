# Third-party notices

## Executor

Woven Matter integrates [Executor](https://executor.sh), created by Rhys Sullivan,
through its public API. The local and remote installers use the unmodified
`executor` npm package at version `2.0.0-beta.7` and retain its upstream license
and bundled dependency notices. Those dependencies remain subject to their own
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

Pi Durable bundles `@earendil-works/pi-durable` 1.3.0 from
[Earendil Works Pi](https://github.com/earendil-works/pi/tree/v1.3.0/packages/durable)
for native execution and persistence. Its
[upstream license](https://github.com/earendil-works/pi/blob/v1.3.0/LICENSE)
is MIT, with `Copyright (c) 2025 Mario Zechner`.

Native store ownership uses `proper-lockfile` 4.1.2 from
[Made With MOXY](https://github.com/moxystudio/node-proper-lockfile).
It is MIT licensed, with
`Copyright (c) 2018 Made With MOXY Lda <hello@moxy.studio>`.
The MIT permission and disclaimer terms reproduced above apply to both packages.
Bundled dependencies retain their own upstream licenses and notices.

## Lucide

The dashboard icon assets are derived from `lucide-static` 1.60.0.
Published tarball integrity and per-asset hashes are recorded in
`docs/assets/lucide-provenance.json`.

Copyright (c) 2022 Lucide Contributors

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
| OpenClaw | [OpenClaw](https://github.com/openclaw/openclaw/blob/main/ui/public/favicon.svg) | MIT licensed; SMIL animation removed to retain the static upstream rest pose |
| Hermes | [Ollama launcher asset](https://github.com/ollama/ollama/blob/main/app/ui/app/public/launch-icons/hermes-agent.svg) | Ollama is MIT licensed; downstream vectorization of the portrait published by the MIT-licensed [Hermes Agent](https://github.com/NousResearch/hermes-agent) repository |
| Pi | [Pi press kit](https://pi.dev/press-kit), [primary color SVG](https://pi.dev/logo-auto.svg) | Official color pixel mark from the MIT-licensed Pi project retained at `docs/assets/harness-logos/pi-color.svg`; the app places it on the same circular black badge as the black-and-white variant, preserving matching canvas dimensions, padding, and mark bounds, and uses it by default for Pi Durable. The existing circular black-and-white badge remains an alternate Pi Durable icon and the Pi CLI icon |
| Cursor | [Cursor favicon](https://cursor.com/favicon.svg) | Official logomark; unmodified |
| OpenCode | [OpenCode brand guidelines](https://opencode.ai/brand) | Official pixel logomark reconstructed from the published brand “O”; two-tone fills retained |

An open-source repository license does not transfer ownership of the underlying
brand marks. The Codex-specific terminal mark above is retained with its
community-source provenance and must be used only to identify the Codex harness.

The MIT-licensed sources above carry these copyright notices:

- Copyright (c) 2023 LobeHub
- Copyright (c) 2026 T3 Tools Inc.
- Copyright (c) 2026 OpenClaw Foundation
- Copyright (c) Ollama
- Copyright (c) 2025 Nous Research
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

## Browser and computer automation

Woven Matter embeds [Peekaboo](https://github.com/openclaw/Peekaboo) Automation Kit
at `260fc35320d6c350af503338b944d68311e2bebb`, under MIT, copyright 2025 Peter
Steinberger. AXorcist and the Swift support-library licenses are reproduced in
`app/App/ThirdPartyNotices.txt`, which is included in the application bundle.

Browser automation bundles `playwright-core` 1.64.1 from
[Microsoft Playwright](https://github.com/microsoft/playwright) under Apache-2.0
and `ws` 8.22.0 from [websockets/ws](https://github.com/websockets/ws) under MIT.
Their upstream licenses remain in the bundled Node dependencies. Playwright
connects to Woven Matter’s pinned CEF rather than installing another browser.

## Sparkle 2.10.0

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
