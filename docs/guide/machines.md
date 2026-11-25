# Your machines

Woven Matter runs on your Macs and Linux machines. Each one runs its own Woven
server and keeps a full copy of your library: chats, notes, pages, sheets, apps,
schedules and settings. Every Mac and Linux machine on your Tailscale network
that runs the server is one of your machines. Tailscale decides who may
connect, and a machine shared in from someone else's tailnet is refused.

## How machines join

A machine joins by itself. Each server looks for the others on your tailnet
and starts syncing with every one that answers. Changes made while a machine
is offline sync when it is back.

The sidebar shows this Mac under **Local workspace**, then one section for each
other machine, online or offline, under its name. Each section lists that
machine's agents and folders. A chat started from a machine's section runs on
that machine.

**Settings → Workspaces** lists your other machines under **Remote workspaces**
with their status. A machine that is switched off stays listed as **Offline**.

## Add another Mac

Install Woven Matter on the other Mac and open it. Both Macs need Tailscale
connected to the same tailnet. The Mac joins your machines on its own.

## Add a Linux machine

Woven Matter installs the server on a Linux machine over SSH. You need:

- an x86_64 or arm64 Linux machine with systemd, on your tailnet
- SSH access to it from this Mac with your own SSH setup; Woven Matter does
  not store SSH keys or ask for passwords

Then:

1. Open **Settings → Workspaces** and choose **Add workspace**.
2. Under **Tailnet machines**, choose the machine, or type its Tailscale name
   in **Tailscale machine**. Enter a **Remote username** if it differs from
   your SSH configuration.
3. Choose **Inspect machine**.
4. Read the access note, select **I understand this workspace's access to the
   machine**, and choose **Create workspace**.

The Mac copies the server it carries to that machine and starts it as a
systemd user service, `woven-server`, under the SSH account, and turns on
lingering for that account so the server keeps running after you log out
there. Nothing is
downloaded on the Linux machine. Agents there run as that account with its
full permissions; there is no container around them. When the server answers,
the machine joins your machines and Woven Matter offers to set up its
harnesses.

The Linux server keeps running when your Macs are off. Its chats, scheduled
tasks and databases carry on there.

## Manage a machine

Open a machine in **Settings → Workspaces** to see its status and agents.
**Set up harnesses** installs or signs in to harnesses on it. Its **Manage**
menu has:

- **Start**, **Stop** and **Restart** for its server. Only a Linux machine's
  stopped server can be started from here; a Mac starts its own.
- **Update server**, for a Linux machine: replaces its server with the
  release this Mac carries. Its data stays.
- **Logs**: the server's recent log.
- **Remove…**: removes the machine, its chats and its folders from every
  machine. On a Linux machine it first stops and uninstalls the server there.
  This cannot be undone. There is no way to hide a machine without removing
  it.

## Chats on another machine

A chat belongs to the machine it runs on for its whole life. While that machine
is online, its chat streams live straight from it. While it is offline, the
chat shows its saved messages and you cannot send until it is back.

## Keep versions level

Machines on different Woven Matter releases still show online to each other,
and most releases keep syncing. When a release changes the library, the
machines say **Can't sync right now** until the one behind is updated; in
Settings that line opens Settings → Updates, which lists the release each
machine runs. See [Updates](updates.md).

Next: [Bots](bots.md) or [Updates](updates.md).
