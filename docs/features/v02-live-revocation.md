# V02: app-visible live revocation

Status: **instrumented and locally tested; device result is separate**. This
control tests whether A disappears from the participant's original open stores
after the owner removes that participant, while owner A/B remain intact. It
does not investigate Core Data internals or implement leaving/reinvitation.

Use the original initial-smoke run and authorized owner iPad / different-account
XR. The [read-only probe result](../results/v02-readonly-fresh-replica-2026-10-26.md)
left A read-only and permanently parked its isolated probe path. Revocation can
start from accepted RO or RW membership. This watch uses the **normal original
XR stores**, never the consumed probe stores. It performs no participant writes.

## Supported operation and functional evidence

Apple's [custom sharing flow](https://developer.apple.com/documentation/coredata/sharing-core-data-objects-between-icloud-users)
supports managing participants through the share and persisting changes with
Core Data. `owner-revoke` looks up the existing A share and exactly the participant
ID from the original protected invitation, calls `removeParticipant`, then
`persistUpdatedShare`. It never purges the owner zone, deletes owner objects,
changes B, invites another user or accepts another invitation.

The positive participant criterion is not a new empty store. The watcher must
first retain the exact edited A fixture with accepted RO/RW permission, mappings
and relationships, and publish `readyForOwnerAction`. The coordinator then starts
the owner action while that watcher remains alive. The watcher samples the same
original container/stores until the bounded window ends and reports whether it
observed complete A then no run objects in either scope, with unchanged store
identifiers. B must never appear in the participant's baseline. Before/after
data, known local object IDs and normalized cloud identities remain retained.

The owner must retain all five original values/links/record/share identities,
with A now owner-only and B completely unchanged. A separate owner-verify stage
reopens those existing owner stores without repeating participant removal.
Functional reports from both devices must be independently correlated. No
latency, universal privacy, graph lifecycle or overall V02 conclusion follows
from one bounded case.

## CLI and coordination

Common arguments, using one new case UUID on both devices:

```text
--v02-run-id 8A6E6A45-2D7D-44C9-B127-32A552C1F773 --v02-case-id <NEW-CASE-UUID> --v02-development-verified
```

| Device / role | Suggested additional arguments | Required sequence |
|---|---|---|
| XR / `participant-watch` | `--v02-revocation-role participant-watch --v02-window 180` | Wait for `readyForOwnerAction=true` with `finished` still absent |
| Owner / `owner-revoke` | `--v02-revocation-role owner-revoke --v02-window 30` | Start only after the matching live XR case is ready |
| Owner / `owner-verify` | `--v02-revocation-role owner-verify --v02-window 30` | New owner process after the removal report is retained |

Windows accept 1–600 seconds, default 120. Readiness has its own bounded
read-only wait; the full watch window starts after the positive baseline and
readiness signal. These windows do not time out native APIs. The coordinator
must verify the matching case/process is still live before owner action; the
app cannot inspect another device's process table. `readyForOwnerAction` in a
completed report is historical evidence, not authorization to start late.

Both sides verify their original account bindings. Missing original stores do
not create replacement replicas. Watch and removal cases reserve progress to
prevent replay after interruption. Failure to observe the complete initial A
fixture cannot produce a removal result. A reserved removal is not automatically
retried, and owner-verify never invokes `removeParticipant`.

## Reports and paths

New reports/state use `Library/Application Support/V02RevocationLaboratory/`:

- `Reports/<run>-<case>-<role>-<stage>.json` and sibling `.trace.jsonl`;
- `State/<run>-<case>.json` reserves the case and pins owner snapshots/store IDs.

Store paths remain under `V02Laboratory/Stores/<run>/participant/` or `owner/`.
The consumed `V02PermissionLaboratory` probe paths are untouched. Original
sensitive bindings/invitation are read locally, never printed or overwritten.

Reports retain readiness time, exact pre-action rows and IDs, first absence
time, bounded samples, final rows, permissions, native events and structured
errors. Up to 64 samples and 128 event snapshots are retained, with drop counters.
Owner mismatch is retained separately and never silently repaired. The snapshot
comparison is the primary criterion; event success alone is insufficient.

A public persistent-history token is captured before readiness when available.
After the window, a bounded shared-store history supplement counts changes for
the known pre-action object IDs. It is accessory observation only, not a barrier,
proof of causal server deletion or a requirement for the data transition.
Unavailable or truncated history is explicit and must not be read as no changes.
No raw history token, account identity or invitation URL is published.

At completion the session detaches stores and the coordinator explicitly stops
the process after evidence retention. There is no purge, wipe, local deletion,
reinvite, leaving or restoration operation. Final report failure is inconclusive;
an earlier Running checkpoint is not completed evidence.

## Local verification

Five new tests cover CLI/case guards; rejection of initial/fresh absence and
replacement-store claims; positive baseline/readiness before the action; a full
same-container observation window with zero participant writes; no watch/removal
replay; preserved owner data and separate verification; and a real local SQLite
history anchor/deletion check. The app suite passes 78 tests. Local/fake checks
are not cross-account revocation evidence. The functional hardware result must
be recorded separately from these tests.
