# V02 — incremental members in an accepted private share

Status: owner add/delete observed across accounts. A normal participant
relationship/save insertion crashed in its first isolated run; a separate
explicit existing-share assignment succeeded across accounts. See the
[first result](../results/v02-incremental-shared-members-2026-10-26.md) and
[explicit-assignment result](../results/v02-participant-explicit-members-2026-10-26.md).
Do not continue the crashed run with participant deletion or replay its write.

This CLI laboratory case tests normal Core Data relationship/save mutations
after A has been shared with another account. It uses a new synthetic V02 run:
owner A/B live in the private store, the accepted participant sees only A in
the shared store. Each side reopens its original store pair for its stage.
There is no explicit share call for a new child and no GraphEvo facade or
model change.

## Stages and expected graph

First execute the [initial V02 setup](v02-cross-account-smoke.md) through
`participant-accept` only, with a new run UUID. Do not execute its
`participant-edit` stage: this case starts with A-001=`alpha` and A-002=`beta`.
Then use one new mutation case UUID on both devices with
`--v02-run-id <RUN> --v02-case-id <CASE> --v02-development-verified
--v02-window 90` and the following roles in order:

| Start observer first | Start writer after `readyForWriter=true` | Target |
|---|---|---|
| XR `participant-see-owner-add` | iPad `owner-add` | A-003 linked to A-root; A-001=`alpha-owner-updated` |
| XR `participant-see-owner-delete` | iPad `owner-delete` | A-003 absent; inverse link removed |
| iPad `owner-see-participant-add` | XR `participant-add` | A-004 linked to A-root; A-002=`beta-participant-updated` |
| iPad `owner-see-participant-delete` | XR `participant-delete` | A-004 absent; inverse link removed |

Pass each role with `--v02-mutation-role <ROLE>`. The observer must retain the
exact previous phase, publish readiness with an unfinished report, and remain
alive while the writer runs. Wait for both final reports before the next pair.
Each stage reserves its role before a write or observation so it cannot replay
after interruption. A failed stage is not silently retried. A new run is needed
if its mutation outcome is uncertain.

If the first participant observer misses the owner addition within its bounded
window but the owner's report proves the local save, retain both reports. A
separate read-only case may use
`participant-confirm-owner-add --v02-prior-case-id <FIRST-CASE-UUID>` on the XR.
It requires the first case's reserved observer state and the exact imported A4
against its original A3 identities, then samples the original stores for its
full window. It does not repeat the owner write or accept an invitation. The
owner may resume `owner-delete` in that **same new case** with the prior-case
argument, but only after the XR confirmation succeeds; each side copies its
own validated prior state and pins the same store identifiers. This separates
late recovery after reopening from a live import in the original observer.

Before every write, the store checks the public
`canModifyManagedObjects(in:)`, `canUpdateRecord(forManagedObjectWith:)` and,
for deletion, `canDeleteRecord(forManagedObjectWith:)` advice. It inserts the
new object into the actor's explicit Core Data store, connects it to A-root,
updates the selected child or deletes the added child, and saves the context.
It does not share the new object explicitly. The session checks exact members,
values, scopes, inverse links, cloud record/share identities, accepted RW
participants and unchanged B. Both processes sample their original stores for
the full window and detach before termination. Compare their retained report
DTOs; local saves and callback events alone are not cloud evidence.

The test suite checks CLI guards, every expected phase, store/scope separation,
identity preservation, one-shot mutation reservation and an already-open
observer's transition. Only real-device reports can establish cross-account
export/import. Keep protected identity and invitation envelopes outside Git.

## Separate explicit-assignment control

Use a **new** V02 run and case ID, with the original A3+B2 fixture accepted by
the participant. Do not run `participant-edit` or any of the normal mutation
roles above. Start `owner-see-participant-explicit-add`, wait for
`readyForWriter=true`, then start `participant-explicit-add` with the same run
and case IDs. The participant inserts an unconnected A-004 into its **shared**
store, saves it, calls `NSPersistentCloudKitContainer.share([child], to:
existingShare)` for A, links A-004 to A-root and saves again. The observer and
writer retain their stores for the full configured window. Require matching
A4 values, inverse links, record IDs and share IDs across accounts, unchanged
owner B2, and no run rows in the participant private store.

After both final reports pass, use the same run and case for a deletion pair:
start `owner-see-participant-explicit-delete`, wait for readiness, then start
`participant-explicit-delete`. This deletes A-004 through the participant's
shared-store context without another share call. The owner must return to
exact A3+B2; surviving identities and B must remain stable. Each role is
reserved once. A failed or interrupted write requires a new run, not replay.

An initial explicit-assignment attempt used the participant's private store
for the unconnected object. It returned `NSCocoaErrorDomain:134060` and is an
invalid comparison for adding to an existing share in the shared store. Its
separate fixture was retained and never reused.
