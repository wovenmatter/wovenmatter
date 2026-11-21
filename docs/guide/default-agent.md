# Pi Durable

**Pi Durable** is included with Woven Matter on every machine. Choose it in
**New chat** like any other agent. It has file and shell tools, web search and
the Woven tools. You do not need to install Pi, Node or Claude Code.

## Connect providers

Open **Settings → Subscriptions & API Keys**:

- **OpenAI:** a ChatGPT subscription, an OpenAI API key, or both.
- **Anthropic:** a Claude subscription through **Sign in with Claude**, a Claude
  API key, or both. They are separate connections and billed separately.
- **Grok · xAI:** a Grok subscription or an xAI API key.
- **OpenRouter** and **OpenCode:** an API key.
- **Web search:** an Exa, Brave or Firecrawl key, then choose which one to use.
  Exa and Firecrawl can also read web pages; Brave only searches. Chats work
  without a search key.

Subscriptions are signed in on each machine. Use **Sign in on** at the top of
the page to choose the machine. API keys are shared with all your machines.
See [Connections and dictation](connections-and-dictation.md).

## Choose models

Open **Settings → Agents → Pi Durable**. After connecting a provider, choose
**Choose chat models** to browse its models and pick the ones that appear in
the composer. Filter by connection type or model lab, or show subscriptions
only. Choose a **Default model** for new chats.

**Applies to** chooses whether you edit the settings for all machines or for
one machine. For one machine, turn off **Use shared chat settings** to give it
its own models and defaults.

**More → Subagents** sets how many subagents can be active in one conversation.
It applies to new conversations; the parent agent does not count.

**More → Software** shows the installed Pi Durable SDK on each machine, with
**Check for updates** and **Update**.

## Where sign-ins are kept

Each machine keeps its own subscription sign-ins: in the Keychain on a Mac and
in a private file on Linux. They never enter your library. API keys are kept
sealed in your library separately for each machine, so only that machine can
open its copy. Agents never receive a key; the server uses it for them.

Signing in for Pi Durable does not sign in Codex, Claude Code, Grok Build or
OpenCode, and their own credentials are not imported.

Next: [Connections and dictation](connections-and-dictation.md).
