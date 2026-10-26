# V01 T6 — independent iPhone recovery preserves graph share zones

Classification: **observed on independent physical devices using the same owner
iCloud account**. A fresh iPhone reader recovered the exact five-member fixture
written by the iPad, including relationships, record identities and distinct
per-graph owner-only share zones. Both graphs downloaded into one local SQLite.
Selective synchronization and broader R01 requirements remain open.

## Procedure and provenance

This follows the [iPad diagnosis and fixed writer](v01-t6-ipad-diagnosis-2026-10-24.md).
The existing cloud fixture for run `649A26B8-C2A1-439B-A6B1-B7462E8E671D` was
reused; no new writer or share creation was launched. After the maintainer
connected and authorized the iPhone, the coordinator verified and installed the
same fixed signed Development binary. The same-account prerequisite was already
confirmed. The iPad was not used for this reader stage.

Source corresponds to `0df51b82a746804370306bb69826e5e19e1fe61a`, app Swift SHA256
`48792e052296391d14099d2167dff832bd08edd1e6300d45a6e228f0e06581b0`.
Build metadata records base `378221e` plus the then-frozen fix; that source hash
matches the published fix. Toolchain and dependency remain Xcode 27.0 (27A266a),
Swift 6.4 in Swift 5 language mode, and GraphEvo develop
`4dc0a7f9a717ee535e9b630b998cd6c869a2d538`. The reader was a physical iPhone on
iOS 27.0.1 (24A446); the writer was an iPad on iPadOS 27.0 (24A437).

The reader launched with `t6-reader`, the existing run UUID, a 120-second maximum
sampling window, Development confirmation and `--v01-t6-trace`. Its new process
and stage opened a fresh SQLite path. It inserted no fixture, created or
persisted no share, accepted no invitation, and copied or restored no writer
store. Fetches selected the entire run without a graph filter. No debugger was
attached.

## Observations

The reader started at **2026-10-24T11:48:29Z** and completed at
**2026-10-24T11:48:33Z**, exiting sampling early after the exact fixture and zone
checks passed. This four-second stage interval is an observation, not a
synchronization latency guarantee.

| Graph | Members and relationships | Preserved share zone |
|---|---|---|
| A | A-root → A-001/alpha, A-002/beta | `com.apple.coredata.cloudkit.share.158AB0D4-0AC1-46EA-8ABA-5AC23CD329C2` |
| B | B-root → B-001/gamma | `com.apple.coredata.cloudkit.share.B65658B5-5DB6-4A43-BAF6-D9DDCFF745E0` |

The archived writer and reader `members` arrays were independently compared and
match exactly: all five graph/node/kind/value fields, parent/children, record
names, zone names and share metadata. Each member's record zone matches its
graph's share zone. Both shares have one owner, zero non-owners and public
permission `.none` (raw 1). Both share record names are `cloudkit.zoneshare`;
the distinct zone/record pairs identify different shares.

The reader reports `fixtureSaved = false`, `shareOperations = []`, no errors,
no diagnostic write failures, and no dropped trace entries or native event
snapshots. Completed setup/import/export events succeeded without errors;
started-only snapshots are not counted as failed operations. Recovery evidence
comes from actual member comparison, rather than event success alone.

Writer and iPhone reader store, stage and process identifiers differ. The reader
store identifier is `D288B29E-A10E-4230-9E4A-4093F7A25614`. Its signed binary and
source provenance match the fixed writer; the device and OS differ as intended.

## Evidence and checks

Final reader JSON SHA256, independently checked:
`4abf3a38de868e69126b18f44784779aecbcce64690f9280adbbcebc54bc2d84`.
The original writer SHA256 remains
`25a3b8291a105af1aa167b928000590f265e2f7009fa3198893e4d7d54bdb617`.

Raw JSON, trace, manifest, console/copy/stop logs and summary are retained outside
Git under `~/Library/Application Support/GraphEvoLab/Evidence/2026-10-24-T6-independent-reader/`.
The earlier iPad archive is unchanged. The original build manifest describes
that earlier iPad-only authorization; this iPhone stage was separately authorized
later. Personal account, provisioning and device details are not published.

The coordinator explicitly terminated the reader after retaining its final
report. Console exit 1 followed intentional SIGTERM. No wipe, purge, app removal,
store deletion or invitation occurred. The existing **45 passing local tests**
remain tied to this unchanged binary; no tests were rerun for these documentation
updates. Documentation links and `git diff --check` were checked.

## Interpretation and remaining limits

The initial independent-device recovery check for this T6 fixture is complete:
the cloud data recovered on a fresh independent iPhone preserves the two graph
share zones. The earlier inconclusive attempts remain historical evidence; the
observer diagnosis and fix are documented separately.

Both graphs still recovered into **one SQLite store**. No graph-selective sync,
separate local store per share, lifecycle deletion/recreation, other-user sharing,
permission changes, scale or all-OS guarantee was tested. The direct-framework
trial does not validate GraphEvo integration. Broader R01 requirements and the
final v2 topology remain undecided; this result is feasibility evidence under
the stated conditions.
