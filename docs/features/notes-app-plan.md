# Notes application implementation contract

Accepted by the maintainer on 2026-11-08. Library baseline before prerequisites:
`949a0913`. Demo baseline: `8655400` on `develop`. Work uses isolated checkouts;
the unrelated dirty `feature/verification-laboratory` checkout is preserved.

## Accepted product decisions

- Each notebook is one graph; creation explicitly selects local or iCloud through
  an iCloud switch enabled by default (maintainer UX update, 2026-11-08).
- Each note has a title, plain text body and automatic immutable creation date.
- Autosave after 750 ms, with dirty-field patches, visible pending/error state,
  local draft retention and no silent overwrite of observed remote dirty fields.
- A cover is a keyed attachment, generated at at most 1,024 pixels and 2 MiB.
- Documents are first-class File nodes linked by a directed NoteFile relationship;
  each is attached to at most one note. Note deletion deletes its files and cover.
- First delivery includes native Apple sharing, permissions, private notebook
  discovery on fresh installations and definitive owner notebook deletion.
- Keep UIKit, testable view models, application-owned injected contexts, iPad
  three-column navigation, iPhone stack navigation and relative persisted paths.
- Primary UI is the Notes app. Retain legacy/laboratory tools in diagnostics and
  preserve every prior store. Fresh Notes data uses a new namespace and S07.
- No widget, rich-text editor, full-text engine or new query optimization here.

## Dependency increments, each reviewed and tested before integration

1. GraphEvo atomic import configuration: synchronous Sendable callback receives
   GraphMutation and GraphFile in the import transaction. Throwing rolls back
   both file rows and links; existing file reclamation handles prepared bytes.
2. GraphEvo private discovery/recovery: inspect existing system descriptors,
   return account/container/environment-bound references, and bootstrap ordinary
   private graphs in an empty/resumable replica without inventing v1 provenance.
   Notes owns a dedicated zone prefix; Graph IDs always come from descriptors.
3. GraphEvo graph deletion: public local and owner-cloud entry points; participant
   removal uses existing leave. Persist exact operation/identity/zone/store intent,
   stop admission and sync, drain work, confirm remote deletion, then destroy local
   owned artifacts under Apple coordination. Preserve interrupted progress. Pending
   offline deletion is not completion and cannot execute under another identity.
   Existing routes must not recreate deleted zones; only initial creation intent
   can create a zone. Version operational state explicitly; preserve incompatible
   alpha state unchanged. No native S06/S07 schema change is planned.
4. Deliver the complete Notes UI on the integrated dependency pin, update all
   package pins, docs and roadmap, with review and affected local acceptance.
   Remote CI only at an explicitly agreed checkpoint.

## App structure

Notebook metadata is an application Entity in its graph; a relative local catalog
retains graph/routing/join/opening information, not canonical note content.
An application owner shares one file-capable context and cloud connection across
scenes and stores. Each scene owns selection/editor state. Aggregate scene activity
controls transport lifecycle. The catalogue masks isolated account content.

List notes using bounded projections in 50-row pages, date descending. Subscribe
before initial reads and rescan on live invalidations/foreground; do not load all
bodies/covers or treat cursors as frozen snapshots. Preserve editor drafts across
refreshes; a remote deletion must never be undone by a delayed autosave.

Import documents with the new atomic callback. Delete note/files in one graph
transaction. For Quick Look/export, copy during withFileURL into an app-owned
presentation cache and release it when presentation finishes. Apple photo/document
pickers and native sharing UI remain ordinary user controls. Persist invitations
and resume joins without replacing populated replicas. Read-only/revoked/isolated
state blocks writes and clears visible sensitive caches; drafts are not replayed
without resolving access and any observed conflict.

Definitive local removal, definitive owner removal for all users and participant
leave have separate confirmations. Unfinished deletion remains visible as pending;
remove the local catalogue entry only after durable terminal completion.

## Acceptance

Test atomic import rollback/reclamation, discovery on empty catalogues and resume,
wrong identity/route refusal, and deletion faults/contention/stale owner return.
Test note persistence, autosave/drafts/conflicts, covers and File lifecycle, deletion
isolation, multi-scene ownership, permissions/revocation and cold/warm invitations.
Run Swift 6 model tests, relevant library suites and Simulator builds/smoke.
Use physical iPad/XR for the full shared path. Fresh private catalogue recovery
on iPad is separate from a two-physical-device same-account certificate; the latter
requires that device/account arrangement to be available.

## Implementation progress

Library prerequisites integrate through GraphEvo #193 (atomic File configuration),
#194 (ordinary private discovery/recovery) and #195 (definitive ordinary graph
deletion and interrupted cleanup), plus #196 (ordinary process-death registration
recovery during exact terminal deletion). The companion dependency now pins reviewed
integration `0229766c9d91096eded07ee3abc904417d57b151` in all four locations.
The complete Notes model/UIKit implementation is present. The current local
checkpoint passes 13 Notes functions and 12 retained public-entry regressions,
including 50-row cursor paging, File subtype exclusion, scene draft isolation,
opening/removal races, autosave conflicts and presentation-copy lifetime. Debug
Simulator and signed device Release builds pass. iPhone/iPad Simulator UI smoke
covers local creation, autosave, reopening and definitive deletion after force
quit; native photo/document pickers were presented. The Release Notes app is
installed and launched on iPad and XR. The maintainer subsequently reported
three manual scenarios passed: local notebook, iCloud notebook and shared notebook.
See [acceptance evidence](notes-app-acceptance.md) for the recorded scope and
remaining specific device checks; these three results do not imply completion of
every permission, File/cover or terminal-lifecycle scenario.
