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

## Separate physical checkpoint

Use two devices with different iCloud accounts in the same container/environment;
keep the owner workspace open through independent participant observation. Preserve
existing workspaces and use a new participant workspace for this run.

1. Start with an empty owner graph, present Apple's sharing UI and send its native
   invitation. On the participant, accept, resume the join and select its replica.
   Compare GraphID; an empty graph must be discoverable without an application row.
2. Add a uniquely named owner note. Wait for independent participant observation
   and compare the saved node ID/content before closing either owner.
3. Use Apple's owner UI to change the participant to read-only, then read-write.
   Refresh status on both devices and verify that mutation access follows the
   observed permission; cached content alone is not authorization evidence.
4. Close/reopen the participant workspace and resume with its existing session.
   Confirm the same GraphID/note and no duplicate replica or application insert.
5. Confirm participant leave, inspect local cleanup and owner status, then issue a
   new native invitation into another empty workspace. Verify the new membership
   independently; an old handle/join must not control it.

Record exact library/demo revisions, OS/device scope, empty/populated observations
and any pending native command or failure. This procedure is not an executed result.
Do not replay a consumed invitation/mutation or copy a native store/session into a
replica described as fresh. Account-switch trials retain their separate beta scope.
