# Local typed-model, attachment and query probe

This standalone Swift 6 package tests direct Core Data behavior. It does not
import GraphEvo, change the demo app, use CloudKit, or propose final v2 APIs.
Run `swift test --package-path Experiments/DocumentProbe` on the selected Mac
with complete concurrency checking. The declared macOS 12 floor is not a claim
that tests ran on that OS or on iOS.

`DocumentModel` maps a small ordinary application value to/from an immutable
`DocumentValue`. This is one fixed-shape protocol candidate, not a generic
schema design. The prototype supports string identity/graph, optional title,
integer rank, one parent/inverse children relation, optional binary data and
filename/content-type metadata. Application decoding errors propagate even if
Core Data itself accepts the stored row. Cross-graph links are rejected by this
candidate's write path; that guard is not a native CloudKit security guarantee.
Actors transfer only values; managed objects and dictionaries stay on a private
context's queue. No unchecked Sendable or preconcurrency import is added.

The seven tests cover:

- application-model and optional-value round trips, including an application
  decoder rejecting a stored value;
- a 10 MiB byte-exact attachment round trip after close and copying the entire
  fixture directory, including any store-managed external content;
- replacement/deletion and explicit rollback with small/1 MiB attachments;
- malformed stored attachment metadata producing a decoding error;
- rank/identity keyset pagination with ties and an intervening insert;
- SQL relationship filtering, count, sum and dictionary projections scoped to
  one graph, plus rejection of a cross-graph parent;
- native nullification of a child's parent after deleting the parent.

The binary attribute permits external storage; Core Data chooses whether to
use it. Tests do not depend on its internal filenames or expose them as public
URLs. This is a whole-directory backup while closed, not a live backup,
streaming path, eviction strategy, file-progress API or memory benchmark.
Cancellation and cloud attachment transfer remain separate experiments.

Keyset pagination traverses changing current state. The test explicitly shows
that a new row inserted before the cursor is not returned on later pages. It
therefore does not certify a frozen query snapshot or stable pagination under
arbitrary sort-key edits. Cycles, bounded traversal, large datasets, remote
imports and observation remain later checks. Results must be linked from the
GraphEvo 2 execution register with these limits intact.

## V07 observation comparison

Four additional tests bring this package to eleven tests. A separate tiny
schema and a main-queue NSFetchedResultsController observe actual background
context saves. Its Objective-C delegate uses an audited MainActor assumption
because that controller is constructed only with a main-queue context. Context
objects are never sent through the AsyncThrowingStream; consumers receive value
arrays. Keep the handle alive and explicitly cancel it before closing the probe.

The checks exercise insertion/value/order/deletion results, bufferingNewest(1)
for a slow consumer, cancellation/resubscription, and relationship-dependent
membership compared with a fresh SQL fetch. On the recorded Mac, eleven state
publications coalesced to one buffered latest state with ten dropped batches.
This is suitable evidence about state buffering, not durable event delivery.

The relationship comparison deliberately records a limitation rather than
adding a hidden invalidation workaround: after changing only a child's title,
fresh SQL excluded the parent, but the existing fetched-results controller
still contained it and had published only its initial snapshot, including after
25 local ten-millisecond sampling intervals. A passing comparative test does
not mean this observation requirement was satisfied. Native related-property
invalidation, cross-device imports, history replay and broader Watch design
remain open. The sample interval is not a guarantee that no later callback can
occur on another runtime or under another workload.

## V08 recovery comparisons

Four recovery checks bring this package to fifteen tests. The suite records one
**known failed guarantee**: direct Core Data metadata inspection with a read-only
option changes the SQLite `.shm` sidecar on the observed runtime. Its failed
`before == after` expectation is retained with `withKnownIssue`, and the original
failing run/diagnosis logs remain in the external evidence archive. A green test
runner with this known issue must not be reported as fifteen satisfied behaviors.

An incompatible native open (automatic migration disabled) returned Cocoa error
134100, preserved the logical data and original model, but also changed `.shm`.
A bad parent path returned Cocoa error 258 without a replacement store or damage
to the sentinel file. A separate candidate inspected metadata on a full copy of
the **closed** fixture and preserved all original files byte-for-byte. This does
not establish a live-copy/backup protocol or modify GraphEvo's store-opening
behavior. Recovery fixture digests concern their flat SQLite family; ambiguous
filenames are rejected instead of silently overwritten in the comparison.
