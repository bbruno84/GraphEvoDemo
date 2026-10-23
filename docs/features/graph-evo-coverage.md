# GraphEvo feature coverage

This guide explains how the demo application exercises the public GraphEvo API.
It is written for developers who want to understand the implementation and
quickly reproduce each behavior in the app.

## Application structure

The demo uses an incremental MVVM structure:

- `GraphProvider` owns the shared graph and GraphEvo lifecycle;
- `NotesViewModel` owns note queries, mutations, and the note watcher;
- `DeveloperViewModel` owns diagnostics, probes, stress tests, and feature
  demonstrations;
- `NotesViewController` and `DeveloperViewController` are responsible for UIKit
  composition, navigation, and forwarding user actions.

This separation keeps GraphEvo behavior readable and makes feature behavior
testable without constructing the complete UIKit hierarchy.

## 1. Graph lifecycle and persistence

`GraphProvider` is the single application-level owner of the GraphEvo graph.
It configures the CloudKit container, creates a `GraphStoreConfiguration`, and
waits for the store to become ready before the view controllers access data.

Implementation:

- `GraphEvoDemo/GraphProvider.swift`
- `GraphEvoDemo/AppDelegate.swift`

The important lifecycle pattern is:

```swift
var configuration = GraphStoreConfiguration()
configuration.name = "Main"
configuration.cloudKitContainerIdentifier = Graph.cloudKitContainerIdentifier

let graph = Graph(configuration: configuration)
graph.whenReady { result in
    switch result {
    case .success(let graph):
        graph.sync()
    case .failure(let error):
        print(error.localizedDescription)
    }
}
```

The app uses `graph.sync()` after mutations. The Developer screen also exposes
`graph.clear()` for resetting demo data. Store migration is not part of this
demo workflow yet.

## 2. Entities, properties, tags, and groups

Notes and attachments are dynamic `Entity` values. Their properties are stored
through GraphEvo's dynamic member subscript:

```swift
let note = Entity("Note", graph: graph)
note[dynamicMember: "title"] = "A note from the demo"
note[dynamicMember: "createdAt"] = Date()
note.add(tags: "inbox")
graph.sync()
```

The Developer screen creates a `User` entity, assigns it to the `demo-users`
group, and creates a note tagged as a probe. This demonstrates that tags and
groups are separate concepts: tags describe a node, while groups describe
membership.

Operational notes:

- Every entity must be created with the same `Graph` used by its search or
  relationship.
- Dynamic values are typed as `Any?`; callers must cast values when reading them.
- Mutations are local until `graph.sync()` persists them.

## 3. Relationships and actions

The note detail screen creates a directed `NoteAttachment` relationship. The
note is the relationship object and the attachment is its subject:

```swift
let attachment = Entity("Attachment", graph: graph)
attachment[dynamicMember: "title"] = "Auto-generated attachment"

let relationship = Relationship("NoteAttachment", graph: graph)
relationship.subject = attachment
relationship.object = note
graph.sync()
```

The Developer screen demonstrates an action with multiple participants:

```swift
let review = author.will(action: "reviews")
review.add(objects: note)
graph.sync()
```

Use a relationship for a durable directed connection. Use an action when the
data represents an event involving subjects and objects.

## 4. Search and predicates

The Notes screen uses a typed search to load notes:

```swift
let notes = Search<Entity>(graph: graph)
    .where(.type("Note"))
    .sync()
```

The Developer screen runs a compound predicate that selects favorite notes:

```swift
let favoriteNotes = Search<Entity>(graph: graph)
    .where(.type("Note") && .has(tags: "favorite"))
    .sync()
```

`Search` also supports asynchronous results. The integration tests cover this
path in `GraphEvoDemoTests/GraphEvoFeatureTests.swift`.

Operational notes:

- Successive `where` calls are combined with OR by GraphEvo.
- Build one compound `Predicate` when an explicit AND is required.
- Searches must use the graph that owns the entities being queried.

## 5. Watchers and local changes

`NotesViewController` observes `Note` entities and reloads the table when a
node changes. A watcher is initially stopped, so the demo explicitly resumes
it after assigning its delegate:

```swift
let watcher = Watch<Entity>(graph: graph)
    .where(.type("Note"))
watcher.delegate = self
watcher.resume()
```

The watcher delegate logs inserted, updated, and deleted notes. The `source`
argument distinguishes local changes from changes delivered through CloudKit.

Keep both the watcher and its delegate alive for as long as observation is
needed. Call `pause()` when observation should be suspended.

## 6. CloudKit and diagnostics

### Configuration placeholders

The repository deliberately uses neutral placeholders so it does not expose a
developer's Apple account or CloudKit resources:

```text
Bundle identifier:       com.example.GraphEvoDemo
Test bundle identifier:  com.example.GraphEvoDemoTests
CloudKit container:      iCloud.com.example.GraphEvoDemo
Developer team:          YOUR_TEAM_ID
```

Replace these values in the Xcode project, `Info.plist`, entitlements, and
`GraphProvider.swift` before enabling real CloudKit synchronization. The app
bundle identifier, entitlements, container, and signing team must be aligned
with the same Apple Developer account.

CloudKit is configured in `GraphProvider` and enabled through the app
entitlements. The provider implements:

- `GraphCloudStatusDelegate` for account availability;
- `GraphEventDelegate` for GraphEvo state, warning, and failure events;
- `GraphCloudSyncDelegate` for completed CloudKit imports.

After the store becomes ready, the provider calls:

```swift
graph.ph_prepareOnLaunchAfterContainerReady()
```

This prepares the Persistent History session before remote changes are merged
into the graph. The application remote-notification handler logs the incoming
notification; GraphEvo's internal remote-change coordinator performs the
history processing.

The Developer screen includes diagnostic controls for the Persistent History
token and transaction author. These controls are deliberately development-only
and should not be treated as application behavior.

CloudKit testing requires a signed device or simulator configuration with the
matching container, entitlements, and CloudKit environment. Local in-memory
tests do not validate CloudKit account state or server imports.

## 7. Tests

`GraphEvoDemoTests` currently covers:

- entities, tags, and groups;
- relationships and actions;
- compound predicates;
- asynchronous searches;
- watcher delivery after `resume()`.

Run the tests with the shared `GraphEvoDemo` scheme or from the command line:

```bash
xcodebuild test \
  -project GraphEvoDemo.xcodeproj \
  -scheme GraphEvoDemo \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' \
  CODE_SIGNING_ALLOWED=NO
```

CloudKit-dependent tests should be added separately when a stable test
container and environment are available. Migration tests remain intentionally
deferred.
