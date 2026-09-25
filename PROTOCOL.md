# FairyStack companion protocol


`/companions` is the owner-authenticated pairing and command activity surface.
FairyStack for Mac (FairyStack.app) is a standalone signed/notarized Mac app with its own
Keychain entry, menu, login item and automatic-update channel. The command protocol has no microphone
permission and no Voice Feed dependency. A human creates
a ten-minute code on this page, pastes it locally into **FairyStack commands:
Off…**, and selects a workspace. The device credential is stored in Keychain,
expires after 90 days, and cannot submit commands. Workspace selection sets the
working directory, not a filesystem sandbox; commands have the Mac user's rights.
No remote password, 2FA, administrator approval, or elevation is provided.

Use the current FairyStack origin and ordinary session agent capability:

- `GET /api/companions` returns owned `devices`, the latest 100 `commands`, and
  `server_time`. Device fields: `id`, `name`, `root`, `last_seen`, `expires`,
  `revoked`. No credentials are returned by reads.
- `POST /api/companions` with `{name}` creates a pending device and returns
  `{id,token,expires_in:600}`. This is a credential: use the authenticated browser
  pairing surface rather than printing it in chat or constructing a login link.
- `POST /api/companions/commands` with `{device_id,mutation_id,command,cwd,
  timeout_seconds}` enqueues one noninteractive shell command on the explicitly
  named Mac. `cwd` defaults to `.` and must be relative to its local workspace;
  `timeout_seconds` is 10–1800 (default 300). A session capability fixes the
  originating `session_id`; a human principal supplies its owned active session.
  The session's `target_id` remains its app box, never the Mac. The returned
  receipt records both identities. Reuse `mutation_id` only for exactly the same
  delivery; conflicting reuse returns 409. A Mac must be online and idle.
- `DELETE /api/companions/commands/<id>` cancels a command.
- `DELETE /api/companions/<device_id>` revokes access and cancels active commands.

The device alone calls `/api/companions/device/poll`, `/report`, and `/revoke`
using its `fs_mac_` credential in `X-FairyStack-Agent-Token`. The ingress exception
is restricted to these three exact paths; the credential is rejected by all
operator APIs. Poll POST `{root}` claims a queued command atomically and returns
`{command:null|receipt,server_time}`. A claim is never replayed. Report POST
`{id,state,output,exit_code,error}` publishes capped output and heartbeats;
`{state,stop}` tells the client to stop cancelled/expired work. These requests have
8-second client request and 10-second resource timeouts. Network failure cancels
the local process group. Device activity is polled every 3 seconds. Missing
heartbeats become terminal failure after 25 seconds when observed; deadlines
apply to queued and running commands. Final result delivery has a 30-second
window; failure remains visible locally and the server's lost-worker state wins.

Commands use `queued`, `running`, `completed`, `failed`, `cancelled`, `timed_out`.
Only exit 0 can complete successfully. Output is capped at about 128 KiB and
stored in the owner-scoped receipt and the Mac's private activity folder; avoid
printing secrets. A native watchdog terminates the process group if the helper
crashes. Deliberately detached processes are unsupported. Reconnecting never
retries a claimed command; inspect the retained receipt and local files first.
Revocation or cancellation takes effect locally on the next bounded request, not
instantaneously. An app update also stops active commands.

