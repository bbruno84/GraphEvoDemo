# Notes acceptance — 2026-11-08

## Source and dependency boundary

Companion [PR #6](https://github.com/bbruno84/GraphEvoDemo/pull/6):
`codex/notes-demo`, based on `develop` (`8655400`). Initial implementation
`48fafa5` is followed by deletion regression/evidence notes and the automatic
connection/invitation UX follow-up recorded below. All four
GraphEvo pins at that checkpoint used integrated `0229766c9d91096eded07ee3abc904417d57b151`;
the physical follow-up below records the current candidate pin.
GraphEvo prerequisites integrate through #193/#194/#195/#196; their own reports
retain actual native/CloudKit scope. No hosted CI was requested for this increment.
User changes in the original verification-laboratory checkout remain untouched.

## Automated checks

`swift test` passes 13 Notes functions and 12 retained public-entry functions.
Notes model targets compile in Swift 6. Cases cover local persistence and immutable
dates; dirty-field autosave with current-transaction conflict detection; explicit
conflict/draft resolution; read-only reload/refusal; remote deletion without
resurrection; independent scene drafts; one shared store lease across scenes;
opening concurrent with terminal removal; adjacent-notebook isolation; 50+1 header
pages without File subtypes or duplicate identities; atomic File linking and
missing-owner rollback; note/File/cover deletion; Quick Look copy/release with the
source preserved; ambiguous File ownership refusing deletion without partial edits; and relative catalogue/cold invitation retention.

Manifest and diff checks pass. UIKit Debug builds and launches on iOS 18.5 phone
and iPadOS 27 Simulator. Signed Release builds and launches on physical iPad/XR.
The retained legacy diagnostic buttons now compile only when the library's Debug
methods exist. DTOs/repository helpers explicitly remain nonisolated, matching
the Swift 6 model contract under the UIKit target's default actor settings.

## Runtime smoke

On the iOS 18.5 Simulator, create a local notebook and note, edit title/body, wait
for local save, terminate and relaunch, and reopen the same values. The app's own
native UI then definitively deletes the notebook after multiple force quits. This
exposed the ordinary stale-registration gap fixed and independently tested in
GraphEvo #196. The empty catalogue is confirmed after completion.

On iPadOS 27 Simulator, create a local notebook and note, edit the title and observe
it in the header list with the original automatic date. Native photo selection
opens correctly; the runtime snapshot tool does not expose that remote picker's
photo cells, so selecting/encoding a photo is not certified by this smoke. The
iOS 18 document provider also presents; actual provider selection/Quick Look UI
remains in physical acceptance. The model copy/import/delete paths pass separately.

Runtime testing corrected diffable-cell reconfiguration to dequeue the existing
cell rather than returning a newly constructed cell, which UIKit rejects. Status
updates keep settings fields attached, and terminal/isolated views clear stale
file-name cells and preview copies. Stable row IDs support focus/selection.

## Review

Self-review checked public-only persistence, one application-owned context and
connection, relative routing, owner/participant removal separation, profile and
account masking, current-transaction conflict guards, atomic document ownership,
terminal draft behavior, native presentation lifetimes and source-preserving
preview copies. It corrected two scene races: pending note selection cannot
replace a newer selection, and a pending notebook open cannot overwrite another
scene's terminal-removal flags. A dedicated regression verifies the latter.
No unresolved actionable source finding is recorded at this checkpoint. Device
and assistive-technology acceptance below remains separate.

## Maintainer acceptance update

On 2026-11-08 the maintainer reported three successful manual scenarios:

| Scenario | Reported result |
| --- | --- |
| Local notebook | Passed |
| iCloud notebook | Passed |
| Shared notebook | Passed |

This is maintainer-reported acceptance of the three notebook flows, additional
to build/install and library-probe evidence. The report does not specify individual
permission changes, cover/File transfer, participant leave, owner deletion or
which exact build was exercised; those details are not inferred from “3 passed”.

## Remaining device/user acceptance

An initial signed Release Notes build is installed and launched on iPad and iPhone XR,
with the test container prefilled. They use different CloudKit accounts. The
final `48fafa5` Release build also passes without source diagnostics; it still
needs deployment and device confirmation after the final lifecycle/UI review
changes. The maintainer's report above now confirms the shared-notebook flow;
its individual invitation steps were not separately itemized. Read-only/revocation,
bidirectional note/File/cover transfer, participant leave and owner deletion on
both devices remain without scenario-specific Notes acceptance evidence. Library
probes retain their own scope and do not substitute for these consumer UI checks.

Fresh same-account private discovery/recovery was proven separately by library
probes on iPad. Two-device same-account recovery requires the relevant account
arrangement and remains a distinct certificate. VoiceOver/Voice Control, maximum
Dynamic Type, reduced motion, external keyboard and actual multiwindow usability
need manual acceptance; accessibility labels/actions and dynamic fonts are present
but do not substitute for those tests.

## Automatic connection and invitation UX follow-up

The maintainer requested automatic cloud connection, an iCloud-default creation
switch and invitation acceptance popups. Startup now selects saved preferences or
the bundled Development configuration. Startup and user operations coalesce the
same connection attempt; cloud creation/acceptance awaits account readiness with
a 20-second bound. An explicit invitation acceptance may select its container;
local creation stays independent. Shared selection restoration waits for readiness.

Four additional Swift 6 model functions verify automatic profile selection,
missing-configuration local creation, one popup owner across scenes, retained
invitations after Later/relaunch, explicit re-delivery and scene-dismissal handoff.
The model checkpoint passes 17 Notes functions plus 12 retained public-entry
functions. Simulator UI confirms iCloud switch initially on, local creation after
switching off, a retained synthetic invitation popup on cold launch, Later dismissal
and re-presentation after relaunch. The synthetic URL is never accepted or sent to
CloudKit; this is popup evidence, not native invitation acceptance.

The unsigned Simulator build traps in SDK CKContainer initialization when automatic
startup first touches CloudKit. A properly signed Simulator build with external
test entitlements launches and passes the UI smoke; no signing workaround or
personal configuration is committed. Actual new popup acceptance and automatic
connection on devices remain separate from the maintainer's previous three-flow
acceptance above. No new hosted CI is requested.

The reviewed UX source is `079cd9e`. Its signed Release build installs and
launches on iPad and XR, preserving existing app data. Debug signed Simulator
and Release builds pass without source diagnostics. These deployment results
do not certify a newly received real invitation's Accept action; that remains
a device interaction check. No library dependency or native schema changed.


## Physical owner/participant acceptance — 2026-11-09

The maintainer validated the automatic connection, iCloud-default switch and
invitation popup follow-up. All existing graphs were explicitly disposable.
A controlled test used XR (iOS 18.7.11) as owner and iPad (iPadOS 27) as participant,
with already accepted invitations. An external guarded driver calls the actual
Notes model and public GraphEvo APIs using the application-owned context; no
probe hook is included in the production source. Device Hub cannot share the
XR screen on iOS 18, so owner permission changes use the SDK against real CloudKit,
not automated Apple management UI. iPad UI is observed separately.

| Scenario | Result |
| --- | --- |
| Owner note, PNG cover and File reach participant with exact values/digests | Passed |
| Participant NoteEditor body change returns to owner, preserving date/assets | Passed |
| Native readOnly refresh allows reads/File preview and refuses patch | Passed |
| iPad UI disables editing/deletion; shared document opens in Quick Look | Passed |
| Participant leave removes its replica/catalogue; owner retains content | Passed |
| Owner deletion completes and remains absent after fresh cloud-ready restart | Passed after SDK correction |
| Participant restart does not restore left graph | Passed |
| Neighboring notebook note/cover/File fingerprints remain identical on both peers | Passed |

The test found two defects. Notes now starts permission observation before remote
refresh, so a transient automatic-refresh busy result cannot leave canWrite stale.
GraphEvo [PR #197](https://github.com/bbruno84/GraphEvo/pull/197) retires the share
attempt with the deleted binding and narrowly recovers the earlier completed
cleanup case. Original failures remain preserved in external evidence; the corrected
XR restart and subsequent checks pass. The four companion pins now use reviewed
candidate `6452a7b2fde73fea8800fa8e36367ce97cf573ee` from that focused PR, pending
library integration. No schema/transport-format change or hosted CI is requested.

Evidence remains outside the repository in `ge-notes-device-tests-20261109d`;
raw account/capability documents and generated stores must not be committed.
These results supersede the outstanding device scenarios listed earlier for the
exact tested scope. Revocation, a fresh same-account two-device arrangement and
assistive-technology/multiwindow manual acceptance remain distinct checks.

Final validation against that exact published pin passes all 29 model functions,
manifest and diff checks. Signed Release builds, installs and launches normally
on both XR and iPad, replacing the external probe variant. The production app
contains no probe source or launch hook. Local Xcode emits its generic-device
placeholder operating-system warning; the build succeeds without source errors.
The final source review records no unresolved actionable findings.


## Requested integration review and hosted checkpoint — 2026-11-09

The maintainer requested review, CI and merge. Source review on `8675ce7` finds
no unresolved actionable issue; the SDK prerequisite receives a separate review.
The requested [demo checkpoint](https://github.com/bbruno84/GraphEvoDemo/actions/runs/42667170506)
is unavailable: its job is cancelled without executing any steps after about
15 minutes queued. GitHub's annotations state that a hosted runner was not
acquired and report macOS arm64 capacity constraints. The workflow conclusion
is failure, but no product test or build ran. This is not a passing checkpoint;
no infrastructure-only retry is requested under the alpha policy. Adequate local
model/build checks and the bounded physical acceptance remain the merge gate.


Library PR #197 is merged at `8f29c20b23b8164cf96f70ecfaa9c488f1667d77`.
All four companion pins now use that integration commit, superseding the candidate
pin above. Its shipping Sources and manifest are byte-identical to the physically
verified `6452a7b2`; subsequent changes only annotate seven tests and record
review/CI/roadmap evidence. Hosted macOS v2 passes 795 functions and both Swift 6
consumers. Hosted iOS compilation exposed the now-corrected annotations; the
final requested library run creates no jobs and has empty logs. Its exact startup
cause is unavailable and no passing remote iOS result is claimed. A complete
local library test build with explicit iOS 16 deployment target succeeds.

The demo's local unsigned Simulator build corresponding to its unavailable
workflow also passes on the local toolchain. Final integration checks use the
merged library pin. The same shipping source already passed the physical Notes
run and the 29 model functions; beta/release remote gates remain separate.

Final checks on the integrated pin pass all 29 model functions, manifest and diff
checks and the signed Release build. That regular build installs and launches
on both physical XR and iPad without probe arguments. The unsigned Simulator
checkpoint uses byte-identical shipping library source. Final source review
covers the four exact pin replacements and documentation only; no further
production change or hosted CI request is introduced. The maintainer authorizes
merge under the alpha policy with the documented unavailable remote checkpoint.
