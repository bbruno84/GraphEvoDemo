# V09 — shared graph and native file probe

V09 is a disposable direct-Core-Data laboratory, separate from the GraphEvo
demo gateway. It uses one `NSPersistentCloudKitContainer` with private and
shared stores in the configured Development container. Each run has a new UUID,
local stores, reports and one-use write tickets. Never reuse a reserved write
after an interrupted or failed stage.

## Fixture and assertions

The model has one `V09Member` entity with optional, inverse Core Data
relationships. Its `kind` distinguishes Entity, Relationship, Action and
attachment equivalents without choosing a GraphEvo 2 schema. A and B each
start with a root, two entities, a directed relationship and an action with
two subjects and one object. The owner gives each graph a separate owner-only
share; only A is invited to the participant. All newly linked members must
retain A's existing share/zone. The participant must never receive B.

Attachments have filename, content type, SHA-256 checksum and a binary
attribute with `allowsExternalBinaryDataStorage` enabled. The 512-byte and
10 MiB payloads are deterministic synthetic bytes. Reports contain metadata,
size and checksum equality, never payloads or account identifiers.

Every stage reads both store scopes and retains a final JSON report in
`Library/Application Support/V09Laboratory/Reports`. Identity and invitation
envelopes live under `Sensitive/<run>`; transfer them only through the app's
`Inbox` on the specified device. Reports alone cannot substitute for the
other device's independent observation. Native import/export events are
diagnostic, not completion barriers.

## Execution order

Launch the app with a fresh UUID and `--v09-development-verified` on every
stage. The default observation window is 180 seconds; `--v09-window` accepts
1–600. Use physical devices with the Development entitlement and the intended
different iCloud accounts.

| Device | `--v09-role` | Additional arguments | Expected state |
|---|---|---|---|
| Participant | `identity` | — | Protected participant identity only |
| Owner | `owner-seed` | — | Two owner-only shares, A/B graph fixture |
| Owner | `owner-invite` | `--v09-input recipient.json --v09-invitation-authorized` | Private A invitation |
| Participant | `participant-accept` | `--v09-input invitation.json` | A only in shared scope |
| Owner | `owner-small` | — | 512-byte attachment in A |
| Participant | `read` | `--v09-side participant --v09-expect smallAdded` | Exact small file |
| Owner | `owner-large` | — | 10 MiB attachment in A |
| Participant | `read` | `--v09-side participant --v09-expect largeAdded` | Exact large file |
| Participant | `participant-replace` | — | Replacement 10 MiB file |
| Owner | `read` | `--v09-side owner --v09-expect largeReplaced` | Replacement recovered, B unchanged |
| Participant | `participant-delete` | — | Large file absent |
| Owner | `read` | `--v09-side owner --v09-expect largeDeleted` | Deletion recovered |
| Participant | `participant-graph-add` | — | Three new A members explicitly assigned to the existing share before linking |
| Owner | `read` | `--v09-side owner --v09-expect graphAdded` | New entity, relationship and action recovered |
| Participant | `participant-graph-edit` | — | Existing A entity edited |
| Owner | `read` | `--v09-side owner --v09-expect graphEdited` | Edit recovered |
| Owner | `owner-graph-delete` | — | Three added members deleted |
| Participant | `read` | `--v09-side participant --v09-expect graphDeleted` | Deletion recovered |

A fresh graph-only run may use
`participant-graph-add-only`, `participant-graph-edit-only` and
`owner-graph-delete-only` immediately after acceptance. The corresponding
read phases are `graphOnlyAdded`, `graphOnlyEdited` and
`graphOnlyDeleted`. These roles are for a new run without attachments; they
must not be used to repair a partially completed file-and-graph run.

For the separate disjoint-edit control, start a third fresh run and stop
after acceptance. Launch `owner-concurrent` on the iPad and
`participant-concurrent` on XR with the same
`--v09-start-unix <future-Unix-second>` value, 30–120 seconds ahead.
Each side must first observe the accepted baseline, reserve its own write
ticket and reach the coordinated start. The owner edits A Entity 1, the
participant edits A Entity 2, and both wait for `concurrentDisjoint`.
Discard a run if either side misses the start or fails preflight; a successful
combined snapshot demonstrates convergence under that timing, not the exact
internal ordering of CloudKit import and local save.

The participant identity file goes to the owner's `Inbox/recipient.json`;
the owner's private invitation goes to the participant's
`Inbox/invitation.json`. Never put their contents in source control, command
arguments or reports. A `read` stage is repeatable. Every other stage reserves
a ticket before its side effect, and a reserved stage must not be replayed.
Keep the app running until its report has `finished` and
`finalReportRetained: true`; then terminate it before the next stage.

The [physical-device result](../results/v09-graph-file-2026-10-26.md)
records successful file and graph runs, a partial failed sequential share
attempt, and a transient read-only reopen failure. Preserve those results
separately; do not replay their reserved writes.

An exact result checks values, links, checksums, store scope, every mapped
record's share zone, and B as the owner-only control. A bounded timeout is
inconclusive, not proof of permanent sync failure. Record the OS, toolchain,
source revision, device role, timings, errors and any separate follow-up run
when publishing results.
