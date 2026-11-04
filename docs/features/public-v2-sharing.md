# Public native sharing (H02 alpha)

The v2 screen uses an application-owned GraphContext and the GraphEvo native
sharing adapter. Existing v1 graphs and user files retain their separate paths.

## Owner

Create/open a v2 workspace, connect its entitled CloudKit container/environment,
and bind the private zone. A converted v1 graph must complete explicit MF10
publication first. Choose **Share with Apple UI**: GraphEvo publishes the small
GraphEvoGraph descriptor and presents Apple's recipient/permission interface.
Only private recipients and read-only/read-write permissions are supported.
The adapter is retained until completion; **Release sharing presentation** awaits
its cleanup before another presentation. Owner data remains intact on stop sharing.

## Participant

Open the standard Apple invitation. CKSharingSupported and SceneDelegate route
cold-launch options and running-scene callbacks to the v2 screen. The invitation
URL/container are retained in a bounded local file, never printed. Connect the
matching container and correct Development/Production environment. Select a new
empty workspace first if the current one already has a graph; old files remain.
Then choose **Accept pending Apple invitation** and **Resume shared invitations**.
Select an identified graph to open its replica in that workspace.

GraphID is discovered from the shared descriptor after native acceptance, even
for an empty graph. It is not entered manually or carried in another invitation
file. Joining intent is durable in that workspace's CloudSession before native
acceptance, and the workspace records graph/join identity before replica opening.
Resume uses the same session directory; no native store/token copies are used.
A successfully opened replica is not proof that all records/attachments arrived.

**Inspect sharing status** displays membership and starts newest-state observation.
**Leave shared graph** confirms destruction of the local replica, attachments and
unsent changes. **Stop sharing as owner** confirms loss of participant access while
preserving owner records. A pending remote command is distinct from local cleanup.
No account sign-out, cloud reset or automatic adoption of another workspace occurs.

## Compatibility and verification

The explicit Connect action enables validated format-8 to format-9 session
conversion. Stop old alpha writers on every participating device first: their
runtime cannot understand the new cloud control record/session document. Payloads,
engine state and queues are preserved; incompatible/corrupt state is refused.
Production CloudKit requires deployment of the new GraphEvoGraph fields.

The model tests verify durable callback staging, deduplication, invalid input and
preservation of existing notes/workspaces. Simulator builds compile the native
adapter and callback integration. Live two-account invitation UI/acceptance remains
a separate physical checkpoint; neither local tests nor a successful app launch
certify it. See the library H02 guide for guarantees and recovery boundaries.
