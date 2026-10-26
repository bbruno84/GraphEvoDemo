# V02: read-only save and fresh accepted-share replica

Status: **fresh RO import observed; local save permitted despite negative advice;
owner unchanged for the bounded window**. See the
[retained result](../results/v02-readonly-fresh-replica-2026-10-26.md).
No server rejection or general enforcement claim follows. RW restore was not
executed and the probe stays permanently parked. Hardware outcomes remain
separate from local tests.
This focused follow-up addresses the first V02 read-only and fresh-replica
checks. It does not implement revocation, leaving, offline behavior or conflicts.
It reuses the [observed initial smoke](../results/v02-cross-account-smoke-2026-10-26.md)
run `8A6E6A45-2D7D-44C9-B127-32A552C1F773`: A-001 is
`alpha-from-participant`, A's other members are unchanged, and B remains owner-only.

Only the authorized owner iPad and different-account XR are involved. Device
operations, signed Development verification and explicit process termination
are handled by the coordinator. The deployment target is unchanged and all
used permission/sharing APIs are compatible with iOS 18.

## What is measured

Apple's [canUpdateRecord(forManagedObjectWith:)](https://developer.apple.com/documentation/coredata/nspersistentcloudkitcontainer/canupdaterecord%28formanagedobjectwith%3A%29)
indicates whether the current user can modify the backing CloudKit record.
It is not used as an application guard to suppress this experiment's write.
The separate [store permission API](https://developer.apple.com/documentation/coredata/nspersistentcloudkitcontainer/canmodifymanagedobjects%28in%3A%29)
is also diagnostic. A Core Data local save and later CloudKit export are
different operations; see [TN3163](https://developer.apple.com/documentation/technotes/tn3163-understanding-the-synchronization-of-nspersistentcloudkitcontainer).

After A's participant permission becomes read-only, the XR opens **two new
SQLite stores** in an isolated probe directory. It calls neither invitation nor
acceptance APIs. This tests rediscovery/import of a share that this account has
already accepted, separately from reopening the original participant stores.
Before writing, it must recover exactly A's three members in shared scope,
with no private copy or B in either scope, and accepted read-only membership.

The probe records `canUpdateRecord` and `canModifyManagedObjects`, sets A-001 to
`alpha-readonly-attempt`, and calls `context.save()` exactly once, even when
`canUpdateRecord` is false. It records:

- whether the save returned success or an error;
- bounded error domain/code chains, separately from stage errors;
- a fresh-context read of the persisted local value;
- the final local fixture after a full observation window;
- native export errors as observations, without assuming causal attribution;
- an independent owner observation of the original A/B values and identities.

If local save succeeds, the report explicitly says local save was permitted;
it does not call that read-only enforcement. If save fails, the error is retained
without inferring remote state from that failure alone. Reset after a failed
context save discards unsaved pending changes only. No saved value is silently
restored, no retry is attempted, and no participant store is purged.

## Implementation and guards

`V02PermissionSession` owns the separate stages and progress file;
`V02PermissionTypes` defines strict snapshot checks, save observations and the
restore gate. `V02CloudStore` reuses the same model/private/shared stack and the
fixed T6 notification handoff. Permission updates use the original A share and
the exact participant ID from the original sensitive invitation envelope. No
participant is added/removed, no public access enabled, and B is never updated.

Owner stages reopen the original owner stores under `V02Laboratory`. The current
account must match the original binding. Readiness waits use only fresh-context
snapshots until the expected values, identities and permission metadata appear.
A successful share update is not assumed to make `fetchShares` immediately
ready. Permission updates reserve their progress first to prevent replay after
an interrupted native operation. Each owner observation retains the full window;
any mismatch keeps `ownerUnchangedForWindow` false, even if the final snapshot
later matches, and retains the first unexpected owner snapshot.

The probe uses a new UUID and a permanently consumed local marker before opening
its stores. There is no probe-reopen stage. Reusing that run/probe pair fails,
even after interruption. The original participant stores are never used for the
attempt. Probe files remain retained for inspection and must never be opened
again after restoring read-write access: a locally saved/export-rejected write
must not be given another export opportunity by reopening that store.

## CLI and paths

Common arguments for one batch:

```text
--v02-run-id 8A6E6A45-2D7D-44C9-B127-32A552C1F773 --v02-probe-id <NEW-PROBE-UUID> --v02-development-verified --v02-window 60
```

The window is 1–600 seconds, default 60. Add `--v02-permission-role` as follows:

| Device / role | Behavior |
|---|---|
| Owner / `owner-readonly` | Reopen original stores; require the original edited fixture with RW membership; persist the one participant as read-only; wait for metadata and observe unchanged owner data |
| XR / `participant-readonly-probe` | New isolated private/shared stores; import already-accepted A with RO permission; one real local save attempt; full observation window; close and retain stores |
| Owner / `owner-observe-readonly` | Reopen original stores and observe original A/B with RO participant metadata for the full window; required before restore |
| Owner / `owner-restore-readwrite` | Requires the proof/stop gates below; restore only that participant to RW and observe unchanged owner data |

The coordinator can overlap the owner observation with the XR's post-attempt
window, but must stop the XR process before restore. The probe holds its owner
open for its whole window regardless of local save success or exact local data.
The readiness window precedes the separate observation window. These windows
do not impose timeouts on native opening or permission APIs. Retain interrupted
checkpoints and diagnose rather than silently retrying.

Paths relative to `Library/Application Support/V02PermissionLaboratory/`:

| Path | Meaning |
|---|---|
| `Stores/<run>/<probe>/participant-probe/{private,shared}.sqlite` | New consumed probe stores; never reopen |
| `ConsumedProbes/<run>-<probe>.json` | Permanent no-reuse reservation |
| `State/<run>-<probe>.json` | Owner progress, pinned original A/B and owner store IDs |
| `Reports/<run>-<probe>-<role>-<stage>.json` | Redacted stage reports |
| Matching `.trace.jsonl` | Bounded diagnostics |
| `Inbox/probe.json` | Coordinator copy of the stopped XR's final probe report for owner restore |

Original account bindings and the owner's sensitive invitation stay in
`V02Laboratory/Sensitive/<run>/`. They are read, never overwritten or printed.
Owner data stays in `V02Laboratory/Stores/<run>/owner/`. Reports retain no raw
account identities or private URLs; record/zone names and run-salted owner
digests support independent comparison.

## Restore is a distinct operator-controlled stage

After retaining the XR's completed probe report, the coordinator must explicitly
terminate its process and quarantine its consumed paths. Copy the original
final probe JSON into the owner's permission namespace as `Inbox/probe.json`.
Then add these restore-only arguments:

```text
--v02-probe-report probe.json --v02-probe-stopped-and-quarantined
```

The gate requires the matching run/probe, final retained report, detached
stores, consumed path, exact pre-attempt RO import, an actual attempt, recorded
fresh-context local state and no stage/trace-write errors. It compares that
pre-attempt fixture and identities against the pinned owner data and retains
the supplied report's SHA256. A prior completed owner observation with unchanged
data is also required. A Running checkpoint or mismatched probe is rejected.

The flag is an explicit coordinator assertion of process stop and permanent
quarantine; the app cannot inspect another device's process table. It is not a
CloudKit shutdown or server-quiescence acknowledgement. The owner is observed
again after restoring RW; unexpected values are reported without silently
rewriting them. No cleanup or automatic reopen of the probe is performed.

## Local verification and remaining limits

Seven new tests cover CLI/restore proof gates, scope/permission validation,
performing the write despite negative permission advice, error separation,
full-window probe lifetime, no reuse, owner change/restore sequencing and a real
local SQLite save read back through a new context with replay rejection.
The full app suite passes 73 tests. The local-only test has no native CloudKit
permission result and does not establish actual read-only enforcement.

Hardware classification must compare fresh RO import, local save/persistence,
export observations and owner state separately. Bounded owner non-mutation is
not a universal permission/lifecycle guarantee, and native export events alone
do not prove the fate of a specific write. Revocation/leaving, offline/conflicts,
account changes, other replicas, GraphEvo facades and broader V02 remain open.
