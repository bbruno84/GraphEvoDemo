# V02 — read-only recovery probe after participant leave

Status: instrumented, locally tested, and observed on hardware. The
[retained result](../results/v02-post-leave-recovery-2026-10-26.md) records
86 empty XR reads over 180 seconds, with old-URL metadata pending before/after.
It also retains the owner metadata identity-comparison limitation and the
initially missing owner share DTOs.
This focused control asks whether A appears automatically in a new XR replica
after the [partial leave result](../results/v02-reinvite-voluntary-leave-2026-10-26.md),
without another invitation or acceptance. It also reads metadata for the prior
case's existing URL. It does not test accepting that URL again.

## Implementation and paths

`V02LeaveRecoverySession` exposes only opening, snapshot, invitation-metadata
read and close capabilities. It has no fixture/save/invitation/acceptance/purge
operation. The participant opens a fresh private/shared pair under
`Library/Application Support/V02LeaveRecoveryLaboratory/Stores/<run>/<new-case>/participant-fresh`.
The original normal XR stores and consumed RO probe are untouched. The new path
is reserved before opening, permanently consumed even after an interrupted run,
and never reopened or automatically cleaned. Store IDs must differ from the
prior normal participant inventory and remain stable during the observation.

`owner-snapshot` instead opens the original owner pair in a new container/process,
checks its original store IDs and records complete public `fetchShares` snapshots
through the same bounded window. It compares retained A/B data and identities
without requiring A to become owner-only. All participant roles, permissions and
acceptance raw values remain in the row DTOs. Two listed participants do not
establish that the nonowner is accepted: inspect the acceptance status.

Both roles call `CKContainer.shareMetadata(for:)` for the prior protected URL
before opening and again after the snapshot window. Reports retain exact raw
participant status, role, permissions, public permission and normalized share ID,
plus container/owner/share matching flags. Errors retain NSError domain/code,
typed CKError code, retry-after value and bounded underlying/partial error codes.
Descriptions and partial-error keys are excluded because they may expose private
IDs or URLs. A metadata error alone is not evidence of access denial. The native
metadata APIs are not timed out by the snapshot window.

Report/trace paths are `V02LeaveRecoveryLaboratory/Reports/<run>-<new-case>-<role>-<stage>.json`
and sibling `.trace.jsonl`. Local read-only-stage reservations live in `State`.
Reports record provenance, stage/process IDs, fresh/prior store IDs, initial/final
rows, sample/empty counts, first exact A recovery and its rows, unexpected B or
private copies, errors and observation limits. Events are bounded at 128 with a
drop counter. Every snapshot is fresh; exact recovery does not end the window.
No history or internal framework analysis is part of this probe.

## Execution prerequisites and commands

Use original run `8A6E6A45-2D7D-44C9-B127-32A552C1F773`, prior lifecycle case
`88DA5EBE-FBD8-4A71-8B0F-E6D959703807`, and a NEW case ID on both devices.
The participant's prior state must be `.left`, with the exact recovered A fixture;
the owner's prior state remains `.invited`, with the original owner fixture.
Original account-binding files must match the signed-in accounts.

No new transport is required: each device reads its existing protected file:

- XR: `V02LifecycleLaboratory/Sensitive/<run>/<prior-case>/received-invitation.json`;
- owner: `V02LifecycleLaboratory/Sensitive/<run>/<prior-case>/private-invitation.json`.

The old invitation is validated against run, prior case, container and account.
It is never overwritten or printed. Do not substitute the initial-smoke invite.

Launch the XR in a new process with:

```text
--v02-leave-recovery-role participant-fresh --v02-run-id 8A6E6A45-2D7D-44C9-B127-32A552C1F773 --v02-case-id <NEW-CASE-UUID> --v02-prior-case-id 88DA5EBE-FBD8-4A71-8B0F-E6D959703807 --v02-development-verified --v02-window 180
```

For an independent owner snapshot, use the same arguments with
`--v02-leave-recovery-role owner-snapshot`. No `--v02-input` is needed. Each role
reserves its own new-case stage; do not repeat it after an interruption. Retain
final reports, detach stores and stop each process. Neither role adds a new
invitation, accepts existing metadata, seeds data, edits records or purges stores.

## Interpretation and local checks

Exact A3 in fresh shared scope with original values, links and cloud IDs is
positive automatic-recovery evidence for this configuration. A bounded negative
observation cannot establish permanent denial, the server's complete membership
state, or a delivery deadline. Partial/missing mapping snapshots and native
errors stay visible. Read public metadata status independently: pending is not
accepted, and neither its value nor an error alone answers whether automatic
import occurs. The previous V02.7 owner-only criterion remains a separate unmet
criterion; this probe does not redefine it as passed.

Five focused XCTest methods cover separate/new-case CLI routing, fresh-store
isolation and full negative window with anti-replay, recovery without early
exit despite a metadata error, owner pending-status snapshots without a false
owner-only failure, and missing-leave/error-privacy guards. The full simulator
suite passes 88 tests. These local/injected checks establish instrumentation,
not a CloudKit result.
