# GraphEvoDemo — instructions for AI agents

This file is the operational entry point for agents working in the repository.
Before changing code, read `README.md` and inspect the relevant tests and project
configuration.

## Project purpose

GraphEvoDemo is the companion iOS application for the GraphEvo library. It is a
test and demonstration app for GraphEvo features, including local persistence,
CloudKit synchronization, relationships, and change observation.

The GraphEvo library is maintained in a separate repository:
<https://github.com/bbruno84/GraphEvo>.

## Documentation and language

Documentation in this repository describes how GraphEvo is implemented and used
by the demo application. It is not a replacement for the GraphEvo library's
own API documentation.

All documentation, comments, test comments, and user-facing diagnostic messages
introduced or modified by an agent must be written in English.

## Code clarity

Code must be written in a form that is easy for humans to read and understand.
Prefer clear names, straightforward control flow, and small focused functions
over clever or unnecessarily compact implementations.

Add explanatory comments where they help readers understand the reasoning,
procedures, data flow, or non-obvious behavior of a function. Comments should
explain why the code works this way, not merely repeat what the code says.

## Application architecture

Use an incremental MVVM structure for feature work:

- View controllers are responsible for UIKit view composition, navigation,
  user interaction forwarding, and presentation-only state.
- View models own feature state, GraphEvo queries, mutations, watchers, and
  feature-specific operations. They should be testable without requiring a
  view controller hierarchy.
- `GraphProvider` is the application gateway for the shared `Graph`, readiness,
  CloudKit status, GraphEvo events, and Persistent History preparation. Do not
  duplicate graph-opening or CloudKit lifecycle logic in view controllers.
- Keep GraphEvo-specific code out of view controllers whenever it represents
  reusable feature behavior. A view controller may read view-model state and
  forward user actions to the view model.

When adding a feature, decide its state owner before writing the UI. Add or
extend a focused view model, add tests for its observable behavior, and keep the
view controller limited to presentation concerns.

## Feature documentation

Every feature must include documentation that explains the implementation in
the demo application, practical usage examples, and relevant operational notes.
Documentation should combine the clarity of traditional technical
documentation with the discoverability of a wiki and the hands-on guidance of a
tutorial.

When appropriate, feature documentation should cover the following:

- how the feature is structured and implemented;
- how to use it in the demo application, with complete and realistic examples;
- configuration, setup, lifecycle, and integration requirements;
- expected behavior, limitations, common pitfalls, and troubleshooting notes.

Keep documentation close to the feature it describes and update it whenever the
implementation or public behavior changes.

## Dependency and test policy

The demo application follows the `develop` branch of the GraphEvo repository so
that new library behavior can be exercised before a stable release. Keep the
Swift Package Manager dependency and its resolved revision aligned with
`GraphEvo` `develop`.

Every implemented or demonstrated GraphEvo feature must be accompanied by
tests covering its observable behavior. Prefer focused tests for the demo's
integration with GraphEvo, including persistence, queries, relationships,
actions, tags, groups, watchers, and CloudKit-related lifecycle behavior where
the environment permits.

Migration implementation and migration-specific tests are currently out of
scope. Do not add migration behavior to the demo unless it is explicitly
requested.

## Branch strategy and pull requests

- `master` is the stable branch and contains the latest released version.
- Hotfix branches must start from the latest `master` branch and use a
  descriptive name such as `hotfix/fix-cloudkit-startup`.
- Hotfixes must be merged into `master` through a pull request. When applicable,
  the resulting fix must also be forward-merged into `develop` through a pull
  request so the branches do not diverge.
- `develop` is the integration branch for ongoing work.
- Feature and bug-fix branches must start from the latest `develop` branch and
  use descriptive names such as `feature/update-graph-api` or
  `fix/cloudkit-setup`.
- Features and bug fixes must be merged into `develop` through a pull request.
- Do not work directly on `master` or `develop` unless explicitly requested.
- Keep commits focused and describe the intent of the change clearly.

Before opening a pull request, review the diff, confirm that no unrelated files
or generated artifacts are included, and run the checks available for the
affected area.

## GraphEvo compatibility

When GraphEvo's public API or behavior changes, update the demo in a focused
branch based on `develop`. Verify the GraphEvo dependency version or branch in
the Xcode project and update demo usage, tests, and documentation together when
needed.

Do not commit credentials, CloudKit secrets, local store files, build products,
or other generated artifacts.

## Identity and project configuration

Tracked project files must not contain developer-specific Apple identifiers.
Use neutral placeholders such as `com.example.GraphEvoDemo`,
`iCloud.com.example.GraphEvoDemo`, and `YOUR_TEAM_ID`. If a feature requires
account-specific configuration, document every replacement point in
`README.md` and the relevant feature guide.

## Framework laboratory

The launch screen separates the v1 demo from the framework laboratory.
`GraphProvider` remains the gateway for normal GraphEvo behavior; do not initialize
it from the launch screen or laboratory. `LaboratorySession` owns the independent
local harness lifecycle and evidence. Direct Core Data fixtures are permitted
only inside this explicit framework-verification boundary.

V00-local-harness and the V01 T0 writer/reader instrumentation are implemented.
V01 instrumentation is not proof of an executed/passed control. Same-device
recovery remains preliminary; T0 requires independent devices on the same
account. T1–T2 are separately instrumented; they require reviewed T0 evidence
and explicit trial authorization. The exact T1 cloud configuration was natively
rejected; preserve that evidence and its preflight guard, do not bypass it or
reinterpret a preflight result as another native trial. T2 was not run. Separate
T5 instrumentation retains two distinct one-store owners and a dedicated peer;
review code/tests before hardware execution. Local/injected passes are not
cloud evidence. See the [T5 guide](docs/features/v01-independent-owners.md).
Initial V02 smoke instrumentation uses separate CLI stages; see
[the V02 guide](docs/features/v02-cross-account-smoke.md). Use only the explicitly
authorized participant identity transferred as a sensitive app-data file. Never
log or commit account IDs, invitation URLs or transport envelopes. Preparing
owner-only shares sends no invitation; `owner-invite` adds the participant.
Distinguish invitation persistence, acceptance, import, local save and owner
recovery. Read both scopes; reopen must not create fresh replicas or repeat
writes. Retain the participant owner for its whole edit window. Reuse T6's
nonblocking event delivery. The full V02 matrix is not certified by local tests.
The [first hardware smoke](docs/results/v02-cross-account-smoke-2026-10-26.md)
observed private sharing, A-only participant recovery, an edit recovered through
a new owner opening, unchanged B and existing-store reopen on both sides. Do not
extend this to live import in an already-open owner, fresh post-acceptance replica
recovery, GraphEvo facades or the full permission/lifecycle/conflict matrix.
The separate [read-only probe](docs/features/v02-readonly-fresh-replica.md) always
attempts one real save after an exact RO import; never skip it based on
`canUpdateRecord`. Keep expected local errors separate from stage/export errors.
Consumed probe paths must never reopen. Restore RW only after the coordinator
has stopped/quarantined the probe and supplied its retained final report; do
not infer CloudKit quiescence from closing. No silent value restoration, retry,
purge, revocation or leaving belongs in this batch.
Revocation has a [separate case/stage path](docs/features/v02-live-revocation.md).
Require a positive A baseline and live readiness before removing only the
authorized participant; do not purge owner data or reuse the consumed probe.
The [reinvite/leave path](docs/features/v02-reinvite-voluntary-leave.md) must
reuse original stores and the authorized recipient. Keep case-scoped invitation
artifacts separate. Leave requires a known A3 fixture, private-user role and
explicit shared store; never pass a nil store or an owner-private store to purge.
Record already-accepted metadata without replaying acceptance.
The [post-leave recovery probe](docs/features/v02-post-leave-recovery.md) is
read-only: a new case uses fresh isolated stores and the protected prior-case
URL, with no invitation, acceptance, seed, edit or purge. Never reuse its path.
Retain typed metadata results and exact acceptance status; pending is not accepted.
Negative bounded recovery and metadata errors cannot establish permanent denial.
Judge app-visible A3→A0 on the same open participant stores and retained owner
A/B. History is accessory and never a causal/completion barrier. Do not start
new V03–V08 explorations: standalone earlier packages remain historical local
evidence, not requirements for the sharing objective.
T3–T4 and V03–V08 remain unimplemented. See
`Experiments/ConcurrencyProbe/README.md` for the separate macOS-only Swift 6
prototype; its eight tests are not part of the iOS app suite or CloudKit evidence.
Do not infer app V03 implementation or GraphEvo v1 Swift 6 compatibility from it. See
[the T6 guide](docs/features/v01-owner-only-shares.md) for the separate CLI-only
owner-only share trial. Keep callback assignment, share persistence, object export,
and fresh-peer recovery distinct. T6 adds no participants or invitations and
does not establish selective download or separate local stores. See
the separate [incremental-membership guide](docs/features/v01-incremental-membership.md)
for the relation/save-only A-003 control. Do not explicitly share the new child
as a fallback. Preserve the anti-replay ledger, pinned identities, full B DTOs,
writer store and complete mutation window. Current fresh readers use the same
iPad and remain preliminary, not independent-device evidence. See
the [observed incremental result](docs/results/v01-incremental-membership-2026-10-26.md)
for the relation/save-only 5→6→5 cycle. Preserve the unstarted metadata-preflight
attempt and the bounded read-only readiness fix as separate source/evidence
boundaries; do not call that preflight a native membership rejection. See
[the V01 guide](docs/features/v01-control.md) for execution and evidence rules. Keep direct framework evidence distinct
from GraphEvo integration, and local save completion distinct from cloud sync.
Keep temporary stores within the laboratory namespace, detach stores before
explicit cleanup, and retain reports. See
[the laboratory guide](docs/features/framework-laboratory.md).

Account-specific Development settings belong in ignored
`Configuration/Local.xcconfig`, never tracked source, project or entitlement
files. The default app configuration is local and has no CloudKit identifier.
