# V01 — relation/save membership and deletion observed on one iPad

Classification: **the relation/save-only 5→6→5 cycle and fresh-store recovery
were observed on the same iPad**. A-003 joined A's existing share/zone after
being related and saved, without an explicit share-extension call. Its later
deletion, A-001's update and all pinned original identities were recovered in
new private reader stores. The complete B DTOs remained unchanged.
This is preliminary same-device evidence: the independent same-account iPhone
was disconnected, and the other-account XR was not used as a same-owner peer.

## Configuration and source boundaries

The new run was `66DD1A44-6C01-4C5F-BB78-EE644BC3BF22`, using the unchanged T6
root/child model, one private writer SQLite, two initial owner-only shares, and
the authorized Development resource. No prior fixture was reused or modified.
Every reader opened a new private SQLite path on the same iPad, performed no
writes/sharing and fetched the whole run. Writer add/delete/reopen reused the
original store. See the [control guide](../features/v01-incremental-membership.md).

Preparation and original recovery used `36f2ce5`, app Swift SHA256
`276f17592af290c0e2eeaa3aa50baa34f63c8a2ba60de2b45857f5c227e69df0`.
Successful add, later readers, deletion and writer reopening used the bounded
precondition fix `0522aca`, app Swift SHA256
`e9624c218c928cf1b83305e5d32b39de5dbef4e218524defef6753ba1d9b2335`.
Both source boundaries remain explicit; this is not a single-binary trial.
Signed environment/provenance was verified by the coordinator. Personal account,
device and provisioning artifacts remain outside Git.

## Initial unstarted add and harness correction

The first writer-add stage, 07:11:37–07:11:39 UTC, stopped at the application's
prior-phase guard. Its initial five rows had the original values, links and
record IDs, but every `share` mapping was absent immediately after reopen.
`localMutationSaved` was false; the durable ledger was still `ready`, with no
added/deleted snapshots. No add/save or explicit sharing had begun. This is not
a native rejection of relationship-based membership.

Fix `0522aca` waits for complete pinned metadata using bounded read-only snapshots
before reserving `adding`/`deleting`. It retains the original `baseline` and the
final `precondition` separately. A timeout performs no mutation or reservation;
the full post-save window begins only after readiness and the save. Two
regressions verify delayed metadata and timeout with zero writes. The subsequent
authorized stage did not replay a reserved or attempted mutation and reused the
existing fixture/store. The failed preflight report remains preserved, SHA256
`b5a9e9547e71bdca52cd221e56f8fb3495ad4aa5674d00579dc87be8f149521e`.

## Successful stages

All times below are UTC on 2026-10-26. Seven successful final report hashes and
all writer/reader DTO comparisons were independently checked before this summary.

| Stage | Start | Finish | Exact members |
|---|---|---|---|
| writer-prepare / original | 07:07:16 | 07:08:01 | 5 |
| fresh reader / original | 07:11:11 | 07:11:16 | 5 |
| writer-add / added | 07:19:57 | 07:21:02 | 6 |
| fresh reader / added | 07:22:15 | 07:22:20 | 6 |
| writer-delete / deleted | 07:22:38 | 07:23:43 | 5 |
| writer-reopen / deleted | 07:24:24 | 07:24:27 | 5 |
| fresh reader / deleted | 07:24:35 | 07:24:40 | 5 |

After initial shares existed, the add stage inserted A-003/delta, assigned it to
the private store, linked it to A-root, changed A-001 to `alpha-updated` and saved
once. It retained the full post-save window. A-003's mapping and share matched
A's original zone/share. The added-phase reader recovered all six DTOs exactly,
including the new child's record identity and inverse links.

Deletion removed A-003 with one `context.delete`/save and retained its full window.
A-001 remained `alpha-updated`; A-root's children returned to A-001/A-002. Both
writer reopening and a third fresh reader recovered the exact updated five.
The changed A-001 value distinguishes this from a stale original five-row import.

All original A record/share identities remained pinned. Full B DTO arrays were
identical in every successful stage, including values, links, scope and identity/
permission metadata. Zone-name components remained:

- A: `com.apple.coredata.cloudkit.share.2BC84FF2-25A8-495C-B4DF-42D9D1261682`.
- B: `com.apple.coredata.cloudkit.share.02BFA1CF-6882-4815-87D5-EA275DC93C7E`.

There were exactly two application initial-share calls, one fixture save, one
add save and one delete save; existing-share extension calls remained zero.
No explicit `share([new], to: existing)` fallback was used. Writer store identity
was reused. All three reader store identifiers differed from one another and
from the writer; each reader retained an empty first run snapshot before import.
All successful stages had no errors, successful completed native events and
zero diagnostic write/drop counters. Native events alone were not used as proof
of exact recovery.

## Evidence and verification

Archive outside Git:
`~/Library/Application Support/GraphEvoLab/Evidence/2026-10-26-V01-membership-66DD1A44-6C01-4C5F-BB78-EE644BC3BF22/`.
It retains final/partial reports, manifests, traces, logs, the unreserved ledger,
`comparison-summary.json` and `collection-note.txt`. The note records a local
collector phase-name shadowing error: a collector reached its deadline despite
an already-retained successful writer final report. Collection was corrected;
the completed native stage was not replayed or interrupted because of that bug.

| Final successful report | SHA256 |
|---|---|
| writer-prepare-original | `32d84d156952b3954e0b808a8b748345c07eba114c91f110d224ddd0b39bbee4` |
| reader-original | `e4cf91d771129be3f2175d65abaf8f62afab01859c94d45fc430b6f390e8a44b` |
| writer-add-added | `1aad986b73c87809da99d3d2797c55dfed478d90a944dcca79dd590def0de4ac` |
| reader-added | `205162c2c3431dc893ce79519d3e42179ba928c2bca0a27a012ba9fcf69efe36` |
| writer-delete-deleted | `dea8dfbfa7d2f6d9203c521574505cd37f75071873c621f0089a3639ddf82799` |
| writer-reopen-deleted | `7b272d3469cb2da228caf9d4bcc2f268b5a437311d04ea6cace656b25b556eae` |
| reader-deleted | `d64f9420ef5186e035960d9735ee4cbf7119a780fe249bc582aa9f9afd94c3a7` |

The initial source passed 64 local tests. The precondition fix passed 66; final
log `test_sim_2026-10-26T07-14-35-694Z_pid60425_94e3afef.log`, result
`test_sim_2026-10-26T07-14-35-695Z_pid60425_728551ad.xcresult`.
Later permission instrumentation has its own source/test provenance and was not
used for these physical membership stages. Tests were not rerun for this
documentation-only result. Each hardware process ended explicitly after evidence
retention. No wipe, purge, migration, account change or local-store deletion
occurred; synthetic fixtures and evidence remain retained.

## Limits

This establishes the tested native relation/save behavior and same-device fresh
store recovery for this root/child fixture, not every relationship topology or
GraphEvo Entity/Relationship/Action facade. An independent same-owner peer,
cross-account incremental membership, larger dependency closure, offline/conflicts,
scale and graph-level deletion/recreation remain open. No explicit-sharing
variant was needed or executed. Same-iPad recovery must not be presented as an
independent-device PASS or a universal export-completion guarantee.
