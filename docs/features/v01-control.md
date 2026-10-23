# V01 — T0 mirroring control

This is direct `NSPersistentCloudKitContainer` instrumentation, separate from
V00's local harness and the normal GraphProvider. It implements a **control**,
not a comparison of cloud graph separation or a GraphEvo 2 topology. T1–T5 are
not implemented. A same-device restart/reader run is a preliminary check and
never satisfies T0's independent-device prerequisite.

## Preconditions

Use only a dedicated disposable Development container and synthetic data. The
operator must verify the signed binary's CloudKit container, Development
environment, service entitlement and provisioning before launching. The app's
confirmation switch/launch flag records this external prerequisite; it does
not introspect or prove the signature. Container/account identifiers are kept
in local configuration, not this guide. Confirm both physical devices use the
same iCloud account without collecting that account's identity.

Start a fresh app process directly in the laboratory. `GraphProvider` records
whether it has been initialized; V01 refuses to proceed if the normal demo has
already opened in that process. The production V01 entry refuses Simulator
execution. Tests inject a fake store/account and explicitly allow Simulator;
those tests perform no cloud operations.

The stage checks `CKContainer.accountStatus()` before opening its store. An
unavailable account or a native setup error produces an inconclusive result,
with error domain/code and no local fallback. Schema reset is not assumed to
have completed, and no automatic schema initialization or remote wipe occurs.

## Fixture, ownership and observation

Each fresh run uses a UUID. Its one-store fixture has three optional-string
rows in `V01ProbeItem`: A/A-001/alpha, A/A-002/beta, B/B-001/gamma, each with that
runID. A/B are diagnostic markers within **one store**, not separate cloud
graphs. There are no uniqueness constraints or deduplication rules.

The writer assigns inserts explicitly to its store and saves once. The reader
contains no insert/restore path; the runID selects the expectation and the
read predicate only. Every stage uses a fresh UUID directory and a new SQLite
file. It never copies/reopens the writer database, sidecars or backups.
Fresh private contexts read the exact persisted row multiset, including values;
duplicates, malformed values and missing rows do not pass the exact comparison.
The observation loop samples local context reads every two seconds; it neither
polls the CloudKit server nor forces export/import. Store loading is explicitly
asynchronous. The default observation window is 120 seconds, configurable from
1 to 600 seconds through launch arguments. Missing rows at timeout are
inconclusive, not proof of separation or failed server delivery.

Native setup/import/export events retain their IDs, store identifiers,
timestamps, success and error domain/code. Event storage is bounded to 128
snapshots with an explicit dropped count. Optional `recordID(for:)` lookups run
on the owning context queue and record record/zone names; they do not save,
obtain permanent IDs or request export. Owner account names are excluded.
Mappings are observational and may be absent. A successful export event is a
native operation observation, not a fixture-level server acknowledgement.

A reader reports exact fixture recovery separately from native export success
and mappings. Recovery from a fresh reader with no local inserts is the observed
roundtrip evidence; only external confirmation of independent devices and the
same account can make that observation eligible for T0. No event alone certifies
a complete fixture, and this control does not establish any isolation boundary.

At the stage boundary, operation contexts are reset, stores are detached and
the owner reference and event observer are released. Detachment is not a public
mirroring shutdown acknowledgement. Only one stage is allowed per process:
terminate/relaunch before the next stage, particularly a fresh same-device
reader. On different devices there is no shared SQLite ownership. No context
or managed object escapes into the UI or reports.

## UI and reproducible launch

Open Framework laboratory, then V01. The screen offers a shared run UUID,
Development preflight confirmation, writer/reader buttons, and the readable
JSON report. Use the writer's UUID on the reader device. Start the writer on
the first device, retain its completed report, then start a fresh process on
the independent reader device. Use Share only after the final report has been
retained. Multiple visible controllers observe the shared session independently.

For hardware automation, pass these arguments to the installed app process:

```text
--v01-role writer --v01-run-id <new UUID> --v01-window 120 --v01-development-verified
--v01-role reader --v01-run-id <same UUID> --v01-window 120 --v01-development-verified
```

These arguments enter V01 directly without opening GraphProvider. Omitted or
invalid role/UUID/window/confirmation prevents automatic execution. Never
repeat the writer with the same run UUID: allocate a new UUID for a new trial.
Terminate the app explicitly after the completed stage; do not uninstall it or
remove the normal demo's stores. Keep the reader in the foreground during the
observation window and record interruptions/backgrounding in external evidence.

Reports are inside the app data container:

```text
Library/Application Support/V01Laboratory/Reports/<runID>-<role>-<stageID>.json
Library/Application Support/V01Laboratory/Stores/<runID>/<role>-<stageID>/probe.sqlite
```

Copy reports out with the device tooling, or use Share. Running JSON is a
checkpoint, not completed evidence. If final persistence fails, the in-memory
outcome becomes inconclusive and sharing stays blocked. Initial/partial files
may remain on disk; inspect `finished` and `outcome` before accepting evidence.
Reports retain synthetic fixture values and cloud mappings locally; sanitize
personal resource identifiers and native tool logs before committing evidence.
Populate LAB_DEMO_REVISION, LAB_GRAPHEVO_REVISION, LAB_SOURCE_STATE and
LAB_TOOLCHAIN for the signed build; Unrecorded fields remain evidence gaps.

No cleanup endpoint or remote purge is invoked by these stages. The disposable
local run files and remote synthetic fixtures are retained for review. After
all owners have ended, any later explicit local cleanup must target only the
selected V01 run namespace and retain reports. Remote cleanup requires a
separate verified Development-only action; local deletion does not clean the
server. Never purge production or the normal demo store/container.

## Verification and remaining limits

Focused tests cover reader recovery with zero inserts, fresh paths, exact
multiset matching, duplicates/missing/wrong values, export/mapping-only
inconclusive outcomes, writer save and one-stage-per-process exclusion,
unavailable-account gating, valid launch arguments and model shape. They use
fake stores, not CloudKit servers. The existing V00 and GraphEvo integration
suites remain distinct and must continue passing.

Hardware outcomes belong in a separate evidence record, with source state,
OS/device, signed environment verification, runID, timestamps, configuration,
actual rows/mappings/events and cleanup status. Do not describe this guide or a
successful build/mock test as an executed or passed T0. Do not begin T1–T5 until
T0 evidence is reviewed and the procedure gate is satisfied.

Apple's [TN3164](https://developer.apple.com/documentation/technotes/tn3164-debugging-the-synchronization-of-nspersistentcloudkitcontainer)
explains system-controlled mirroring timing and the multiple-owner hazard.
The public mapping lookup is
[`recordID(for:)`](https://developer.apple.com/documentation/coredata/nspersistentcloudkitcontainer/recordid(for:));
a mapping lookup is not a server fetch.
