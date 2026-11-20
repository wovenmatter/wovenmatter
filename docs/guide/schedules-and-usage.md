# Scheduled work and usage

## Scheduled tasks, events, timers and wake-ups

A scheduled task runs a prompt in an agent session at a set time, once or on
repeat, continuing the same session or starting a new one each run. A timer
prompts a chat again after a delay, once or on repeat. A wake-up prompts a
chat at a set time with a message the agent left for itself. Ask an agent to
set any of these up with the Woven tools; agents can also list, change and
delete them.

Each entry belongs to the machine that will run it, and only that machine's
Woven server fires it. A Linux computer keeps running its entries while your
Macs are off. On a Mac, entries fire while its Woven server is running.

If a machine was off when an entry came due, the entry runs once when the
machine is back, then carries on from its next time; missed runs are not each
repeated. An entry whose chat is busy is tried again a little later. A
one-time timer or wake-up is removed after it fires.

**Calendar** in the sidebar shows scheduled tasks and calendar events on every
machine, and adds new ones. A calendar event only marks a time; it runs
nothing. **Scheduled Tasks** lists the tasks. Timers and wake-ups stay with the
chats that set them.

## Usage

**Usage** has two pages.

**Analytics** shows the tokens used by chats on your machines, by provider,
model, harness and reasoning level, over a range you choose. Each machine
records the usage of the chats it runs, and the records sync, so every machine
sees all of it. A machine on a different release shows that it needs an update
instead of its usage.

Switch the graph to **API estimate** to see what the same usage would cost at
public API list prices. This is an estimate for comparison, not your bill.
Models with no known price show as **Unpriced**.

**Limits** shows each saved account and the limits its provider reports, read
with this machine's sign-ins. Use **Manage subscriptions and keys** to add or
manage accounts in **Settings → Subscriptions & API Keys**. A limit the
provider does not report is never shown as zero or full.

Next: [Bots](bots.md).
