# V02 — reaccepting the invitation after voluntary leave

This focused stage answers whether the *same* private invitation URL can be
accepted after `purgeObjectsAndRecordsInZone` removed the participant's copy.
It uses the original participant private/shared stores and the protected
invitation from the completed leave case. It creates no new invitation, store
pair, graph object or CloudKit record. The [hardware result](../results/v02-old-link-reaccept-2026-10-26.md)
must be read separately from the local XCTest checks.

## Procedure

The previous lifecycle state must be `.left`, contain the exact three-row A
fixture, and pin the two original store identifiers. The new case ID must differ
from the previous case ID. The app validates the signed-in account binding,
container, recipient, owner, share, URL and original store identities. Its
opening snapshot must be empty. It reserves the new case before reading public
invitation metadata or attempting acceptance, so interruption cannot replay the
mutation automatically.

Use the original run and leave case with a **new** case UUID on the XR:

```text
--v02-lifecycle-role participant-rejoin-old-link
--v02-run-id 8A6E6A45-2D7D-44C9-B127-32A552C1F773
--v02-case-id <NEW-CASE-UUID>
--v02-prior-case-id 88DA5EBE-FBD8-4A71-8B0F-E6D959703807
--v02-development-verified --v02-window 120
```

The stage reads the old URL with `CKContainer.shareMetadata(for:)`. Only
validated `pending` metadata reaches
`NSPersistentCloudKitContainer.acceptShareInvitations(from:into:)` for the
explicit shared store. An already-accepted status, wrong identity or native
error stops the case; the app does not generate a replacement URL or retry.
Success requires exact recovery of the previous A records, values, inverse
links, record/share identities and shared scope, with no B or private copy.
The report distinguishes the pending metadata, API call and recovered data.

Run the existing `owner-snapshot` read-only stage with the same new case ID and
previous leave case ID to retain the owner's full A/B fixture and public share
status over a bounded window. A positive participant report alone cannot
establish owner retention. After both final reports are saved and the processes
stopped, the disposable share can be cleaned up through the existing
`participant-watch` / `owner-revoke` / `owner-verify` sequence with another new
case UUID. Do not purge owner data or reopen the consumed fresh-replica probe.

Reports contain no invitation URL or raw account identifier. The URL remains in
protected application data, and any copied envelope belongs only in the
private evidence archive outside Git. Local tests cover CLI guards, case
reservation, exact recovery, anti-replay and the already-accepted stop path;
they cannot establish cross-device behavior.
