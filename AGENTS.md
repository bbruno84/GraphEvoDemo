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

Only V00-local-harness is implemented. V01–V08 remain Not run until explicitly
implemented and verified in later work. Keep direct framework evidence distinct
from GraphEvo integration, and local save completion distinct from cloud sync.
Keep temporary stores within the laboratory namespace, detach stores before
explicit cleanup, and retain reports. See
[the laboratory guide](docs/features/framework-laboratory.md).

Account-specific Development settings belong in ignored
`Configuration/Local.xcconfig`, never tracked source, project or entitlement
files. The default app configuration is local and has no CloudKit identifier.
