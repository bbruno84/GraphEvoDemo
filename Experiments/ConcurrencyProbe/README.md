# V03 local Core Data concurrency probe

This standalone Swift package is a direct-framework experiment. It does not
modify or import GraphEvo, initialize the demo app, use CloudKit, or define the
GraphEvo 2 public API. It compiles in Swift **6 language mode**, with complete
concurrency checking and default nonisolated declarations. The sole
`@unchecked Sendable` is a small cancellation flag protected by `NSLock`;
no managed object is declared Sendable.

Run on a Mac with the selected Xcode toolchain:

```sh
swift test --package-path Experiments/ConcurrencyProbe
```

The package also declares iOS 16. Its `ConcurrencyProbe-Package` scheme
ran the same 11 tests on iOS Simulator with Xcode 27.1. The worker executable
is used only for the separate macOS process control.

The package declares macOS 12 and iOS 16 deployment floors; the actual execution OS
and SDK must be recorded separately. A successful current-Mac run does not prove
iOS physical-device behavior, older runtime behavior, or Swift 6 compatibility
of GraphEvo v1.
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

The eleven tests exercise 100 concurrent increments without lost updates,
canonical-URL coalescing, independent stores, explicit error rollback and the
next clean mutation, durable close/reopen with closed-owner rejection, and
cancellation before work, during native work, at an explicit commit boundary,
and after commit. Every test uses a new temporary SQLite path, closes the
owner before deleting its own fixture, and transfers only values across tasks.

Cancellation before enqueue is an explicit application check. The native-only
variant deliberately disables that check: on the observed runtime a pre-cancelled
Swift task still performs and saves its context operation. Cancellation after a
durable commit does not undo saved data. These results do not establish every
possible timing window, cancellation during queued work, or a transaction API
contract for GraphEvo 2. No post-save cancellation error is invented to imply a
rollback that did not happen.

The native `context.perform` closure does not inherit the caller task's
cancellation state on the observed runtime. An explicit cancellation handler
can signal the context operation before `save()`, allowing rollback at that
boundary. A save already running when `close()` begins completes before the
store is detached; the value survives reopen.

The `ConcurrencyProbeWorker` executable permits two independent macOS
processes to open one SQLite file. It is intentionally not a safe distributed
writer. In one observed run, racing insertion of an absent key created duplicate
rows, which the probe rejected. With a preexisting row, one worker completed
100 increments while the other received Core Data merge error 133020. This is
evidence that the actor registry only coordinates its own process; it is not an
iOS App Group or app-extension result.

Main-thread execution is recorded for the context operations; this is not a UI
responsiveness benchmark. Complete checks for pending-work close/invalidation,
merge policy under remote imports, iOS App Group process coordination and a scoped
application-model transaction remain later experiments.
