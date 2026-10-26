# V02 — reinvitation and participant-initiated leave

Status: **V02.7 PARTIAL: reinvitation, reacceptance and participant A3→A0
observed; complete owner-only lifecycle criterion not satisfied**. The initial owner verification
retained A/B data but still exposed two participants for A and failed its strict
owner-only precondition. A subsequent 120-second read-only owner verification retained the same data
and the same two-participant A snapshot, and failed the same precondition.
The nonowner acceptance status in both owner reports was `pending` (raw 1),
whereas the XR reacceptance and pre-leave snapshots showed `accepted` (raw 2).
Participant count alone omits this meaningful public-metadata difference. Do not label the whole case passed or turn that failure into
a server-membership conclusion.

## Fixture and operation

This follows the [live revocation](v02-revocation-2026-10-26.md), retaining original
run `8A6E6A45-2D7D-44C9-B127-32A552C1F773` and introducing lifecycle case
`88DA5EBE-FBD8-4A71-8B0F-E6D959703807`. The owner is the iPad and the participant
is the different-account XR. The [lifecycle guide](../features/v02-reinvite-voluntary-leave.md)
describes the implementation. Neither device uses a replacement SQLite or the
permanently parked read-only write probe.

The owner began with five unchanged edited A/B records and owner-only shares.
It added only the original authorized XR to existing A as private read-write,
persisted the share, retained a new protected case-scoped invitation, and observed
A with two participants while B stayed owner-only. No fixture was rewritten and
the original invitation was preserved.

The XR opened its original stores with zero run objects. Metadata was pending;
the stage called acceptance once, then recovered exactly A's three edited
records with original values, relationships and normalized record/share IDs in
shared scope. B and private copies were absent. This is actual reacceptance,
not the separately instrumented already-accepted metadata path.

A new XR process reopened the same store identifiers and first recovered the
same exact A3. It invoked `purgeObjectsAndRecordsInZone` with the explicit
validated shared store and A's expected zone. The callback returned that zone
without error. The subsequent 60-second observation ended with A0. There was
no owner-private purge, nil-store operation, object rewrite or repeated leave.

The first owner verification reopened its original stores for a 30-second
readiness window. All five values, links, record/share IDs and complete B DTOs
matched the pre-reinvitation fixture; A's public Core Data share snapshot still
contained two participants, with the nonowner now `pending` (raw 1), rather than
the XR pre-leave `accepted` (raw 2). The stage reported `GraphEvoDemo.V02Error:5`
(`invalidFixture`) because it requires A owner-only before verification. Its
`ownerPreserved=false` is not evidence of lost data: the combined predicate also
requires owner-only membership, and the raw rows retain the unchanged data.
A subsequent owner process performed only a longer 120-second readiness check
(08:15:48–08:17:50 UTC). It again retained all five original values, links,
record/share IDs and unchanged B, but A still listed two participants with the nonowner `pending` (raw 1). It ended
with the same `invalidFixture` error. Both verification processes were stopped
after evidence retention. No repair, participant removal or other owner mutation
followed.

## Public API interpretation

Apple's [custom sharing flow](https://developer.apple.com/documentation/coredata/sharing-core-data-objects-between-icloud-users)
identifies the purge API as a way to stop participation, and describes deletion
of the shared-store object graph. It supplies no deadline for the owner's local
share participant list to reflect that action. The 30-second owner-only check
is an explicit laboratory criterion, not a documented API timing guarantee.
The observed callback and participant A0 do not establish the owner's server
membership state or prove a subsequent reopen cannot import A again.

Keep the facts separate: the supported operation returned, the participant
observed absence, the owner retained data, and the strict owner-only verification
failed in its window. Neither a propagation-delay explanation nor failed server
removal follows from these observations alone. No framework-internal analysis
is required for this distinction. The longer read-only verification retains its own failed report and does not
erase the first unmet precondition. The complete owner-only lifecycle criterion
remains open after both bounded observations.

## Source and retained evidence

App source `dec15fed83bfcc14faf29291b5009d04c1e8e088`; Swift source SHA256
`089c6b4dc3efe7da0c16e3776269800c9190f11a5fdade8e8eae4b7ca2c5116b`.
The pre-run simulator suite passed 83 XCTest cases. GraphEvo develop pin is
`4dc0a7f9a717ee535e9b630b998cd6c869a2d538`; deployment remains iOS 17.6.
The physical run used Xcode 27.1 (27A9275), Swift 6.4 in Swift 5 mode, the owner
iPad on iPadOS 27 and XR on iOS 18.7.10, with Development configuration.

All intervals are UTC on 2026-10-26:

| Stage | Interval | Final report SHA256 |
|---|---|---|
| owner-reinvite | 08:10:34–08:11:41 | `fe292208471928210d48cddea286853b26ab724847ab9c6f8e5ab0ece600c0ae` |
| participant-reaccept | 08:12:41–08:12:49 | `6c2def36965f26b67d1245457d18eebd99fee2cd1f2f105a3017f1c80d88cc15` |
| participant-leave | 08:13:05–08:14:09 | `e8be392ba88c45822127d6d30aae82b5467329a9e9ff985339c35cb03e7964ed` |
| owner-verify-leave, first | 08:14:17–08:14:52 | `2d4889d79cc2fea731ef26876d3d33fbe45b0b93500c2b747a2d8d3e3fb1cd24` |
| owner-verify-leave, read-only retry | 08:15:48–08:17:50 | `56b1bcb72f36bcc92dc869bc44c49e7579d4a28b354792a24c62d56286e7f23e` |

The first three reports contain no stage errors. Both owner verification reports retain the fixture
error above; all five retain their final reports and detach their stores, with
zero trace-write failures or dropped trace entries. Independent raw-report
review recomputed these hashes and compared complete participant and owner
fixtures, links, identities and store inventories. Native event snapshots are
bounded and do not certify server completion.

Private archive:
`2026-10-26-V02-lifecycle-88DA5EBE-FBD8-4A71-8B0F-E6D959703807` under the local
GraphEvoLab evidence directory. Raw device reports, logs and sensitive transport
artifacts remain outside Git. The separate [read-only post-leave probe](../features/v02-post-leave-recovery.md)
has a [bounded hardware result](v02-post-leave-recovery-2026-10-26.md): no
automatic recovery across 180 seconds and pending XR metadata from the old URL,
without accepting again. It does not replace these retained strict-criterion
failures or establish whether a future acceptance could regain A.
No GraphEvo facade lifecycle, general access
revocation deadline, offline behavior or complete V02 matrix is certified.
