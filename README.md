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

## Project configuration

This repository contains only neutral placeholders for application identity and
CloudKit configuration. Before running the app with synchronization enabled,
replace the following values with identifiers owned by your Apple Developer
account:

- `com.example.GraphEvoDemo`: the app bundle identifier in the Xcode project
  and `GraphEvoDemo/Info.plist`;
- `com.example.GraphEvoDemoTests`: the unit-test bundle identifier in the Xcode
  project;
- `iCloud.com.example.GraphEvoDemo`: the CloudKit container identifier in
  `GraphEvoDemo/GraphEvoDemo.entitlements` and `GraphEvoDemo/GraphProvider.swift`;
- `YOUR_TEAM_ID`: the Apple Developer team identifier in the Xcode project.

The bundle identifier, CloudKit container, entitlements, and Developer Portal
configuration must belong to the same Apple Developer account. Select the
correct team and CloudKit environment in Xcode before testing synchronization.
The local in-memory and unit-test flows do not require a real CloudKit
container.

The app is distributed under the MIT License. See [LICENSE.md](LICENSE.md). GraphEvo is maintained in its own repository and remains subject to its own license and notices.
