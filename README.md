# GraphEvoDemo

GraphEvoDemo is the companion iOS application for [GraphEvo](https://github.com/bbruno84/GraphEvo). It demonstrates local Core Data persistence, CloudKit synchronization, relationships, and change observation.

## Requirements

- Xcode 26 or later
- iOS 17.6 or later
- A configured CloudKit container for synchronization features

The Xcode project follows GraphEvo's `develop` branch so the demo can exercise
the latest library implementation. Open `GraphEvoDemo.xcodeproj` in Xcode and
select the `GraphEvoDemo` scheme to build and test the app.

Feature documentation is available in [docs/features](docs/features/README.md).
The documentation combines implementation notes, usage examples, and
operational guidance for the demo application.

## Framework laboratory and local configuration

The launch screen offers the existing v1 demo and a separate framework
laboratory. V00 checks the local harness; [V01 T0 instrumentation](docs/features/v01-control.md)
provides separate cloud writer/reader stages with explicit prerequisites.
[T1–T2 stages](docs/features/v01-two-stores.md) instrument two stores and a fresh
peer. The tested T1 cloud configuration was natively rejected; a preflight now
prevents repeating it and T2 was not run. Separate [T5 instrumentation](docs/features/v01-independent-owners.md)
uses distinct one-store owners and a dedicated peer. The [observed T5 result](docs/results/v01-t5-2026-10-23.md)
records locally separate writer rows but full A+B recovery in one fresh peer.
T3–T4 and V02–V08 remain unimplemented.
See the [laboratory guide](docs/features/framework-laboratory.md) for lifecycle,
fixtures, reports, explicit cleanup, evidence limitations and tests.

The app defaults to local persistence, without CloudKit entitlements or a
container. Personal Development settings belong in ignored
`Configuration/Local.xcconfig`; the guide lists each setting needed for the
existing v1 cloud demo. Keep tracked files free of personal identifiers and
use dedicated Development resources, never production resources.

The app is distributed under the MIT License. See [LICENSE.md](LICENSE.md). GraphEvo is maintained in its own repository and remains subject to its own license and notices.
