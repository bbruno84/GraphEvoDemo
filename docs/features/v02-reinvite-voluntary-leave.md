# V02 reinvitation and voluntary leave

The [first hardware observation](../results/v02-reinvite-voluntary-leave-2026-10-26.md)
recovered A after a new pending invitation and observed participant A3→A0 after
leave. Owner-only verification failed in both a 30-second check and a subsequent
120-second read-only check while all owner data remained intact. V02.7 is partial;
the lifecycle result required another test. The later
[old-link reacceptance](v02-old-link-reaccept.md) showed that the same pending
URL could restore A, followed by a separate owner revocation cleanup. The owner reports show the
nonowner as pending, whereas pre-leave XR snapshots show accepted; inspect
acceptance status separately from participant count.

This CLI-only framework control reuses the original V02 owner and participant
private/shared SQLite files after a completed revocation. It introduces no
GraphEvo sharing API and does not reopen the consumed read-only probe.

`V02LifecycleSession` owns the stages and reports. `V02CloudStore` uses public
CloudKit metadata and `NSPersistentCloudKitContainer` sharing APIs. The owner
starts with the exact edited five-row fixture, A and B owner-only, and reinvites
only the original authorized participant to existing A as private read-write.
Share and record identities remain pinned; B must remain unchanged.

Use the original `--v02-run-id`, a new `--v02-case-id`,
`--v02-development-verified`, and `--v02-window 60` for each stage. Launch a new
process for each role, using `--v02-lifecycle-role` in this order:

1. `owner-reinvite`: persists one invitation and retains its final report.
2. Transfer only the case-scoped sensitive envelope from owner app data
   `Library/Application Support/V02LifecycleLaboratory/Sensitive/<run>/<case>/private-invitation.json`
   into participant app data
   `Library/Application Support/V02LifecycleLaboratory/Inbox/lifecycle-invitation.json`.
3. `participant-reaccept --v02-input lifecycle-invitation.json`: validates run,
   case, owner, recipient, container, share identity and private RW metadata.
   Pending membership invokes acceptance once. Already accepted membership is
   recorded without another acceptance call. Initial absence and exact A3
   recovery are separate report fields; B and private-scope copies are forbidden.
4. `participant-leave`: requires the same case's completed recovery state and
   original store inventory. It reserves the mutation before calling
   `purgeObjectsAndRecordsInZone(with:in:completion:)` for only A's validated zone
   in an explicit shared-scope store. It observes the full window and requires
   known A3 before the operation and A0 afterward on the same stores.
5. `owner-verify-leave`: reads existing owner stores, requires A owner-only,
   and checks all five original records, values, links, share identities and B
   throughout the observation window. It performs no sharing mutation.

The original V02 invitation is never overwritten. Lifecycle envelopes have a
separate purpose and case ID; old invitations and wrong cases cannot reach
acceptance. Sensitive envelopes remain protected local files and must not be
published. Reports and traces contain no invitation URL or raw account IDs.
They live in `V02LifecycleLaboratory/Reports`; state in `State` prevents replay
of inviting, accepting, leaving, or completed stages after an interruption.
There is no fallback invitation, replacement store, owner purge, fixture repair
or automatic retry. A callback with no error is distinct from observed absence.
Owner retention requires its independent verification report.

Apple documents shared-store purge as the participation removal path in
[Sharing Core Data objects between iCloud users](https://developer.apple.com/documentation/coredata/sharing-core-data-objects-between-icloud-users).
The explicit shared store, private-user role, expected share zone and complete
participant fixture are mandatory guards before that API. This path must never
be generalized to a nil store, all stores, or an owner-private store.

Five focused lifecycle XCTest methods cover CLI and envelope compatibility,
leave guards, owner reinvitation with preserved sensitive evidence, both metadata
outcomes and same-store participant removal with anti-replay, and wrong-case or
old-envelope rejection. The full simulator suite has 83 passing tests. These
local and injected checks validate the instrumentation; they do not establish a
CloudKit lifecycle result. Keep hardware observations in a separate result file.
