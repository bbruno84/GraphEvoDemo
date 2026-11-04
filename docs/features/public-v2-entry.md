# Public GraphEvo 2 flow

The launch screen selects the existing v1 demo or a separate GraphEvo 2 workspace.
Selecting v2 constructs an application-owned GraphContext and never initializes
GraphProvider's legacy cloud graph. The Developer screen also links to v2.

## Ownership and local use

PublicV2ViewModel owns one context, graph lease and optional connection lease.
UIKit forwards actions and aggregate application activity. Account observation
and typed note queries update detached UI state. Isolation cancels old query
observation and clears cached notes immediately; a verified return starts a fresh
query observation. Cloud readiness is displayed separately from local access.

Workspaces live under Application Support/GraphEvoDemo-PublicV2, separate from v1.
A current-workspace descriptor persists the graph, conversion-operation and
activation UUIDs and zone before first mutation. Create is explicit; Open refuses
a missing store. New workspace closes current leases and selects a new directory;
it does not delete old files or silently convert old data. User stores are never
reset by selecting v2.

Use Create local graph, Add demo note and Refresh notes first. Local-only opening
never needs an iCloud account. Import attachment targets the first demo note and
uses GraphEvo's public coordinated file API. Existing Data properties are not
rewritten by the demo.

## Optional private cloud

Configure an explicitly entitled v2 container and its expected development or
production environment. Use a container separate from the concurrently available
legacy v1 demo until an application-specific cutover has been completed. The demo
does not discover accounts, change entitlements or merge v1 mirroring zones.
Do not commit personal identifiers/signing settings when configuring a device.

Connect returns while identity is checked; wait for Transport ready before
binding the selected private zone or requesting synchronization. A synchronized
store opened locally still verifies its stored identity, even without a live
connection. Retry account checks works independently of transport.
A ready connection/requested turn is not proof of peer delivery. Public invitation
onboarding, background delivery and physical account-change acceptance are outside
this flow.

## Explicit v1 conversion and authoritative recovery

Start with an unused workspace. Select a complete, stopped v1 source directory,
including native external content and SQLite sidecars when present. Enter the
exact SQLite filename and type STOPPED only after all source writers have stopped.
The directory's security scope remains held throughout the public staged bootstrap.
The library validates/protects the source and creates the verified backup.
The demo retains the operation UUID so resubmitting the same source/request can
recover a committed conversion rather than duplicating it.

Conversion commit is displayed separately from opening. Data and serialized
array/dictionary/Codable payloads are preserved. Moving large application binaries
to logical attachments is an explicit consumer transformation; the demo never
infers it from size. Unprepared large ordinary values may exceed cloud record
limits and are refused rather than silently transformed.

Before publication, the host must explicitly declare its authoritative source,
completeness, stopped writers and returning-client policy. Advance authoritative
publication prepares MF10 once and advances its durable protocol on each request.
A declaration records the host's assertions; it does not verify global old-client
completeness. Existing v1 data/cloud zones are not repurposed.

On a same-account peer select a new empty workspace, connect its own account-bound
session directory, and enter the owner's exact Graph UUID and zone in Recover
empty replica. The peer recovers the published authority; it does not convert its
own v1 source. Repeating recovery supports the same already-marked replica route;
an existing workspace cannot be relabeled to a different graph/zone.

## Verification

The Foundation-only model is tested in Swift 6 with `swift test`. For a local
reviewed library checkout, set GRAPHEVO_DEMO_LIBRARY_PATH to that checkout's path;
this affects only the test dependency, not the Xcode app's pinned remote revision.
Tests cover stable reopening, isolation cache clearing, preservation of old
workspaces, explicit stopped-source prerequisites, duplicate-open refusal and
updates from independent feature leases. The app builds on iOS Simulator. Seven model cases pass locally; simulator UI
smoke covers explicit v2 selection, local creation, note insertion and reopening
the same persisted note after releasing the previous UI owner. The pinned
library revision is 4c253f2a (reviewed H01 #150, full checkpoint #41811987802).
Injected library tests exercise cloud/activation/peer recovery. Local model/UI
checks are not a physical CloudKit/account-change certificate.
