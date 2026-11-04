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

## Public v2 flow

The maintainer explicitly authorized H01 public-entry and migration demonstration.
For this flow the dependency is pinned to a reviewed GraphEvo 2 integration
revision, superseding the ordinary develop-dependency rule above. Preserve the
existing v1 flow and its files. The launch selector must not initialize the legacy
cloud graph before v1 is selected. PublicV2ViewModel owns its GraphContext and
leases; controllers only forward input/lifecycle and present detached state.
Account isolation must clear cached notes and replace query subscriptions after
verification. Keep the explicit source/authority/peer prerequisites and stable
operation UUIDs. Native staged conversion preserves payloads; attachment
optimization remains consumer-owned. See docs/features/public-v2-entry.md.

H02 extends the same explicit v2 screen with GraphEvo's native sharing adapter.
Route cold/warm CKShare metadata through the v2 controller; retain bounded invite
URL/container state without printing it or opening the legacy stack. Never replace
a populated workspace on invitation acceptance. Keep durable join/workspace IDs
before opening a replica, observe permissions and confirm destructive leave/stop.
All dependency pins must agree on the reviewed library integration revision.
Injected/model/Simulator evidence remains distinct from native two-account device
acceptance. See docs/features/public-v2-sharing.md.

Connection UI must remember bounded container/environment preferences, prioritize
an incoming invitation's container and offer environment buttons. Do not require
retyping identifiers during ordinary restart/reconnect. Local opening remains
independent of invalid saved cloud settings. Workspace switches await prior
lease closure, require settled participant removal commands, create a new owned
GraphContext and preserve foreground activity; do not carry a retired context's
membership restrictions into another workspace. Bundle suggestions, entitlements
and signing overrides share GRAPHEVO_DEMO_CLOUD_CONTAINER. Never infer provisioning
success from a declared build value or publish account/invitation diagnostics.
