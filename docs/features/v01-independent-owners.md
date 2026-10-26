# V01 T5 — independent one-store owners and a dedicated peer

Status: [hardware result retained](../results/v01-t5-2026-10-23.md). Local A/B
rows remained separate during the window, while the fresh independent peer
recovered A+B together. The result does not establish cloud separation. This alternative topology follows the
[observed T0 control](../results/v01-t0-2026-10-23.md) and
[native T1 rejection](../results/v01-t1-2026-10-23.md); it does not rename T1/T2,
weaken their preflight, or select a GraphEvo 2 architecture.

## Exact ownership and configuration

`V01IndependentOwners` retains two distinct `V01CloudStore` instances. Each
constructs its own `NSPersistentCloudKitContainer` and opens exactly one fresh
SQLite URL: A.sqlite for owner-A and B.sqlite for owner-B. Reusing one owner
instance or the same standardized URL is rejected before any store is opened.
Both owners remain alive throughout writes and the observation window; reading
A does not release B. A failed close still attempts to close the other owner.

Each child uses the unchanged T0 `V01ProbeItem-v1` model, the same configured
dedicated Development resource and private database scope, default model
configuration, asynchronous loading, Persistent History and remote-change
notifications. The existing duplicate-destination preflight applies separately
to each owner's store descriptions. A single owner with two stores using the
same resource/scope remains rejected. Two independent one-store owners are the
variable being tested, not an exemption from that guard.

Use a new run UUID. Insert A-001/alpha and A-002/beta only through owner-A,
B-001/gamma only through owner-B, with explicit child `context.assign` routing.
These are separate saves, not an atomic cross-owner transaction. Each snapshot
uses a fresh private context and its owning store selected by URL/key through
`affectedStores`. Its only predicate is runID: no logicalGraphID filter hides
unexpected cross-imported rows. There is no custom zone, direct CKRecord write,
scope change, automatic schema initialization, fallback, migration or wipe.

The dedicated T5 reader uses one new owner and SQLite file on the independent
same-account peer device. It receives the run UUID and never inserts, restores,
copies or opens a writer store. It reads the entire run, including both graph
labels, duplicates and unexpected values.

## Observation and interpretation

Reports retain initial post-save and final snapshots for each store, actual
row/value multisets, optional public record/zone mappings, per-store local saves
and native load/setup/import/export observations. `ownerStorePlan` maps owner-A
to A and owner-B to B, or owner-peer to peer. Each native event/load result has
an `ownerKey` in addition to the native store identifier. Owner keys are explicit
instrumentation labels, not account identifiers or persistent graph identities.

Initial reads occur after both saves and are not atomic with cloud imports.
Both owners stay alive for the later sampling window. Fresh local reads occur
every two seconds for 120 seconds by default (CLI range 1–600); no CloudKit poll
or forced export/import occurs. Native event retention stays bounded to 128
snapshots with an explicit dropped count. Partial opening errors retain both
owner references and available load results until cleanup. Objective-C
exceptions remain process terminations, not recoverable Swift callback errors.

`localStoresSeparated` describes only an exact sampled local A/B distribution.
Known A rows appearing in B or vice versa produce `localMixtureObserved`.
An independent peer recovering the full exact A+B fixture produces
`unifiedPeerReplicaObserved` under those conditions. Missing, partial, duplicate
or different rows remain inconclusive; an A-only/B-only peer at timeout does
not prove selective recovery. Events, mapping availability and actual peer
rows/identities must be inspected separately. Neither an export event nor a
mapping alone acknowledges complete fixture delivery.

## Reproducible entry and artifacts

Verify the signed Development binary/resource and same-account/device
prerequisites externally. Start directly in the laboratory with GraphProvider
uninitialized; one stage per process still applies. UI buttons and dedicated
CLI roles keep T5 distinct from T0 and the protected T1/T2 entries:

```text
--v01-role t5-writer --v01-run-id <NEW UUID> --v01-window 120 --v01-development-verified
--v01-role t5-reader --v01-run-id <SAME UUID> --v01-window 120 --v01-development-verified
```

Run the writer on the first device, review its evidence, then use the dedicated
reader on the independent device. If native setup rejects the topology, retain
that result and return to review; do not silently change resources or scope.

```text
Library/Application Support/V01Laboratory/Stores/<runID>/t5-writer-<stageID>/A.sqlite
Library/Application Support/V01Laboratory/Stores/<runID>/t5-writer-<stageID>/B.sqlite
Library/Application Support/V01Laboratory/Stores/<runID>/t5-reader-<stageID>/probe.sqlite
Library/Application Support/V01Laboratory/Reports/<runID>-<role>-<stageID>.json
```

Record revision, frozen-source hash/local diff, OS/toolchain, procedure, timing
and interruptions, exact rows, native errors and mappings. Keep raw device and
provisioning logs local; commit only sanitized results. Detach/release both
owners at the boundary, then terminate the process before another stage;
detachment is not an acknowledged mirror shutdown. No local deletion or remote
cleanup is invoked. Retain fixtures and reports for review and record any later
explicit Development-only cleanup separately.

## Local verification

Eight additional tests verify distinct owner creation/lifetime, one URL per
owner, resource forwarding, event/load attribution, reused-owner/URL rejection,
closing both owners after errors, partial opening failure, A/B write routing,
initial/final sampling and the reader's zero inserts. A two-owner real local
SQLite test uses ordinary NSPersistentContainer without cloud options and checks
run/store scoping and visible cross-label rows. These local/injected tests do
not validate cloud separation or execute T5. The full 35-test suite passes,
including the unchanged T1 preflight tests. Tool logs include an App Intents
metadata warning without an AppIntents dependency; no Swift diagnostic failure
is hidden by that tooling warning.
