# Bots

A bot is a long-running agent with its own Linux container. It keeps its files,
memory, browser sign-ins, and services between conversations, so you can hand it
ongoing work: watching a project, running a dev server, or coming back to a task
on a timer. Bots run on Pi Durable and use the models you connect in Woven
Matter.

Every set of bots starts with **Admin Bot**. Ask it to create, rename, or
organize other bots, or create one yourself.

## Choose where bots run

Bots run on one machine at a time: this Mac, another Mac, or a Linux machine on
your tailnet.

1. Open **Settings → Bots**.
2. Under **Where bots run**, choose a machine in **Run bots on**, then confirm
   **Run bots there**.
3. On the first run, sign in to a provider in **Subscriptions & API Keys** if you
   haven't yet, then choose Admin Bot's model and select **Use this model**. New
   bots use that model by default.

Each machine runs bots in its own way:

- **On a Mac**, Woven Matter runs an Ubuntu virtual machine using Apple's
  Virtualization framework. This needs Apple silicon. The first start downloads
  Linux for the VM, which takes a while.
- **On Linux**, Woven Matter installs its own Docker Engine, separate from any
  Docker you already use. Installing it needs the SSH account's passwordless
  sudo once.

Moving bots to another machine stops them where they were running. Bots, their
files, and their conversations stay on the machine they were made on. Choose
**Off** to stop bots without removing anything.

### Install on another device

To run bots on a machine that isn't set up yet, open **Install on another
device** in Settings → Bots and choose **Find devices**. It lists the Macs and
Linux machines online on your Tailscale network and what each one needs:

- **No Woven server yet** (Linux): enter an SSH user if it differs from your
  own, then choose **Install bots**. This installs the Woven server with bots
  over Tailscale SSH. The machine doesn't need to be a workspace; you can add a
  workspace to it later from Settings → Workspaces.
- **Woven Matter isn't connected** (Mac): download Woven Matter on that Mac and
  open it, pair it from this Mac in **Settings → Apple Devices**, then finish the
  setup card on that Mac. See [Apple devices](apple-devices.md).
- **Ready**: choose it in **Run bots on**.

An install keeps running if you close Settings. If it fails, the device shows
**Needs attention** with the reason, and you can try again once it is fixed.

## Work with bots

Bots appear in the sidebar under **Bots** (or **Bots on** a machine's name when
you have bots on more than one). Choose **New bot** to create one. Each bot has
a main channel; start a thread from any message to work on something separately.
Right-click a bot to **Rename** it, **Move to group**, or **Delete…** it. A
deleted bot can be restored from Settings → Bots. Admin Bot's name is fixed.

Bot conversations are saved in your library, so they appear on every paired Mac.
They stay out of your regular chat lists.

## What a bot's container can do

- **Its own computer.** Each bot gets an Ubuntu container with a browser, Git,
  Node, Python, and build tools. The bot has full administrator access inside
  its own container, and nowhere else.
- **Internet, but not your network.** A container can reach the internet. It
  cannot reach your tailnet, private networks, the host machine, or other bots'
  containers.
- **No credentials inside.** Provider sign-ins and API keys never enter a
  container. Bots use the subscriptions and API keys of the machine they run on.
- **Previews.** A bot can share a web server running in its container. It gives
  you a private HTTPS address on your tailnet; it is never public.
- **Services that come back.** A bot can register long-running services, such
  as a dev server. They restart whenever its container starts.

A bot's container stops after 15 minutes without activity. Its next tool call
starts it again, with its files, browser profile, open tabs, and registered
services restored. Viewing a bot's chat or one of its previews counts as
activity.

## Settings for a machine's bots

In Settings → Bots, choose the machine under **Where bots run** to open its page:

- **Profiles**: the main model for a bot's channel and threads, fallback models
  for when the main model hits a usage limit, a pool of models for subagents,
  and the model that names threads.
- **Bots and teams**: each bot's name, profile, and optional team. A manager
  hands work to the bots on its team, and an optional orchestrator oversees
  every bot. This page also has each bot's memory, **Rebuild**, and deleted bots
  you can **Restore**.
- **Resources**: how much memory all bots share, how much each bot may use, and
  one disk limit for all bots' files.
- **Subscriptions & API Keys**: the sign-ins bots on that machine use.
- **Manage**: **Restart bots**, **Update bots**, and, for a Linux machine,
  **Update server…**. Updating stops running work, saves a snapshot of each bot,
  updates it, and rolls back if something fails.

**Rebuild** recreates a bot's container from a clean image. Its files, restart
list, browser profile, memory, and conversations stay.

## Woven MCP for bots

Bots can use Woven MCP tools such as notes, calendar, conversation history,
Library, timers, and sessions on your workspaces. Turn this on with **Give bots
Woven MCP** in **Settings → Woven MCP → Bots**, and choose **Tools for bots**.
Each bot gets its own key, so its calls are attributed to it. Under **Bot keys**,
**Revoke** stops a bot's calls at once; **Reinstate** gives it a new key.

## Keep versions in step

When your devices run different versions, Settings → Bots shows **Versions
don't match**, which opens Settings → Updates. There, **Update everything** or
**Update Woven Matter** updates each Linux host, other Macs, each Mac's bots VM,
and the bots themselves. See [Updates](updates.md).

Next: [Apple devices](apple-devices.md) or [Remote workspaces](remote-workspaces.md).
