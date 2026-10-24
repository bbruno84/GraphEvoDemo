# V01 T6 — observer deadlock fixed; same-iPad recovery observed

Classification: **the reproduced laboratory deadlock was diagnosed and removed;
distinct owner-only share zones and fresh-store recovery were observed on one
iPad**. This is preliminary same-device evidence, not independent-device recovery,
cross-account sharing, selective download, or GraphEvo integration verification.
No iPhone was used in this investigation.

Subsequent result: a separately authorized
[independent iPhone reader](v01-t6-independent-reader-2026-10-24.md) later
recovered this writer's exact fixture and share identities with the same binary.
The iPad-only diagnosis and same-device observations below remain unchanged.

## Diagnosis before the fix

The [earlier attempts](v01-t6-2026-10-23.md) remain preserved as inconclusive
observations. They lacked independent callback-entry tracing. A new iPad writer
run, `07132211-4640-4609-9423-1CFB8C231FAE`, used opt-in JSONL tracing in source
`378221e`, app Swift SHA256
`ddfe7dd1407ed1ff2371bfbc84b84eda7a6fcbe17e8a3724e4422805bbd10b15`.

On 2026-10-24 UTC, the trace recorded `runStarted` at 08:07:13, then root-fetch
start/end and `shareCallEntered` at 08:07:17. It recorded neither
`shareCallReturned` nor callback entry nor the first scheduled MainActor
heartbeat. The process remained alive. This distinguished an invocation that
had not returned from a task merely suspended awaiting a callback.

The coordinator attached LLDB interactively, waited for the process to stop,
and captured all thread backtraces. The main thread waited in
`_PFRequestExecutor wait` inside
`NSPersistentCloudKitContainer shareManagedObjects:toShare:completion:`.
The CloudKit queue waited in `NSOperation waitUntilFinished` through
`_CFXNotificationPost` and `NSPersistentCloudKitContainer eventUpdated:` during
mirroring export. T6's NotificationCenter observer used `queue: .main`: native
event posting synchronously waited for the main queue while that queue was
occupied waiting for the share request. This established a cycle in the
laboratory's observer delivery. The debugger was detached and the process resumed
before explicit termination and evidence retention.

The fix registers the actual T6 observer through `T6EventDelivery.observe` with
`queue: nil`, snapshots event metadata on the posting queue into a nonisolated
Sendable value, and submits report updates through an asynchronous MainActor
task. No context, model, scope, resource, fixture, or share-call sequence was
changed. The root still comes from `viewContext`. This is an application observer
fix, not evidence of a general Apple API defect or a network diagnosis. It
explains the reproduced path without retrospectively manufacturing missing
evidence for each earlier attempt.

## After-fix writer and reader

The tested fix is `0df51b82a746804370306bb69826e5e19e1fe61a`, app Swift SHA256
`48792e052296391d14099d2167dff832bd08edd1e6300d45a6e228f0e06581b0`.
The coordinator verified the signed Development resource and installed only on
the physical iPad. Both after-fix stages ran without debugger attachment under
synthetic run UUID `649A26B8-C2A1-439B-A6B1-B7462E8E671D`.

| Stage | Start UTC | Final report UTC | Fixture save | Share operations |
|---|---|---|---|---|
| Writer | 08:14:39 | 08:15:24 | Yes, five members | A and B completed |
| Fresh reader on the same iPad | 08:16:12 | 08:16:16 | No | None |

All times are 2026-10-24 UTC. The writer used a 30-second post-share sampling
window. The trace shows A invocation at 08:14:43, callback entry and invocation
return at 08:14:47, and share persistence completion at 08:14:48. B invocation
started at 08:14:48, callback entry and return occurred at 08:14:51, and persistence
completed at 08:14:53. Callback entry preceded the corresponding invocation-return
entry in trace sequence; the instrumentation does not presume an always-later
callback. MainActor heartbeats continued after the fix. These timestamps describe
this observation and are not performance guarantees.

The writer's five-member fixture and the reader's entire-run snapshot match
exactly, including values, parent/children, record mappings and share identities.
Writer and reader have different store, stage and process identifiers and the
same recorded environment/source. The reader used a fresh SQLite path after the
writer process ended; it did not insert, restore, or create shares.

| Graph | Members | Observed zone name |
|---|---|---|
| A | A-root, A-001, A-002 | `com.apple.coredata.cloudkit.share.158AB0D4-0AC1-46EA-8ABA-5AC23CD329C2` |
| B | B-root, B-001 | `com.apple.coredata.cloudkit.share.B65658B5-5DB6-4A43-BAF6-D9DDCFF745E0` |

Every member's record zone matches its assigned share zone. Both share records
use the name `cloudkit.zoneshare`; the distinct zone names make the share identities
different. Each share reports one owner, zero other participants, and public
permission `.none` (raw value 1). Both reports have no errors, diagnostic write
failures or dropped trace entries. Completed native setup/import/export events
succeeded. Native event success alone is not the recovery evidence: the comparison
uses the actual five-member snapshots.

## Evidence, tests and limits

The original writer/reader JSON was independently read and compared before this
sanitized result was written. SHA256 values are:

- Writer: `25a3b8291a105af1aa167b928000590f265e2f7009fa3198893e4d7d54bdb617`.
- Reader: `52f02abef98c3bf396bcb66cda98ae2cff264dd4b84020bf12f956871fc4d3d4`.

Raw traces, backtraces, reports, manifests and build/install/console logs remain
outside Git under
`~/Library/Application Support/GraphEvoLab/Evidence/2026-10-24-T6-ipad-diagnosis/`,
separated into `before-fix/` and `after-fix/`, with `summary.json`.
Personal device/account/provisioning details are not published.

All **45 local tests passed**. The new regression uses the actual observer
factory and confirms that background notification posting returns while the
MainActor is occupied, with a bounded one-second wait. Three trace tests cover
ordering, concurrent bounded appends and preservation of an existing trace file.
Final log: `test_sim_2026-10-24T08-13-46-225Z_pid3076_554aeed6.log`;
result: `test_sim_2026-10-24T08-13-46-225Z_pid3076_75eee6b4.xcresult`.
These local tests are distinct from the physical iPad observations.

Fresh-store recovery on the same iPad does not establish recovery on an
independent device. No other-account participant, invitation, selective-download
mechanism, isolation of local stores by share, or v2 architecture was verified.
Both after-fix processes were explicitly terminated only after their final
reports were retained. No wipe, purge, store deletion, uninstall or invitation
was performed. The fixture and archived evidence remain retained.
