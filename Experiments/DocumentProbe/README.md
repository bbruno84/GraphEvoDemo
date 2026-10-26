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
