# V02: initial private cross-account smoke

Status: **initial smoke observed on the owner iPad and a different-account XR**;
see the [retained result](../results/v02-cross-account-smoke-2026-10-26.md).
Invitation, exact A recovery in shared scope, return of one participant edit and
existing-store reopen passed under those conditions. Local tests alone do not
establish that result. This is one bounded direct-framework control, not completion of V02,
R01, or GraphEvo integration verification. The authorized pair is the owner's
iPad and an iPhone XR on iOS 18 under a different account. Device orchestration
and evidence collection are handled separately. The implementation does not
raise the deployment target. Verify Developer Mode, provisioning, unlocked state,
account availability and the signed dedicated Development resource first.
CLI Development confirmation asserts an operator check, not app certification.

## Implementation

`V02Session` owns stages/checkpoints; `V02CloudStore` owns one container with two
SQLite stores in private/shared scopes; `V02Types` defines fixture validation and
sensitive transport envelopes. The CLI-only view presents redacted reports and
does not initialize `GraphProvider`. The unchanged T6 model retains the legacy
probe entity. Only a new run UUID is used; older remote fixtures are not reused
or modified. New objects are explicitly assigned to private scope. Each snapshot
fetches the entire run from both stores using `affectedStores`, without graph
filtering. No automatic migration or replacement store is introduced.

| Graph | Root | Children and original values | Sharing |
|---|---|---|---|
| A | A-root, value A | A-001/alpha; A-002/beta | One authorized private read-write participant |
| B | B-root, value B | B-001/gamma | Owner only |

Children have inverse links only to their own root, with no global catalog or
A/B reference. The one participant edit changes existing A-001 from `alpha` to
`alpha-from-participant`. It creates no object/share and is not replayed on timeout.

Event delivery reuses T6's `queue: nil`, Sendable DTO and asynchronous MainActor
handoff. Share/persistence callbacks are explicitly `@Sendable`. Bounded JSONL
tracing and MainActor heartbeats retain diagnostic phases without assuming native
calls return immediately. Framework callbacks are not treated as import completion.

## Private invitation via sensitive files

The XR exports its current CloudKit user record ID from the configured container.
The coordinator transfers that local file into the owner sandbox. Core Data's
`fetchParticipants(matching:into:completion:)` resolves precisely that ID using
`CKUserIdentity.LookupInfo(userRecordID:)`. The owner checks the returned identity,
adds only that participant with `.privateUser`/`.readWrite`, then uses
`persistUpdatedShare(_:in:completion:)`. Public permission stays `.none`; B is
not offered. No Contacts, email or phone discovery is performed.

The coordinator transfers the resulting private invitation envelope only to the
authorized XR. It includes the URL and expected owner, recipient, share and run.
The XR fetches `CKContainer.shareMetadata(for:)`, validates these identities,
container, private read-write role and pending status, then calls Core Data's
`acceptShareInvitations(from:into:completion:)` into shared scope. No application
CKRecord CRUD, custom zone or direct `CKAcceptSharesOperation` is used.

This path needs no Messages interaction, system sharing UI or link-dispatch
plist change. Personal project/plist settings are preserved. Only `owner-invite`
adds a participant; preparing owner-only shares sends no invitation. Before that
stage, the coordinator must verify the identity file came from the authorized
XR/run. The CLI flag authorizes the operation but does not authenticate that
file's provenance.

## Paths and transport

Paths are relative to `Library/Application Support/V02Laboratory/` in app data:

| Path | Purpose |
|---|---|
| `Sensitive/<run>/participant-identity.json` | XR identity output |
| `Sensitive/<run>/owner-binding.json` | Account binding checked on owner reopen |
| `Sensitive/<run>/participant-binding.json` | Account binding checked on participant reopen |
| `Sensitive/<run>/private-invitation.json` | Owner output containing private URL/account IDs |
| `Inbox/recipient.json` | Coordinator copy of XR identity on owner |
| `Inbox/invitation.json` | Coordinator copy of invitation on XR |
| `Stores/<run>/owner/{private,shared}.sqlite` | Owner stores reused by follow-up stages |
| `Stores/<run>/participant/{private,shared}.sqlite` | Participant stores reused by edit/reopen |
| `Reports/<run>-<role>-<stage>.json` | Checkpoints/final stage report |
| `Reports/<run>-<role>-<stage>.trace.jsonl` | Bounded diagnostic phases |

Sensitive outputs are excluded from backup, protected until first unlock and
written with mode 0600, without overwriting existing evidence. Inputs are bounded
regular JSON files, not symlinks. CLI accepts only an input filename, never a URL,
raw identity or arbitrary path. Run, purpose, version, container and account
bindings are checked. Keep these files, copied app-data archives and raw framework
logs outside Git and public reports. Do not print their contents.

Reports include synthetic record/zone names and a run-salted digest of the zone
owner, not raw account IDs or URLs. Owner-default zone owner names in invitation
IDs resolve against the share owner, not the recipient. Snapshot default owners
resolve against the current account before hashing. Compare normalized identity
tuples across accounts; scope and current-user role legitimately differ.

## CLI procedure

Every stage needs the following common arguments using one new UUID:

```text
--v02-run-id <NEW-RUN-UUID> --v02-development-verified --v02-window 120
```

The window is 1–600 seconds, default 120. Terminate each device process after
retaining its final report before another stage on that device.

| Stage/device | Additional arguments | Operation |
|---|---|---|
| 1, XR | `--v02-role identity` | Export identity; no stores/fixtures/invitation |
| 2, owner | `--v02-role owner-prepare` | Fresh stores; five objects; two owner-only shares |
| Transfer | No launch | Copy XR identity into owner `Inbox/recipient.json`; verify provenance |
| 3, owner | `--v02-role owner-invite --v02-input recipient.json --v02-invitation-authorized` | Reopen; invite only XR to A; export private envelope |
| Transfer | No launch | Copy envelope into XR `Inbox/invitation.json`, without printing it |
| 4, XR | `--v02-role participant-accept --v02-input invitation.json` | Fresh stores, empty run baseline in both, accept into shared, sample A |
| 5, XR | `--v02-role participant-edit` | Reopen; require exact original A/write permission; save once |
| 6, owner | `--v02-role owner-observe` | Reopen and observe participant edit; can run concurrently with XR edit stage |
| 7, XR | `--v02-role participant-reopen` | New process, same stores; require edited A; no acceptance/save replay |
| 8, owner | `--v02-role owner-reopen` | New process, same stores; require edited A/unchanged B; no insertion/invitation |

Preparation/invitation and participant-edit stages keep their owner open for the
full sampling window. In particular, an exact local edited snapshot does not end
the participant stage immediately. This offers export time without claiming
acknowledgement or causality. Run owner observation in parallel. Other read
stages can exit early on an exact snapshot. The window starts after native
open/share/accept operations; it does not time out those APIs. Record external
stops separately and retain unfinished checkpoints.

Stages deliberately do not retry interrupted preparation, invitations or edits.
Keep partial evidence and diagnose before allocating another run. Reopening
missing stores fails instead of creating a replacement. Reopen verification is
durable local-store behavior, not a fresh cloud replica. No cleanup/wipe/purge
operation is provided.

## Evidence and limits

Preparation uses `preparationObserved` and does not require an accepted participant.
`invitationPersisted` means share update completion; `acceptanceCompleted` means
the acceptance API completed. Neither proves import. A subsequent
`exactObservation` requires the full values, links, mappings, private permissions
and correct scope: participant A's three members only in shared, no B anywhere,
and no run objects in private; owner all five in private with A invited/accepted
and B owner-only. Missing/extra/duplicate rows, broken links, wrong permissions or
missing mappings are inconclusive. B's bounded absence is not a universal privacy
proof. Independently compare A's normalized record/share identities and values
across accounts, and B's fixture/identities before and after on the owner.

A local participant save does not prove owner receipt. Final report write failure
is inconclusive in memory; an earlier Running checkpoint is not final evidence.
Closing detaches stores and releases the owner, without acknowledging CloudKit
shutdown or deleting remote data.

Eleven new tests cover real SQLite routing/reopen/edit, duplicate/edit replay
rejection, full multiset/scope/permission validation, owner-name normalization,
secret/report separation, account binding, bounded file input, participant zero
inserts, share-A failure gating B, and full edit-window lifetime with a test clock.
The full 56-test local suite passes; injected/local tests do not create actual
participants or certify hardware sharing.

Read-only enforcement, revocation, permission changes, leaving, offline/concurrent
edits, lifecycle resets, scale, traversal beyond this root/child model and GraphEvo
Entity/Relationship/Action facades remain separate checks.

## Primary references

- [Sharing Core Data objects between iCloud users](https://developer.apple.com/documentation/coredata/sharing-core-data-objects-between-icloud-users): private/shared stores and custom sharing.
- [Lookup by user record ID](https://developer.apple.com/documentation/cloudkit/ckuseridentitylookupinfo/1640419-initwithuserrecordid?language=objc): supported participant lookup input.
- [NSPersistentCloudKitContainer](https://developer.apple.com/documentation/coredata/nspersistentcloudkitcontainer): `share`, `fetchParticipants`, `persistUpdatedShare`, `acceptShareInvitations` and `fetchShares`; SDK declarations confirm iOS 15 availability for these Core Data APIs.
- [Share metadata](https://developer.apple.com/documentation/cloudkit/ckshare/metadata): owner and current participant role/permission/status, retrieved independently of link dispatch.
