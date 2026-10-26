# V02 — initial private cross-account smoke observed

Classification: **the initial root/child smoke passed under the stated
conditions**. The owner iPad privately shared only A with a different-account
iPhone XR. The XR recovered A in shared scope, edited one existing child, and
the owner recovered that edit while B remained unchanged. Both devices then
reopened their existing stores without repeating writes or invitations.
This does not complete the full V02 matrix, R01, or GraphEvo facade verification.

## Configuration and provenance

- Synthetic run UUID: `8A6E6A45-2D7D-44C9-B127-32A552C1F773`.
- Owner: physical iPad, iPadOS 27.0. Participant: authorized physical iPhone XR,
  iOS 18.7.10, with a different iCloud account. No other iPhone was used.
- App source: `7199135b42a03fe567b8a733b1c46ef156b1406a`; app Swift-source SHA256:
  `036202fcec89cf963a24d6d4bc689602bf700fe3cd54e73f9b35f9411aa3353c`.
- Toolchain: Xcode 27.1 (27A9275), Swift 6.4 (`swiftlang-6.4.0.34.1`), Swift 5
  language mode. These conditions differ from the earlier T6 build.
- The coordinator verified Development entitlements, runtime container, account
  availability, unlocked devices and provisioning for both destinations before
  execution. Identity/invitation envelopes were checked locally to bind distinct
  authorized accounts to this run. Raw account IDs, URLs and provisioning details
  are not published. Personal project/plist settings remain outside commits.

Each device opened one `NSPersistentCloudKitContainer` with distinct private and
shared SQLite stores. The unchanged T6 model uses a new five-object A/B fixture
and run namespace; prior fixtures were not reused. Objects were assigned to
owner private scope. Entire-run queries read each affected store without graph
filtering. Native event delivery used `queue: nil` and asynchronous MainActor
report updates. See the [implementation/procedure guide](../features/v02-cross-account-smoke.md).

The XR exported its current user-record identity into a sensitive local file.
The coordinator transferred it only to the owner. The explicitly authorized
owner-invite stage resolved that one participant through Core Data, assigned
private read-write access only to A, and persisted the share. A second sensitive
file carried the private invitation to XR metadata retrieval and Core Data
acceptance into shared scope. No application CKRecord CRUD, custom zone, public
access link, system-message delivery, invitation to another account or schema
reset was used.

## Retained stages

All timestamps below are UTC on 2026-10-26. Eight completed reports were
independently read, their hashes checked, and their observations compared before
this sanitized result was written. Every stage/process identifier is distinct.

| Device / role | Start | Finish | Observation |
|---|---|---|---|
| XR / identity | 06:31:42 | 06:31:43 | Account available; identity output only, no stores or fixture |
| iPad / owner-prepare | 06:31:45 | 06:32:32 | Empty run baseline; five private members; two owner-only shares |
| iPad / owner-invite | 06:32:45 | 06:33:22 | Private RW invitation persisted only for A; B owner-only |
| XR / participant-accept | 06:33:39 | 06:33:46 | Empty run baseline in both scopes; accepted and recovered exact A |
| XR / participant-edit | 06:34:13 | 06:35:15 | One existing A child saved once; owner held for full 60-second sampling window |
| iPad / owner-observe | 06:34:40 | 06:34:43 | New opening of existing owner stores recovered exact participant edit |
| iPad / owner-reopen | 06:35:09 | 06:35:10 | Same owner stores, edited A and unchanged B retained |
| XR / participant-reopen | 06:35:30 | 06:35:32 | Same participant stores, edited A retained without acceptance/save replay |

The owner observation occurred while the participant edit stage remained open.
It opened a new container over the existing owner stores after the edit; this
does not test live import into an already-open owner container. The three-second
owner stage is not a synchronization latency bound. Local participant-save
completion and native event success were not substituted for owner data recovery.

## Exact fixture, scope and identity checks

The owner retained A-root with A-001/alpha and A-002/beta, and B-root with
B-001/gamma, including inverse parent/child links. The participant's acceptance
snapshot contained exactly A's three members in shared scope: no private-scope
run objects and no B in either scope. Independent comparison matched all A
values, links, record names, normalized zone-owner identities and share IDs
against the owner. Account-relative default zone owner names were normalized;
raw account identifiers were not printed or committed.

Observed zone-name components:

| Graph | Zone | Access |
|---|---|---|
| A | `com.apple.coredata.cloudkit.share.A1A4549C-9103-47EF-A8F3-2825387E95E7` | One owner and one private read-write participant |
| B | `com.apple.coredata.cloudkit.share.EA522E35-A82E-4BBE-B804-0AB0B3C343C3` | Owner only |

Public permission remained `.none`. After acceptance, both sides observed the
accepted A membership and their respective owner/participant roles. The XR
changed only A-001 from `alpha` to `alpha-from-participant`; the owner-observe
snapshot recovered that exact value and retained all other A values/links and
identities. The complete B DTOs, including values, links, record/share metadata
and scope, were identical from owner-prepare through owner-reopen.

Each side reused its own original two store identifiers on subsequent stages.
Final owner snapshots matched across owner-observe/reopen; final participant
snapshots matched across participant-edit/reopen. Reopening did not insert a
fixture, invite, accept or edit again. This is durable existing-store reopening,
not recovery of a new post-acceptance cloud replica.

All eight reports have no stage errors and retain their final result. Completed
native events succeeded; started-only event entries are not counted as failures.
Diagnostic write/drop counters were zero. The identity stage had no native store
events. Scope and fixture comparisons, rather than event counts alone, support
the observed result.

## Evidence integrity and validation

The local archive is
`~/Library/Application Support/GraphEvoLab/Evidence/2026-10-26-V02-8A6E6A45-2D7D-44C9-B127-32A552C1F773/`.
It retains original reports, traces, manifests, device/build/copy/stop logs,
sensitive envelopes separately, and `comparison-summary.json`. Raw identity,
invitation and provisioning artifacts remain outside Git.

| Final report | SHA256 |
|---|---|
| identity | `58aa44996f1ef025cd302fd0e92d40c87b05ec2e4ce79c0d0d6df593ee89fffd` |
| owner-prepare | `ee0c964737afa875dd06c6718f8a579a77aa4577852bfc18832cf2f2ced2775a` |
| owner-invite | `c4053f97837fb8649de2e97ff40cd9bad60e87b85e8d0a745f39187cb7dda751` |
| participant-accept | `2edb21d8c5a3421d626ab31610608bc8e44fc7d85e513771e0d5a639ac46f2be` |
| participant-edit | `5615849c5cbb9ca229b3405e8a6befefa18857ae82efd5832a0058941f0ef615` |
| owner-observe | `ba84cfecc403eb28a445f83c3bf9e34bedaf88ffc83351a66749b176164d70d2` |
| owner-reopen | `4f518ed44beed1bce9f821690cc7c1a09046b14771cce1ac8b3056c49f6b24ca` |
| participant-reopen | `733454baf35540d6e80f32cec92be12a08d5567e5c83f209b5ec38443377ab4f` |

The unchanged source previously passed **56 local tests**, including eleven new
V02 tests. Final log:
`test_sim_2026-10-26T06-28-55-948Z_pid60425_5e3f03ff.log`; result:
`test_sim_2026-10-26T06-28-55-948Z_pid60425_c0643240.xcresult`.
Tests were not rerun for documentation-only updates. Local injected/SQLite
checks remain distinct from these physical cross-account observations.

## Limits and retained state

This smoke covers only the direct-framework root/child model, not GraphEvo
Entity/Relationship/Action facades or a full dependency closure. It does not
verify read-only enforcement, offline/concurrent edits, conflicts, revocation,
leaving, account changes, fresh post-acceptance replica recovery, selective
download, scale or broader lifecycle behavior. Hardware and OS versions differ
together; no comparative OS attribution follows. B's bounded absence on the
participant is not a universal privacy proof. Full V02 and R01 remain open.

The coordinator explicitly terminated each process only after retaining its
completed report. No wipe, purge, deletion, uninstall or migration occurred.
Synthetic cloud data, local stores and evidence remain retained. No merge or
final v2 architecture selection follows from this first smoke.
