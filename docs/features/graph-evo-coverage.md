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

`NotesViewModel` observes `Note` entities and reloads the table when a
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

### Local Development configuration

The app starts with a choice between the v1 demo and the isolated laboratory.
`GraphProvider` is created only when the v1 demo opens. The default configuration
is local; account-specific CloudKit settings belong in ignored
`Configuration/Local.xcconfig`. See the [laboratory guide](framework-laboratory.md)
for the complete configuration and Development resource requirements.

The provider implements `GraphCloudStatusDelegate` for account availability and
`GraphEventDelegate` for diagnostics. Finished imports arrive through
`GraphEvent.stateChanged(.cloudImport(.finished))`. An import event does not certify
complete synchronization or graph completeness.

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
