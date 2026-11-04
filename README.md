# GraphEvoDemo

GraphEvoDemo is the companion iOS application for [GraphEvo](https://github.com/bbruno84/GraphEvo). It demonstrates local Core Data persistence, CloudKit synchronization, relationships, and change observation.

## Requirements

- Xcode 26 or later
- iOS 17.6 or later
- A configured CloudKit container for synchronization features

The Xcode project pins reviewed GraphEvo 2 integration revision `a1097ff1`. Open
`GraphEvoDemo.xcodeproj` in Xcode and select the `GraphEvoDemo` scheme to build
the public v2 entry and retained v1 compatibility flow.

The app is distributed under the MIT License. See [LICENSE.md](LICENSE.md). GraphEvo is maintained in its own repository and remains subject to its own license and notices.

## Public GraphEvo 2

The launch screen selects v1 or a separate v2 workspace before either stack is
opened. The [public v2 guide](docs/features/public-v2-entry.md) describes local
opening, account-aware private sync, explicit stopped-source v1 conversion and
authoritative empty-peer recovery. The v2 view model owns its GraphContext;
there is no new global graph singleton or automatic user-store cutover.

The public v2 model tests run with `swift test` (macOS 14+). The iOS application
uses the same model and public library entry. Personal CloudKit/signing values
remain local configuration and must not be committed.
