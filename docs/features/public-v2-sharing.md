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
The participant card identifies its zone as managed by the accepted Apple invitation; the
workspace's generated private-zone name is only an owner-binding input and is
not the participant route. GraphID remains comparable across both devices.

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

## Remembered connection settings

The Connect cloud action offers a saved-configuration reconnect, or Development and
Production buttons. Container/environment choices are retained in the app's
bounded cloud-preferences.json across restarts and workspace switches. A pending
Apple invitation supplies its own container in preference to the saved/default
one. No account identity, share URL or engine token is stored in these preferences.
Invalid settings leave the local workspace usable and are preserved until the
user explicitly chooses replacement settings. Connecting remains explicit.

The bundled suggestion comes from GRAPHEVO_DEMO_CLOUD_CONTAINER, also used by
the CloudKit entitlement; CFBundleIdentifier follows PRODUCT_BUNDLE_IDENTIFIER.
Local signing overrides can set those build values without editing source files.
GRAPHEVO_DEMO_DISPLAY_NAME distinguishes a laboratory install in the launcher.
These build values must match the actual provisioning capability; declaring one
does not create a registration or grant access.

Each selected workspace owns its GraphContext. New workspace closes the previous
leases before allocating a new context and carries the current foreground state.
Pending participant removal commands must settle before switching. Retired sharing
state and invitation-list snapshots are cleared; incoming invitation envelopes
remain durable across that switch. Participant zone presentation describes the
accepted native route rather than the workspace's unrelated private-zone input.
Known errors explain the needed action; other errors expose only a bounded
error-domain/code, never account identities, invitation URLs or error userInfo.

The Copy status navigation button copies bounded status categories, graph identity
and error-domain/code for support. It omits invitation URLs, account identities,
node contents and error userInfo; tests retain that privacy boundary.

The dependency pin uses GraphEvo
`e0f2a07c2115181a74e359f299a5c10ad47f17fd`, which includes direct App Group
secondary writes in [GraphEvo #183](https://github.com/bbruno84/GraphEvo/pull/183).
The Demo continues to exercise the public H02 app flow. For the physical
check on this pin, leave a synthetic participant graph, accept a new invitation
without restarting the app, and verify the same graph ID and exact records.
Use separate CloudKit accounts and the Development environment. Earlier H02
device results retain the build and scope recorded in the library report.

Alpha delivery uses reviewed, affected local verification by default. Remote demo
CI is opt-in at agreed checkpoints (ci-checkpoint label event or manual dispatch),
with no automatic rerun for a retained label, dependency pin or intermediate push.
Runner unavailability is recorded without blocking an otherwise verified,
authorized alpha merge. Actual failures remain investigated and recorded; beta
and release acceptance retain their required remote checks.
