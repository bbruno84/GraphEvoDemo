# V01 T1–T2 — two stores and a fresh peer

This adds a bounded topology trial to the [V01 control](v01-control.md).
The [observed T0 control](../results/v01-t0-2026-10-23.md) established the
prerequisite for the authorized physical-device run. T1/T2 instrumentation and
local tests are not themselves evidence of cloud separation or a v2 decision.
T3–T5 remain unimplemented and must not be started by these roles.

## Exact configuration

T1 uses **one** `NSPersistentCloudKitContainer`, the unchanged T0 model
`V01ProbeItem-v1`, and two fresh store descriptions with the default model
configuration. A.sqlite and B.sqlite receive the same configured CloudKit
container identifier and private database scope. Both descriptions enable
Persistent History and remote-change notifications, load asynchronously and
disable automatic migration. No zone is selected or created by application
code. There is no model partition by configuration and no fallback to another
container, store layout or persistence mode.

A new run UUID scopes three synthetic fixture rows: A-001/alpha and A-002/beta
with logicalGraphID A, and B-001/gamma with logicalGraphID B. The writer calls
`context.assign(item, to: store)` for A and B explicitly and saves each store's
fixture in its own private-context operation. These two local saves are not an
atomic cross-store transaction. `localSavesByStore` retains any partial progress.
The run UUID must differ from T0 and earlier writer trials; no remote wipe is
needed to distinguish old records.

Store lookup is by the configured, standardized file URL, never by the first
store returned by the coordinator. Each snapshot sets `affectedStores` to just
that store and predicates only on runID. It does **not** hide unexpected A rows
in B or B rows in A using a logicalGraphID predicate. The peer uses one new
SQLite store with the same model and cloud settings and reads all rows of the
run. The peer never inserts data or restores/copies the writer store.

## Opening, sampling and evidence

`loadPersistentStores` calls back once per description. A small MainActor
tracker waits for both distinct callbacks, retains success/failure by key,
local filename and available store identifier, and resumes only once. Callback
order is irrelevant; an error in one store does not release the owner while
the other configured callback is still outstanding. Partial-open results are
retained and any successfully loaded stores are detached at the stage boundary.
A native rejection is an experiment outcome: do not work around it with another
zone, model or local fallback.

The report retains:

- `storeLoadResults`: native per-description load status and error domain/code;
- `initialStoreSnapshots` and `initialLocalObservation`: fresh reads immediately
  after both local fixture saves, before the timed observation loop;
- `storeSnapshots` and `topologyObservation`: final per-store rows, mappings and
  identifiers after sampling (the peer is keyed `peer`);
- native setup/import/export event snapshots, correlated by store identifier;
- per-store local save status, actual rows/values and optional record/zone names.

The immediate post-save reads are not atomic with mirroring and may already
include an import. The later snapshots are after a timed window, not a promise
that import completed. Both are retained so routing can be distinguished from
subsequent observed convergence. Sampling requests fresh local reads every two
seconds; it does not poll CloudKit or force export/import. The default window
is 120 seconds, configurable up to 600 seconds. Event storage remains bounded
with an explicit dropped count.

| Classification | Meaning and limit |
|---|---|
| `openingFailed` | A configured store failed its native load; inspect partial results. No fallback or topology success is claimed. |
| `localStoresSeparated` | This sampled local A/B row distribution exactly matches explicit assignment. This is not cloud isolation. |
| `localMixtureObserved` | A known A fixture row was observed in B or a known B row in A. Full actual snapshots remain available. |
| `unifiedPeerReplicaObserved` | The independent peer contains exactly the full expected A+B row multiset in one fresh store without inserts. This is a scoped observation, not a universal mapping rule. |
| `inconclusive` | Rows are absent, partial, duplicated, malformed or unexpected. An A-only/B-only peer at timeout does not prove selective recovery. |

A successful export event or available mapping alone cannot establish either
separation or full delivery. Inspect native setup failures even if local opening
and saves succeeded. Compare peer row identities and zone mappings with each
writer store independently; filenames and query scoping are not cloud evidence.

## Reproduce on the authorized devices

Verify the same Development signing/resource/account prerequisites as T0.
Start directly in the laboratory, one stage per process:

```text
--v01-role t1-writer --v01-run-id <NEW UUID> --v01-window 120 --v01-development-verified
--v01-role t2-reader --v01-run-id <SAME UUID> --v01-window 120 --v01-development-verified
```

Run the two-store writer on the first device. Retain and inspect its opening,
native setup and fixture results before starting the peer on the second.
If Apple rejects the configuration, preserve the error and return to review;
do not silently change the procedure. Keep the app foreground and record any
interruption. Do not uninstall the app or delete the normal demo's store.

Paths remain inside `Library/Application Support/V01Laboratory/`:
`Stores/<runID>/t1-writer-<stageID>/A.sqlite` and `B.sqlite`,
`Stores/<runID>/t2-reader-<stageID>/probe.sqlite`, and
`Reports/<runID>-<role>-<stageID>.json`.
The UI has explicit T1 and T2 buttons; T0's writer/reader roles still open one
store and remain available. V00 is unchanged.

After collection, end app processes explicitly. Store detachment does not prove
that a mirror owner has acknowledged shutdown. Local files and remote synthetic
fixtures remain for review; no purge or cleanup is invoked by either stage.
Record any future cleanup separately and confine remote actions to the
explicitly authorized Development resource.

## Local checks and hardware gate

Seven additional focused tests exercise actual local SQLite routing and
`affectedStores` reads with no cloud owner, matching private cloud descriptions,
callback order/duplicate handling, initial-versus-later snapshots, reader
without insert, partial opening error without fallback, and conservative
classification of missing/mixed/unexpected rows. Together with existing suites,
23 tests pass on Simulator. This does not execute or establish T1/T2 hardware
behavior. Hardware results are retained in a separate sanitized result document
once collected and compared by the coordinating chat.
