# V01: relationship-only incremental membership

Status: **instrumented and locally tested; hardware observations are separate**.
This control fills the incremental-membership gap after initial
[T6 owner-only share creation](v01-owner-only-shares.md). It uses the unchanged
T6 root/child model and direct frameworks, not GraphEvo facade APIs.

The current hardware scope is the same-owner iPad. The connected XR belongs to
another account and is not a same-owner reader. A fresh SQLite reader on the
same iPad remains preliminary same-device evidence, even when it recovers exact
CloudKit identities. Do not label it independent-device verification. No
cross-account participant or invitation is introduced by this control.

## Question and sequence

After sharing disconnected graphs A and B into two owner-only zones, does Core
Data place a newly related A child in A's existing share through relation/save
alone? Can a fresh replica recover it, then recover its later deletion while
all old identities and the complete B fixture remain unchanged?

| Expected phase | Members | A-001 | A-root children | A-003 |
|---|---|---|---|---|
| `original` | 5 | `alpha` | A-001, A-002 | Absent |
| `added` | 6 | `alpha-updated` | A-001, A-002, A-003 | `delta`, parent A-root |
| `deleted` | 5 | `alpha-updated` | A-001, A-002 | Absent |

A-root retains value A; A-002 retains beta. B-root/B-001 retain B/gamma and their
inverse links throughout. The original and deleted phases both contain five
members but different A-001 values, so stale original recovery cannot satisfy
the deleted-phase predicate.

Only initial preparation calls `share([root], to: nil)` for A and B and persists
those shares. Addition inserts A-003 explicitly into the writer's private store,
links its parent to A-root (inverse children updates), changes A-001, and saves
once in the owning context. Deletion uses `context.delete` for A-003 and saves
once. Neither mutation calls a share API or changes the share explicitly.

No `share([new], to: existing)` operation or fallback is implemented here. If the
native relationship/save path fails or remains incomplete, retain that result.
An explicit-sharing variant would need a separate named trial and provenance;
it must not silently repair this one.

## Implementation and scope

`V01MembershipSession` owns stages, reports and the anti-replay ledger;
`V01MembershipTypes` defines deterministic phase checks and identity pinning.
The stack reuses `V02CloudStore` with only `.privateStore` selected, so this
control opens one private SQLite and does not allocate a shared store. V02's
default private/shared configuration remains unchanged. The model is unchanged;
new run namespaces prevent earlier remote fixtures from satisfying the test.

Store assignment and run-scoped `affectedStores` fetches are explicit. Context
objects remain on their queue. T6's fixed event delivery and bounded trace are
reused: posting-queue metadata snapshot, asynchronous MainActor handoff, explicit
Sendable share callbacks and heartbeat checkpoints. Native setup/import/export
success does not replace exact fixture and identity comparisons.

## CLI and local paths

All launches require a new common UUID and Development confirmation:

```text
--v01-membership-run-id <NEW-UUID> --v01-membership-development-verified --v01-membership-window 60
```

Add `--v01-membership-role` and the role-specific phase below. Windows accept
1–600 seconds, default 60. Terminate the process after retaining its final report
before the next stage on the same device.

| Order | Role | Phase argument | Behavior |
|---|---|---|---|
| 1 | `writer-prepare` | Implicit `original` | New writer store, five-member fixture, initial A/B shares |
| 2 | `reader` | `--v01-membership-phase original` | New private reader store, expect original five |
| 3 | `writer-add` | Implicit `added` | Reopen writer, add/link A-003 and update A-001, save once |
| 4 | `reader` | `--v01-membership-phase added` | New private reader store, expect all six and original A share |
| 5 | `writer-delete` | Implicit `deleted` | Reopen writer, delete A-003, save once |
| 6 | `writer-reopen` | `--v01-membership-phase deleted` | Reopen the same writer store; no mutation |
| 7 | `reader` | `--v01-membership-phase deleted` | New private reader store, expect updated five and no A-003 |

Read/reopen roles require an explicit phase; contradictory mutation-phase
arguments are rejected. Each reader gets a unique path and performs no fixture
insertion, mutation or share operation. Writer roles reuse their original store
identifier. Native opening/share operations precede the sampling window; the
window is not a timeout on those APIs. Preparation/add/delete hold the owner for
the full window even if local values already match. Read-only stages can finish
early when exact identity checks pass. External stops remain separate evidence.

Paths are inside `Library/Application Support/V01MembershipLaboratory/`:

| Path | Purpose |
|---|---|
| `Stores/<run>/writer/private.sqlite` | Original writer, reused for add/delete/reopen |
| `Stores/<run>/readers/<phase>/<stage>/private.sqlite` | Fresh private SQLite for each reader |
| `State/<run>.json` | Original/added/deleted snapshots, pinned writer store and progress |
| `Sensitive/<run>/owner-binding.json` | Protected account/resource binding; never commit or print |
| `Reports/<run>-<role>-<phase>-<stage>.json` | Stage checkpoints/final evidence |
| Corresponding `.trace.jsonl` | Bounded diagnostic phases and heartbeats |

This first implementation uses the existing local writer ledger and protected
binding for each reader's expectations. It does not copy writer rows into the
reader store. These local dependencies are another reason not to imply a new
independent-device procedure from the same-iPad reader. Independent comparison
of original and fresh-reader reports remains required.

## Progress, identity and failure guards

Before opening a preparation store, the session reserves the run in a durable
ledger. Before either mutation, it validates the complete prior fixture and
identities, checks the original writer store identifier, and durably reserves
`adding` or `deleting` before performing the save. Interrupted or incomplete
mutations keep that reservation; restarting cannot silently replay them or skip
to the next phase. Missing stores do not create replacement writer replicas.

Successful phase advancement requires exact values and links, a mapping for
every member, owner-only metadata, one common share per graph, and distinct A/B
zones. All original A record IDs and full share metadata remain pinned. A-003
must use A's original share/zone; after its first observed addition, its own
record identity is also pinned for the added-phase reader. The full B DTO array
is compared unchanged, including scope, values, links, record and share metadata.
Deletion requires the updated A-001 value and the exact five-member closure.

`fixtureSaved`, `localMutationSaved`, `initialShareCreationCalls`,
`explicitExistingShareCalls`, `exactFixture` and `preservedIdentities` are
separate report fields. An exact local snapshot is not proof of cloud delivery.
Missing membership/mappings or stale/mixed rows remain inconclusive, without
fallback. The explicit-existing-share count remains zero by construction and
the mutation-path tests verify no call to share creation. Original baseline
identities and stage snapshots support independent review; sanitized reports
use the same run-salted zone-owner digest as V02 rather than raw account IDs.

Final report retention failure is inconclusive in memory. Do not substitute an
earlier Running checkpoint for a final report. Closing detaches stores without
acknowledging CloudKit shutdown or deleting local/remote data. No cleanup, purge,
account change, invitation or migration is performed.

## Local verification and limits

Eight new tests cover CLI phase guards; exact 5→6→5 values/closure; pinned IDs,
new-child membership and unchanged B; a real one-private-store SQLite cycle with
reopen and anti-replay checks; reservation before save; full mutation-window
lifetime; fresh reader paths with zero writes/shares; and conservative missing
membership/replacement-store rejection. The full app suite passes 64 tests;
these local/injected checks are not native cloud membership evidence.

This is a root/child control only. Independent same-owner peer recovery,
cross-account propagation of the incremental child, GraphEvo facades, broader
dependency traversal, explicit-sharing variants, conflicts/offline behavior,
permissions, graph-level deletion/recreation and scale remain separate checks.
The initial T6 and V02 results remain unchanged by this instrumentation.
