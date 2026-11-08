# GraphEvo Notes

## Everyday use

Create a notebook with a name and the **iCloud** switch, enabled by default.
Turn the switch off for an **On this device** notebook, then tap **Create**.
Each notebook is one independent graph. iCloud connects automatically at launch
using remembered settings, or the bundled container and Development environment
on first launch. Concurrent startup/creation requests share one connection attempt.
iCloud creation waits up to 20 seconds for account verification and reports
unavailability without silently creating a local notebook. Local creation never
requires an iCloud account or connection.

A note has a title, plain text content and automatic immutable creation date.
Changes save after 750 milliseconds. “Saved on this device” describes local
persistence, not CloudKit delivery. An interrupted or rejected edit retains its
local draft. A reopened draft requires explicit approval. Same-field conflicts
require **Keep mine** or **Use latest**; unrelated fields merge. A deleted note is
never recreated by autosave. Scenes retain separate drafts even for the same note.

Choose a photo for the cover, or remove it. The app downsamples the photo to at
most 1,024 pixels and encodes a keyed attachment within the 2 MiB limit. Document
imports use File nodes linked atomically to the note. A File belongs to at most
one note in this application. Deleting a note deletes its cover, document nodes
and links in one graph transaction. The original imported document is unchanged.
Quick Look uses a temporary application-owned copy and releases it on dismissal.

On iPad, notebooks, note headers and the editor occupy three columns. iPhone uses
stack navigation. Multiple scenes share application-owned store leases and cloud
transport while retaining separate navigation/editor state. Foreground activity
is aggregated across scenes. The app awaits transport suspension within the
system's finite background allowance.

## iCloud and sharing

Settings remembers the container and environment; a bundled identifier or an
incoming Apple invitation prepopulates the field. Development is appropriate only
for the signed development test configuration. Automatic connection reuses the
saved environment. Settings retains **Reconnect iCloud** for manual retry or
configuration changes, and **Find my iCloud notebooks** on a fresh catalogue.
Discovery uses the app's zone prefix and GraphEvo system descriptors, never names
or user-entered graph IDs. Recovery imports into a fresh/resumable replica.

The notebook toolbar opens Apple's native sharing interface. Incoming invitations
are retained before connection or replica creation. Cold and warm invitations
present an **Accept / Later** popup once the scene is active and other forms or
native pickers have closed. Only one scene claims a given popup. **Accept** connects
to the invitation's container, waits for account readiness, accepts only that link
and opens its notebook when ready. **Later** keeps the capability on disk and
suppresses repeat prompts until relaunch or explicitly reopening the invitation.
Failed acceptance retains retryable state; Settings still provides **Accept or
resume invitations**. Restoring a shared notebook waits for automatic cloud
readiness. Participant status controls
editing: read-only notes remain readable, while isolated/revoked content clears
visible notes, covers and previews. GraphEvo enforces actual access at every scope;
UI availability is not an authorization substitute. Retained drafts require
review before resuming after access changes.

Owner deletion and participant leave have different confirmations. Owner iCloud
deletion removes the zone and this replica; it does not certify that every other
device has already erased its cached data. Participant leave removes only that
replica and unsent work. Interrupted removal remains visible as pending: tap to
retry. The catalogue entry is removed only after terminal completion. Notebook
removal also discards this device's drafts for that notebook.

## Persistence and implementation boundaries

The namespace is `Application Support/GraphEvoDemo-Notes-v1`. The bounded local
catalogue stores graph IDs, relative notebook identifiers, cloud routing, pending
invitation capabilities and unfinished creation/removal flags. It stores no
absolute sandbox paths. Canonical notebook names and note content live in the
graph. Cloud catalogue rows show placeholders until verified graph access; cached
content never grants access under another identity. Diagnostics retain their old
namespaces and do not automatically convert or erase old stores.

`NotesDomain` uses public GraphModel/GraphStore APIs only. Note lists project title
and date in 50-row pages using explicit query budgets; bodies load on selection.
Observation starts before initial reads, triggers current-state rescans, and
refreshes on foreground. Cursors are not frozen snapshots. Covers load for visible
rows with a bounded cache. This increment adds no full-text index, widget, rich
text, new query engine or application-specific native schema.

`NotesApplicationModel` owns one injected context and connection. `NotebookSession`
owns one shared store lease and observation feeds. `NoteEditor` owns a scene's
field baselines, draft and dirty-field autosave. File import uses the library's
atomic configuration closure; Quick Look copies only inside `withFileURL`.

## Verification

Run `swift test` for Swift 6 model tests and retained public-entry regressions.
Build the GraphEvoDemo Xcode scheme for UIKit and native picker/sharing integration.
The [accepted plan](notes-app-plan.md) records physical sharing/recovery acceptance
scope. Simulator results never certify actual CloudKit, account changes, device
file-provider availability or assistive-technology user acceptance.

Automatic CloudKit startup requires a properly signed app with its configured
iCloud entitlements, including Simulator UI testing. The SDK traps on container
initialization in an unsigned Simulator build; use a signed Simulator build for
this flow. Offline model tests use no live CloudKit connection.
