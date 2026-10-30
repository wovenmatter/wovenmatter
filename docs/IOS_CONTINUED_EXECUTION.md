# Quick Chat lifecycle and remote execution

Quick Chat is a small foreground conversation feature powered by Pi Durable.
It supports note operations, public web search/reading through a device-owned
Exa connection, dictation and explicit note references. Model connections and
sign-ins remain device-local. It has no shell, Python/WASM, code mode, subagents,
goals, timers, calendar execution, browser automation or computer control.

When the app backgrounds, a short UIApplication allowance lets it save and
interrupt an in-flight Quick Chat response. Saved request identities and receipts
survive reopening. Resume is explicit and cannot race interruption cleanup.
There is no continued-processing task registration or background agent promise.

Earlier device-agent conversations are retained as history. Their saved runtime
checkpoints are not opened or resumed as Quick Chat. Earlier phone-owned tasks
keep their ownership and remain visible; users must explicitly choose a Mac or
Linux agent before saving a replacement schedule. They never migrate silently.

Mac and Linux work belongs to the selected workspace. Pair once with the central
Mac using its QR/link, with both devices on the same Tailscale network. Woven
also keeps per-device, revocable workspace credentials in the phone Keychain.
Previously authorized direct Linux control does not require a reachable Mac.
Closing or suspending the phone does not stop accepted remote work.

Notes retain their existing local saves and coalesced synchronization. Normal
network loss preserves direct grants and pending writing. Explicit Unpair clears
the grants. Shared-library synchronization resumes when central is reachable;
no Linux owner depends on a viewing phone to publish its history or new folders.

The Debug-only `WOVENMATTER_DEVICE_RUNTIME_SMOKE=1` mode runs the actual bundled
SDK with synthetic inference and an isolated local note store. Its report in
`Documents/runtime-smoke.json` verifies native notes, the restricted tool registry,
and request replay. It never opens personal data, provider services or Keychain.
Real sign-ins, Tailnet ACLs, microphone/camera permissions, physical-device network
transitions and distribution signing remain separate acceptance checks.
