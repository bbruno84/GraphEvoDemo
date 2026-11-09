# GraphEvoDemo

GraphEvoDemo is the companion iOS application for [GraphEvo](https://github.com/bbruno84/GraphEvo). It opens as **GraphEvo Notes**: notebooks backed by independent graphs, autosaved notes, attachment covers, File documents and optional iCloud sharing.

## Requirements

- Xcode 26 or later
- iOS 17.6 or later
- A configured CloudKit container for synchronization features

The Xcode project pins an exact reviewed GraphEvo 2 revision. Open
`GraphEvoDemo.xcodeproj` in Xcode and select the `GraphEvoDemo` scheme to build
the Notes app and retained diagnostic/compatibility flows.

The app is distributed under the MIT License. See [LICENSE.md](LICENSE.md). GraphEvo is maintained in its own repository and remains subject to its own license and notices.

## Notes app

The [Notes guide](docs/features/notes-app.md) explains notebooks, automatic local
saving, retained drafts, covers/documents, iCloud settings, recovery and sharing.
The application shares one injected GraphContext and cloud connection across
scenes; each scene has independent selection and drafts. Fresh Notes stores use a
separate relative namespace and never replace previous demo stores.

The model tests run with `swift test`. Package and Xcode pins must always identify
the same reviewed library integration commit. No personal signing configuration,
CloudKit account values, stores or tokens belong in source control.

## Retained GraphEvo diagnostics

Open Settings → Diagnostics and legacy tools to select the previous v1/v2 flows. The [public v2 guide](docs/features/public-v2-entry.md) describes local
opening, account-aware private sync, explicit stopped-source v1 conversion and
authoritative empty-peer recovery. The [native sharing guide](docs/features/public-v2-sharing.md)
covers Apple invitations, graph discovery and participant lifecycle. The v2 view model owns its GraphContext;
there is no new global graph singleton or automatic user-store cutover.

The public v2 model tests run with `swift test` (macOS 14+). The iOS application
uses the same model and public library entry. Personal CloudKit/signing values
remain local configuration and must not be committed.
