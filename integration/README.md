# Companion integration checks

Run `scripts/test-companion-integration.sh` on macOS. All state is temporary and
all provider work is a controlled fake. No user workspace, tailnet configuration,
credentials, provider service or Docker lifecycle is touched.

The suite connects the actual iOS `MobileStore` and `MobileSyncEngine` to the
actual authenticated `CompanionWorkspaceAPI`, durable command dispatcher and
canonical SQLite database through the production `CompanionHTTPServer` listener
and HTTP parser, using URLSession on a temporary loopback port under the real
`/wovenmatter` mount. A test-only transport maps a valid HTTPS fixture credential
to that loopback endpoint; production HTTPS restrictions remain intact. Pairing,
authorization and workspace checks pass through HTTP. Fault injection loses
replies after commits and cancels an actual URLSession request while accepted
Mac work is suspended. This suite needs permission to bind a loopback socket.

It verifies offline rich note/folder capture and restart; lost mutation receipts;
base/local/remote conflict preservation; deletion and recovery identity; workspace,
protocol and revocation checks before outbox delivery; fresh note revisions before
agent commands; new-session creation plus the first selected-note prompt with
lost acknowledgements and restarts between both phases; GET-only command receipt
recovery without automatic unsent execution; and stopped-host rejection of
new requests without canceling accepted Mac-owned work.

Related coverage lives in shared package tests, `CompanionWorkspaceTests`, the
iOS package tests, `scripts/test-note-drafts.sh`, `scripts/test-note-editor.sh` and
`scripts/test-note-socket.sh`.
