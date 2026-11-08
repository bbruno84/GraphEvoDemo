# Notes acceptance — 2026-11-08

## Source and dependency boundary

Companion [PR #6](https://github.com/bbruno84/GraphEvoDemo/pull/6):
`codex/notes-demo`, based on `develop` (`8655400`). Implementation `48fafa5`
is followed only by additional deletion regression/evidence notes. All four
GraphEvo pins use integrated `0229766c9d91096eded07ee3abc904417d57b151`.
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

## Pending device/user acceptance

An initial signed Release Notes build is installed and launched on iPad and iPhone XR,
with the test container prefilled. They use different CloudKit accounts. The
final `48fafa5` Release build also passes without source diagnostics; it still
needs deployment and device confirmation after the final lifecycle/UI review
changes. Do not replace the running build during the pending human invitation
interaction. The
human Apple invitation/acceptance pass is pending; do not report Notes sharing,
read-only/revocation, bidirectional note/File/cover sync, participant leave or
owner deletion on both devices as passed merely because library probes passed.

Fresh same-account private discovery/recovery was proven separately by library
probes on iPad. Two-device same-account recovery requires the relevant account
arrangement and remains a distinct certificate. VoiceOver/Voice Control, maximum
Dynamic Type, reduced motion, external keyboard and actual multiwindow usability
need manual acceptance; accessibility labels/actions and dynamic fonts are present
but do not substitute for those tests.
