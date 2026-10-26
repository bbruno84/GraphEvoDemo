# Framework verification laboratory

The [initial V02 cross-account smoke](v02-cross-account-smoke.md) has separate CLI
stages for identity export, private invitation/acceptance, participant edit,
owner observation and existing-store reopen. Local tests do not imply hardware
success or completion of V02. Sensitive transport files use a separate app-data
namespace and must never be shared as reports.

The launch screen offers the existing **GraphEvo v1 demo** and a separate
**Framework laboratory**. Entering the laboratory does not initialize
`GraphProvider`. Opening the v1 demo still creates its normal shared graph;
the Menu button returns to the launch screen, but that graph remains open for
the app process lifetime. Relaunch the app and
choose only the laboratory when collecting isolated framework evidence.

## Current scope

**V00 — Local harness check** remains the local preparation check. The separate
[V01 T0 control](v01-control.md) now has explicit writer/reader instrumentation;
its results must be collected and reviewed separately. V02 has initial CLI smoke
instrumentation; V03–V08 remain catalog entries marked Not run. Separate
[T1–T2 stages](v01-two-stores.md) now instrument
a two-store trial after the T0 control; T3–T4 remain unimplemented. Separate [T5 instrumentation](v01-independent-owners.md)
and its [observed result](../results/v01-t5-2026-10-23.md) retain the independent-owner
trial and unified fresh-peer recovery; local writer separation was not cloud isolation.
This preparation does not choose a cloud topology, application model protocol,
or future GraphEvo API. No CloudKit container or remote resource is opened by
the harness.

`LaboratorySession` owns state and report retention, independently of the normal
graph gateway. Its shared instance prevents overlapping checks or cleanup across
app scenes. Change observation uses independent UUID subscriptions rather than
one replaceable callback. Each `LaboratoryViewController` subscribes when it
appears, removes its token when it disappears, and reloads current state on
return; weak captures avoid retaining controllers. Multiple visible consumers
continue receiving the same run and cleanup updates independently.
`LaboratoryViewController` forwards run/cleanup actions and displays
state and evidence. The states are Not run, Running, Passed (local harness only),
and Failed. A second run requires explicit cleanup of the previous workspace.

The V00 check uses **direct Core Data**, not GraphEvo integration and not
`NSPersistentCloudKitContainer`. Its tiny `HarnessItem-v1` model is a disposable
fixture, not a proposal for the v2 model. It writes fixed string keys A-001/A-002
to store A and B-001 to store B. Each write saves locally, resets its private
context and detaches the persistent store. A fresh coordinator reopens each file
and verifies the exact sorted keys, including the absence of the other fixture.
Core Data operations execute with asynchronous private-context `perform` calls.

Successful save/reopen is evidence of local persistence under these conditions.
It does not establish CloudKit export, import, graph completeness, sharing,
cross-device isolation, performance, or v2 feasibility.

## Use and evidence

1. Launch the app and select Framework laboratory.
2. Tap V00. The screen changes to Running and then an outcome.
3. Tap the outcome row to inspect the readable JSON report; Share exports it.
4. Use Reports to export completed retained reports, including prior launches.
   Initial Running records and undecodable files are excluded from sharing.
5. Use Clean temporary laboratory stores and confirm removal before another run.

Files live inside the app's Application Support/VerificationLaboratory namespace:

- `Stores/<run UUID>/A.sqlite` and `B.sqlite`, including SQLite sidecars;
- `Reports/<run UUID>.json`, atomically updated at start, finish and cleanup.

These stores are disposable and never share a path with the v1 demo. Cleanup
removes only UUID directories inside this private Stores directory, including
interrupted runs. Every operation detaches its stores before cleanup becomes
available. Reports remain; app removal deletes the app's retained evidence.
Leaving the screen does not cancel an active check. After process interruption,
a report can remain Running: treat it as interrupted/inconclusive, clean the
stores explicitly, and repeat. Initial or interrupted Running JSON remains
available on disk for inspection but is never offered as completed evidence.
There is no automatic remote cleanup or purge.

If the final report write fails after fixture verification, the session is
Failed and the report displayed in memory explicitly becomes Inconclusive with
the retention error, while preserving the fixture observations. `finished`
marks the end of the attempt, not successful retention. Sharing the current
report is blocked until its current final contents have been saved; the initial
Running JSON is not substituted. A later successful explicit cleanup can retain
that inconclusive report, including its original retention failure, without
promoting the check back to Passed.

A report records run identity, timestamps, OS, device class, Simulator/device
execution, build provenance, fixture/model/backend, observations and cleanup.
Missing build provenance is explicitly Unrecorded. Populate these build settings
before retaining evidence for an actual experiment:

```text
LAB_DEMO_REVISION = <full demo commit SHA>
LAB_GRAPHEVO_REVISION = <resolved Package.resolved SHA>
LAB_TOOLCHAIN = <Xcode build, Swift toolchain, language mode>
LAB_SOURCE_STATE = <clean, or a description/reference for the local diff>
```

The GraphEvo revision default reflects the checked-in pin and must be updated
when that pin changes. These fields are operator-supplied provenance, not
runtime assertions. For shareable evidence, also record hardware model, exact
procedure, errors, cleanup and the relevant Apple references. Keep account IDs
and data payloads out of committed evidence. Classify later conclusions as
documented, observed under stated conditions, unsupported, inconclusive or
blocked; a harness pass is not an experiment conclusion.

## Development configuration

`Configuration/Development.xcconfig` is the app target's base configuration.
Its default is local persistence with no CloudKit identifier or entitlements.
Both existing app build configurations use these safe defaults. Personal
settings belong in ignored `Configuration/Local.xcconfig`, which the base
configuration optionally includes. Do not edit tracked project files with
account identifiers.

To enable the existing v1 cloud demo with dedicated Development resources,
create the local file and supply your own values:

```text
PRODUCT_BUNDLE_IDENTIFIER = <your dedicated development app ID>
DEVELOPMENT_TEAM = <your team>
GRAPHEVO_CLOUD_CONTAINER = <your dedicated development container>
CODE_SIGN_ENTITLEMENTS = GraphEvoDemo/GraphEvoDemo.entitlements
```

`Info.plist` reads the bundle ID and container from build settings;
`GraphProvider` reads the container from the built Info.plist. Entitlements use
the same setting. Configure signing, Developer Portal capabilities, test target
signing if needed, and the CloudKit Development environment with resources you
own. These settings configure the v1 cloud demo; V01 additionally requires the
explicit preflight confirmation and separate entry described in its guide.
No real account or resource is supplied by this repository. Never use production
stores or containers for experiments. Check the resolved build settings before
device testing.

## Tests and dependency

The app follows GraphEvo **develop**, currently pinned to
`4dc0a7f9a717ee535e9b630b998cd6c869a2d538`. This deliberately updates the recovered
local pin `ae111160254b9a6c441f8418134bf868e4d1deeb`; no design branch is used.
The v1 import diagnostic now consumes `GraphEvent.stateChanged(.cloudImport(.finished))` in
place of the removed `GraphCloudSyncDelegate`.

`LaboratoryTests` verifies state transitions, save/reopen and fixture isolation,
retained JSON, repeated-run exclusion, cleanup of interrupted workspaces,
preservation of unrelated directories and reports, fresh runs, and visible
filesystem/report failures. Separate regression tests verify two independent
subscribers and removal of either subscription, plus failure only on the final
report write after both fixtures pass. They check the in-memory inconclusive
outcome, exclusion of the initial Running file from current/archive sharing
after relaunch, and subsequent retention of the inconclusive report during
cleanup. A controller test verifies entry from the launch
menu and the pending experiment rows. The existing four GraphEvo integration tests remain
separate from the direct-framework harness. The hosted test target imports the
actual app implementation; launching the test host does not open GraphProvider.

Run on an available Simulator (substitute its name/runtime):

```bash
xcodebuild test -project GraphEvoDemo.xcodeproj -scheme GraphEvoDemo \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' \
  CODE_SIGNING_ALLOWED=NO
```

The shared scheme's Core Data diagnostic environment variable keys contain no
trailing newlines. Simulator and local tests do not replace real-device,
cross-account CloudKit verification, which remains future work.

## Preparation verification (2026-10-23)

- Preserved the pre-existing uncommitted MVVM/coverage/configuration work in
  commit `7dd008b`, separately from laboratory changes. Xcode user data was left
  on disk and ignored, never committed. The original feature branch was retained.
- App build and build-for-testing passed with Xcode 27.0 (27A266a), Swift 6.4
  toolchain and Swift 5 language mode, signing disabled.
- All ten XCTest cases passed on iPhone 17 Simulator / iOS 26.5 (four existing
  GraphEvo integration tests, six laboratory tests), including the review fixes
  for independent subscriptions and final-report retention failure.
- The app launched and the two-entry launch screen was inspected. Navigation
  into the laboratory and its pending rows were verified by the controller test;
  the runtime snapshot tool did not expose table rows as tap targets.
- `git diff --check` passed. This repository is an Xcode app, not a standalone
  Swift package; package-level dump-package/swift test are not applicable.
- No V01–V08 experiment or real CloudKit synchronization was executed. Signed
  devices, dedicated Development identities, and account provisioning remain
  prerequisites for later cloud verification. Simulator passes prove no cloud
  topology, sharing behavior, performance budget or v2 contract.

V01 control execution is governed by the separate guide; V00 outcomes do not
satisfy its cloud prerequisites or establish any topology result.
