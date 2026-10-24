# V01 T6: owner-only shares

T6 tests two disconnected object graphs assigned to separate Core Data-managed
CloudKit shares. It uses one `NSPersistentCloudKitContainer`, one fresh private
SQLite store, and the existing Development container. It does not test GraphEvo
integration, selective download, or independent local stores.

The [initial observations](../results/v01-t6-2026-10-23.md) remain inconclusive.
A later [iPad diagnosis and fix](../results/v01-t6-ipad-diagnosis-2026-10-24.md)
removed a laboratory observer-delivery deadlock. The writer created two distinct
owner-only share zones and a fresh-store reader recovered the exact fixture on
the same iPad. A subsequently authorized
[independent iPhone reader](../results/v01-t6-independent-reader-2026-10-24.md)
recovered the exact five members and share identities using the same binary.
Both graphs recovered into one SQLite; selective download, other-user sharing,
lifecycle behavior and broader R01 requirements remain unverified.

The implementation is `V01OwnerOnlyShareTrial.swift`. It is CLI-only and keeps
`GraphProvider` uninitialized. Production execution rejects Simulator; local
XCTest exercises the model, SQLite fixture, parser, and report validation without
opening CloudKit. A local pass is not cross-device evidence.

## Model and fixture

The model preserves `V01ProbeItem` unchanged so earlier Development records remain
representable. The added `V01T6Member` entity has optional string attributes and
optional inverse `parent`/`children` relationships, without ordered relationships
or uniqueness constraints. No T6 object references an older probe object.

For a new run UUID, the writer saves exactly these five objects:

| Graph | Root | Children and values |
|---|---|---|
| A | `A-root`, value `A` | `A-001`: `alpha`; `A-002`: `beta` |
| B | `B-root`, value `B` | `B-001`: `gamma` |

Each child references its own root; inverse relationships populate that root's
children. The roots have no parent and no A/B cross-reference or global catalog.

## Execution

Use the reviewed build on two independent devices on the same iCloud account,
with the configured Development resource. Allocate a new run UUID and retain
the source revision, source hash, build settings, device details, and raw reports.
The command-line confirmation asserts that the operator checked Development;
the app does not query or certify the CloudKit environment.

Launch the writer with:

```text
--v01-role t6-writer --v01-run-id <NEW-UUID> --v01-window 120 --v01-development-verified
```

After reviewing the writer report, terminate the writer app. Then launch a fresh
reader process using the same reviewed build on the peer and the same UUID:

```text
--v01-role t6-reader --v01-run-id <SAME-UUID> --v01-window 120 --v01-development-verified
```

Each launch allocates a stage UUID and fresh SQLite path. The reader creates no
fixture and calls neither share creation nor share persistence. Its fetch uses
the entire run UUID without a graph filter. Windows must be 1–600 seconds;
the default is 120. This window bounds only snapshot sampling after store opening
and the writer's share operations complete. It is not a timeout for opening,
share creation, or share persistence. A pending native callback can therefore
leave the stage unfinished beyond that window; record any external observation
limit and explicit process termination separately. Do not reuse a process for
another stage.

## Share operations and evidence

For A and then B, the writer passes only the corresponding root to
[`share(_:to:completion:)`](https://developer.apple.com/documentation/coredata/nspersistentcloudkitcontainer/sharemanagedobjects%3Atoshare%3Acompletion%3A),
with `nil` as the existing share. Core Data owns the graph traversal and zone
creation. The app adds no participants, presents no invitation UI, performs no
custom CKRecord writes, and injects no custom zones.

The report records the callback share and returned node names separately from
the result of
[`persistUpdatedShare(_:in:completion:)`](https://developer.apple.com/documentation/coredata/nspersistentcloudkitcontainer/persistupdatedshare%3Ainpersistentstore%3Acompletion%3A).
Apple documents that the persistence completion follows export of the share
record. It does not establish export of every fixture object. Callback assignment,
share persistence/export, object export, and peer import are different observations. None substitutes for another. Returned callback IDs are
not assumed to enumerate the complete closure; lookup errors are retained.

Fresh snapshots call
[`fetchShares(matching:)`](https://developer.apple.com/videos/play/wwdc2021/10015/)
and `recordID(for:)` for every fetched root and child. Missing metadata remains
inconclusive. Compare share identity as `(zoneName, recordName)`; distinct zones
may contain share records with the same name. The observed result requires:

- the exact five-object multiset, values, and parent/child links;
- one consistent share per graph, with distinct A/B zones;
- a record mapping for every member in its assigned share zone;
- one owner, no other participants, and no public permission for each share.

The report omits account identities, participant names, and share URLs. Native
setup/import/export events are bounded to 128 entries with a dropped count.
These events describe the owner, rather than certifying delivery of a particular
object. A fresh-peer result still requires independent device/account provenance.

## Retention and limitations

Stores are under `Application Support/V01Laboratory/Stores/<run>/<role>-<stage>/`.
JSON reports are under `Application Support/V01Laboratory/Reports/`. A checkpoint records each imminent A/B share request; successful assignment is
retained before share persistence. Unexpected non-owner participants or public
permission stop the sequence before another share is created. Checkpoints
can remain unfinished if the process terminates; `Running` is not completed
evidence. Retain raw partial reports alongside final ones when diagnosing a
native exception or a failed share operation.

At completion, the app resets contexts, detaches the store, and releases its
owner. It neither wipes local files nor purges CloudKit. This lifecycle is not
a CloudKit shutdown acknowledgement. This trial cannot establish an isolation
boundary for storage or selective synchronization.

`V01OwnerOnlyShareTests` covers model compatibility, a real local SQLite fixture,
CLI validation, complete-multiset rejection cases, share identity across zones,
and rejection of absent mappings, mixed membership, and public/additional
participants. It does not invoke native share creation or cross-device import.


## Opt-in diagnostics and event delivery

Add `--v01-t6-trace` to retain a sibling `.trace.jsonl` file alongside the report.
`T6Trace` serializes entries under a lock, without enclosing a Core Data call in
that lock. It records sequence, timestamp, phase, optional graph label and main
thread status, without fixture payload or participant/account identities. Entries
are bounded to 512; write failures and dropped entries are counted. An existing
trace path is rejected rather than overwritten.

Phases distinguish root fetch, entry/return of share and persistence calls,
callback entry before metadata processing, continuation resumption, metadata
conversion and object lookup. Callbacks are explicitly `@Sendable`; the recorder
can write on their calling queue before returning to MainActor. A callback can
occur before the API invocation returns. MainActor heartbeats run approximately
every five seconds while the stage is active and persist the report; their
absence alone is not proof of a deadlock. Trace write failure or entry truncation
must also be considered when interpreting absent phases.

T6 registers native event notifications through `T6EventDelivery.observe` with
`queue: nil`. It converts event metadata to a nonisolated Sendable DTO on the
posting queue, then asynchronously submits report changes to MainActor. Keep
that handoff asynchronous: a `.main` NotificationCenter delivery can make native
posting wait on the same main queue that is synchronously inside a share call.
The reproduced cycle and controlled after-fix result are documented separately.
The fix preserves the model, root context and share-call sequence.

`T6TraceTests` adds three tests for sequence/schema, bounded concurrent appends,
and existing-path retention. `T6EventDeliveryTests` uses the actual observer
factory with a private NotificationCenter and verifies background posting can
return while MainActor is occupied. Together with existing coverage, the final
local suite has 45 passing tests. These checks do not replace device evidence.
