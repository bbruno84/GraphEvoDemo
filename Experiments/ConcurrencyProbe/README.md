# V03 local Core Data concurrency probe

This standalone Swift package is a direct-framework experiment. It does not
modify or import GraphEvo, initialize the demo app, use CloudKit, or define the
GraphEvo 2 public API. It compiles in Swift **6 language mode**, with complete
concurrency checking, default nonisolated declarations, and no unchecked
Sendable, unsafe isolation, or preconcurrency import escape hatches.

Run on a Mac with the selected Xcode toolchain:

```sh
swift test --package-path Experiments/ConcurrencyProbe
```

The package declares macOS 12 as its deployment floor; the actual execution OS
and SDK must be recorded separately. A successful current-Mac run does not prove
iOS behavior, macOS 12 runtime behavior, or Swift 6 compatibility of GraphEvo v1.
No third-party dependencies are added.

## Ownership under test

`ProbeStore` is an actor that owns one Core Data container and one private writer
context. Async context operations fetch, mutate, save/rollback and construct an
immutable Sendable value on that context's queue. Managed objects never escape.
Actor calls can reenter during an await; the shared private context serializes
the entire read/modify/save operation rather than assuming actor isolation alone
makes an operation spanning awaits atomic.

`ProbeRegistry` coalesces concurrent opens of one canonical URL into one owner.
This is an explicitly implemented process-local candidate policy, not a native
Core Data singleton, distributed lock, or repair of the existing GraphEvo
context manager. Independent URLs receive different owners. This prototype has
no per-handle release/reopen policy: close it only when its callers are finished.
App/extension access and remote imports are not covered.

## Retained checks

The eight tests exercise 100 concurrent increments without lost updates,
canonical-URL coalescing, independent stores, explicit error rollback and the
next clean mutation, durable close/reopen with closed-owner rejection, and three
cancellation cases. Every test uses a new temporary SQLite path, closes the
owner before deleting its own fixture, and transfers only values across tasks.

Cancellation before enqueue is an explicit application check. The native-only
variant deliberately disables that check: on the observed runtime a pre-cancelled
Swift task still performs and saves its context operation. Cancellation after a
durable commit does not undo saved data. These results do not establish every
possible timing window, cancellation during queued work, or a transaction API
contract for GraphEvo 2. No post-save cancellation error is invented to imply a
rollback that did not happen.

Main-thread execution is recorded for the context operations; this is not a UI
responsiveness benchmark. Complete checks for pending-work close/invalidation,
merge policy under remote imports, cross-process ownership and a scoped
application-model transaction remain later experiments.
