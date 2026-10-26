# V02 — read-only advice, local save permitted, bounded owner non-mutation

Classification: **a new accepted-share replica recovered A read-only; the
deliberate local save succeeded despite negative record permission advice; the
owner remained unchanged during the bounded observation**. This is not proof
of a CloudKit server rejection or universal read-only enforcement. The ordinary
application edit path must respect permissions; this probe deliberately bypassed
the advice once to measure the result.

## Procedure and provenance

The owner iPad and different-account iPhone XR reused the initial smoke run
`8A6E6A45-2D7D-44C9-B127-32A552C1F773`. New probe UUID:
`605155F3-6AC9-4A5E-B248-15BC88569647`. The source was `b3e23b1`, app Swift SHA256
`a790aaa80a6d05985ed67fb2a46da7c255bd826719bba006a87d3680e76191d0`.
The coordinator verified the signed Development binary and both authorized
destinations; source was unchanged during these stages. No new invitation or
acceptance was issued. See the [stage guide](../features/v02-readonly-fresh-replica.md).

| Stage | Start UTC | Finish UTC | Result |
|---|---|---|---|
| owner-readonly | 07:29:31 | 07:30:07 | A participant changed to RO; original owner A/B unchanged |
| participant-readonly-probe | 07:30:28 | 07:31:33 | Fresh private/shared stores imported A; one real save; full 60-second post-attempt window |
| owner-observe-readonly | 07:31:00 | 07:32:04 | Original owner A/B unchanged through the 60-second observation window |

All times are 2026-10-26 UTC. Owner stages reopened the existing owner stores.
The XR probe used new isolated stores, not its original participant stores or
a copy/restore of them. It imported the share already accepted by that account,
without another acceptance. The exact pre-attempt three-member A fixture appeared
only in shared scope, with no B or private copy. Values, links, record and share
identities matched the owner after normalization; current participant permission
was read-only and public permission remained `.none`. B stayed owner-only.

## The actual write observation

The XR reported:

| Observation | Value |
|---|---|
| `canModifyStore` | true |
| `canUpdateRecord` for A-001 | false |
| Value before attempt | `alpha-from-participant` |
| Requested value | `alpha-readonly-attempt` |
| One `context.save()` attempt | Returned success |
| Value read through a new context | `alpha-readonly-attempt` |
| Local save / fresh-read errors | None |
| Reported failed native exports / stage errors | None |

Negative advice was not used to skip the write. The probe retained its owner
for the full window and did not retry or silently restore a value. Local
persistence of the attempted value was verified separately from remote state.
The owner-observe report retained A-001 as `alpha-from-participant`, with all A
identities/relationships and the full B DTOs unchanged. These were bounded data
observations, not a per-record export acknowledgement. The absence of an export
error does not identify the attempted write's server fate or establish a server
permission rejection. No general synchronization latency bound follows.

## Evidence and retained state

All three original final reports and hashes were independently checked. They
had no stage errors, detached stores, final retention and zero diagnostic
write/drop counters. Completed native events succeeded; started-only snapshots
are not failed operations.

| Final report | SHA256 |
|---|---|
| owner-readonly | `28b72193a598f23088dc219cb5ce1933cb95fd9d82702ff126f7b69560597009` |
| participant-readonly-probe | `766364c57ff84ca0e9ddeaa6bc962eea1feefdec557411739d03198a8c8eb249` |
| owner-observe-readonly | `883bf85c37c9330e6cf72921875272e4977b41900dcc3c980b84f3d412f19844` |

Archive outside Git:
`~/Library/Application Support/GraphEvoLab/Evidence/2026-10-26-V02-readonly-605155F3-6AC9-4A5E-B248-15BC88569647/`.
Original reports/traces/manifests and raw device logs remain private; no account
identities or invitation URLs are published.

The coordinator explicitly stopped each process after final evidence retention.
Read-write restoration was **not executed** after observing local save success.
Permission remained read-only for the next separately authorized revocation
control. The consumed probe path is parked permanently and must never reopen,
so its locally saved attempt is not given another export opportunity through a
new app opening. No probe file deletion, remote purge, wipe or silent correction
was performed. Closing/stopping is not a CloudKit quiescence acknowledgement.

The frozen source passed 73 local tests. Final log:
`test_sim_2026-10-26T07-25-21-893Z_pid60425_d223c5b9.log`; result:
`test_sim_2026-10-26T07-25-21-893Z_pid60425_34402477.xcresult`.
Tests were not rerun for this documentation update and are not substituted for
the physical observations. Broader permissions, revocation/leaving, lifecycle,
offline/conflicts, GraphEvo facades and the full V02 matrix remain separate checks.
