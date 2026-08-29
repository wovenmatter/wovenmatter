# Third-party notices

## Lucide

The dashboard icon assets are derived from `lucide-react` 0.563.0.

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

## Buzz-derived design and code

The local CLI discovery, two-stage installer, managed Node.js runtime design,
and portions of the remote container and OpenClaw supervisor design are adapted
from [Buzz](https://github.com/block/buzz). Buzz-specific relay, deployment, and
ACP-worker behavior is not included.

Copyright 2026 Block, Inc.

Buzz is licensed under the Apache License 2.0. A copy of that license is
included at [`LICENSES/Apache-2.0.txt`](LICENSES/Apache-2.0.txt).

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
| Grok | [xAI brand guidelines](https://x.ai/legal/brand-guidelines), via [Buzz](https://github.com/block/buzz/blob/main/desktop/public/harness-logos/CREDITS.md) | Official `Grok_Logomark_Dark.svg`; unmodified and used referentially as required by xAI |
| OpenClaw | [OpenClaw](https://github.com/openclaw/openclaw/blob/main/ui/public/favicon.svg), via [Buzz](https://github.com/block/buzz/blob/main/desktop/public/harness-logos/CREDITS.md) | MIT licensed; SMIL animation removed by Buzz to retain the static upstream rest pose |
| Hermes | [Ollama launcher asset](https://github.com/ollama/ollama/blob/main/app/ui/app/public/launch-icons/hermes-agent.svg) | Ollama is MIT licensed; downstream vectorization of the portrait published by the MIT-licensed [Hermes Agent](https://github.com/NousResearch/hermes-agent) repository |
| Pi | [Pi press kit](https://pi.dev/press-kit) | Official pixel mark from the MIT-licensed Pi project, placed on a circular black badge matching the product artwork |
| Cursor | [Cursor favicon](https://cursor.com/favicon.svg) | Official logomark; unmodified |
| OpenCode | [OpenCode brand guidelines](https://opencode.ai/brand) | Official pixel logomark reconstructed from the published brand “O”; two-tone fills retained |

An open-source repository license does not transfer ownership of the underlying
brand marks. In particular, Buzz records that it does not bundle the generic
OpenAI blossom after Simple Icons removed that mark at OpenAI's request. The
Codex-specific terminal mark above is retained with its community-source
provenance and must be used only to identify the Codex harness.

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
