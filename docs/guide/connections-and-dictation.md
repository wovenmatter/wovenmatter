# Connections and dictation

## Subscriptions and API keys

Open **Settings → Subscriptions & API Keys** to connect model providers and web
search. Account links in Usage and in Pi Durable's settings lead here.

**Sign in on** at the top chooses the machine. Subscription sign-ins (ChatGPT,
Claude and Grok) belong to the machine you sign in on and are never copied to
another one; sign in again on each machine that needs them. API keys are
shared with every machine.

**Sign in** shows the provider's steps beneath its row: ChatGPT shows a link
and code, and **Sign in with Claude** opens Anthropic's sign-in, after which you
paste the code it returns and choose **Continue**. Saved rows show the account
or key label and the date added, never the secret. **Remove** disconnects a
connection.

Pi Durable, the bots and Usage use these connections. Codex, Claude Code, Grok
Build and OpenCode keep their own sign-ins.

## GitHub

**Settings → GitHub** holds one SSH key and a Git identity for your agents and
bots on every machine. **Generate a key** makes one, or **Paste an existing
private key**, then **Add key on GitHub** with the public key. Agents never
receive the key file; the server uses the key for them.

## Mac permissions

**Settings → Permissions & Access** lists the macOS permissions agents use on
this Mac, such as Accessibility and Screen Recording for the computer tool.
Choose **Allow** on each one, or **Allow all**. Some are switched on in System
Settings; if a row offers **Reopen**, reopen the app afterwards. See
[Mac access](../MAC_ACCESS.md).

## Dictation

Dictation uses Apple's on-device speech recognition on your Mac. No account or
API key is needed, and audio is never saved or sent anywhere.

Click the microphone in a conversation or note, or press **⇧⌘D** in the focused
editor. Allow microphone access the first time. Apple may need to download a
language the first time you use it; after that, dictation works offline.

Recording continues while you move between conversations and notes. Stop it in
the editor where the text belongs: the finished transcript is inserted at the
caret as one undoable edit, and it is never sent for you. If the text cannot
be inserted there, it is kept so you can insert or discard it.

**Settings → Dictation** sets the language; **Automatic** follows your preferred
languages. **History** lists your finished dictations, newest first. A
transcript is saved there when you stop recording; audio is not. History is
part of your library, so it syncs to your other machines.

Next: [Notes and data](notes-and-data.md).
