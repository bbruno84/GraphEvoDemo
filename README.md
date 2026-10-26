# GraphEvoDemo

GraphEvoDemo is the companion iOS application for [GraphEvo](https://github.com/bbruno84/GraphEvo). It demonstrates local Core Data persistence, CloudKit synchronization, relationships, and change observation.

## Requirements

- Xcode 26 or later
- iOS 17.6 or later
- A configured CloudKit container for synchronization features

The Xcode project follows GraphEvo's `develop` branch so the demo can exercise
the latest library implementation. Open `GraphEvoDemo.xcodeproj` in Xcode and
select the `GraphEvoDemo` scheme to build and test the app.

Feature documentation is available in [docs/features](docs/features/README.md).
The documentation combines implementation notes, usage examples, and
operational guidance for the demo application.

## Framework laboratory and local configuration

The launch screen offers the existing v1 demo and a separate framework
laboratory. V00 checks the local harness; [V01 T0 instrumentation](docs/features/v01-control.md)
provides separate cloud writer/reader stages with explicit prerequisites.
[T1–T2 stages](docs/features/v01-two-stores.md) instrument two stores and a fresh
peer. The tested T1 cloud configuration was natively rejected; a preflight now
prevents repeating it and T2 was not run. Separate [T5 instrumentation](docs/features/v01-independent-owners.md)
uses distinct one-store owners and a dedicated peer. The [observed T5 result](docs/results/v01-t5-2026-10-23.md)
records locally separate writer rows but full A+B recovery in one fresh peer.
[T6 instrumentation](docs/features/v01-owner-only-shares.md) uses two disconnected
roots and owner-only shares in one private store, with separate writer/reader CLI
stages. Local tests do not establish a CloudKit result.
The [initial T6 attempts](docs/results/v01-t6-2026-10-23.md) remain inconclusive.
A later [iPad diagnosis and fix](docs/results/v01-t6-ipad-diagnosis-2026-10-24.md)
removed a laboratory observer-delivery deadlock and observed distinct owner-only
share zones plus fresh-store recovery on the same iPad. A later
[independent iPhone reader](docs/results/v01-t6-independent-reader-2026-10-24.md)
recovered the exact fixture and share identities. Both graphs downloaded into
one SQLite; selective synchronization and broader R01 requirements remain open.
[V01 incremental membership](docs/features/v01-incremental-membership.md) now has
separate relation/save-only add, update, delete, reopen and fresh-reader stages.
Its [observed 5→6→5 result](docs/results/v01-incremental-membership-2026-10-26.md)
retains same-iPad fresh readers and unchanged identities/B. These readers are
preliminary, not independent-device evidence.
[Initial V02 instrumentation](docs/features/v02-cross-account-smoke.md) adds a
private cross-account invitation/acceptance, one participant edit, owner
observation and existing-store reopen. Hardware results remain separate from
local tests; the full V02 matrix is not complete.
The [first V02 smoke result](docs/results/v02-cross-account-smoke-2026-10-26.md)
observed A-only shared recovery on the different-account XR, return of its edit
to the owner, unchanged owner-only B and reopening of both sides' existing stores.
[Read-only/fresh-replica instrumentation](docs/features/v02-readonly-fresh-replica.md)
adds an isolated single-save probe, independent owner observation and a guarded
RW restore. Local permission advice, local save, export and remote state remain
separate observations; no enforcement result is implied by its tests.
The [read-only observation](docs/results/v02-readonly-fresh-replica-2026-10-26.md)
recovered a fresh accepted-share replica and permitted the local save despite
negative record advice; the owner remained unchanged in the bounded window.
[Live-revocation instrumentation](docs/features/v02-live-revocation.md) separately
tests A3→A0 on the original open participant store while preserving owner A/B.
The [observed revocation](docs/results/v02-revocation-2026-10-26.md) removed A
from the already-open XR while an independent owner reopen retained all A/B.
[Reinvitation and voluntary leave](docs/features/v02-reinvite-voluntary-leave.md)
reuse those original stores with case-scoped invitations, explicit shared-store
participation removal and independent owner retention verification.
The [first lifecycle observation](docs/results/v02-reinvite-voluntary-leave-2026-10-26.md)
recovered A and removed its participant copy, but the owner share still listed
two participants in both bounded checks, with the nonowner pending rather than
the pre-leave accepted status. V02.7 remains partial.
A [read-only post-leave probe](docs/features/v02-post-leave-recovery.md) now
checks automatic A recovery in new stores and public metadata for the old URL,
without another invitation or acceptance. Its [bounded hardware result](docs/results/v02-post-leave-recovery-2026-10-26.md)
observed no automatic recovery during 180 seconds and pending old-URL metadata.
The [old-link reacceptance check](docs/features/v02-old-link-reaccept.md) uses
that same pending URL on the original participant stores; its
[hardware result](docs/results/v02-old-link-reaccept-2026-10-26.md) recovered
the exact A graph without a new invitation. Permanent access denial after a
voluntary leave must therefore not be assumed.
[Incremental cross-account sharing](docs/features/v02-incremental-shared-members.md)
observed owner addition and deletion after sharing. Its
[hardware result](docs/results/v02-incremental-shared-members-2026-10-26.md)
also records a participant-insertion crash; participant-created members remain
unverified.
T3–T4 and V03–V08 remain unimplemented.
The separate [V03 concurrency probe](Experiments/ConcurrencyProbe/README.md)
is a standalone macOS Swift 6 package with eight local tests. It does not
implement the app's V03 flow, test CloudKit or certify GraphEvo v1 under Swift 6.
See the [laboratory guide](docs/features/framework-laboratory.md) for lifecycle,
fixtures, reports, explicit cleanup, evidence limitations and tests.

The app defaults to local persistence, without CloudKit entitlements or a
container. Personal Development settings belong in ignored
`Configuration/Local.xcconfig`; the guide lists each setting needed for the
existing v1 cloud demo. Keep tracked files free of personal identifiers and
use dedicated Development resources, never production resources.

The app is distributed under the MIT License. See [LICENSE.md](LICENSE.md). GraphEvo is maintained in its own repository and remains subject to its own license and notices.
