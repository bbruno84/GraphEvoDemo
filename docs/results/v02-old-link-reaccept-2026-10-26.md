# V02 — the prior invitation can be accepted after leaving

**Observed on the authorized iPad owner and different-account iPhone XR:**
the XR reaccepted the *same* private invitation URL after its earlier
`purgeObjectsAndRecordsInZone` leave. No new invitation was made. The old URL's
validated public metadata was `pending` (raw 1); the explicit shared-store
`acceptShareInvitations` call ran once. The original XR stores recovered the
exact three A members with the prior values, links, record and share identities.
B remained absent on the XR. This establishes that voluntary leave did not
permanently prevent rejoining through that still-pending URL in this fixture.

## Functional observations

The original run was `8A6E6A45-2D7D-44C9-B127-32A552C1F773`, the completed
leave case was `88DA5EBE-FBD8-4A71-8B0F-E6D959703807`, and this one-shot
reacceptance case was `384DF70D-841E-4823-9175-3AAB06B75F46`. The XR's
previous state was `.left`, with three pre-leave A rows and the two original
store identifiers. Its opening snapshot was empty. The new case was reserved
before acceptance. The participant report ended without errors, recorded
`acceptanceAPICalled=true`, `alreadyAccepted=false`, and exact recovery. No
fresh or consumed read-only store path was opened.

An independent iPad process observed the original owner stores for the full
120-second window. Its 57 samples ended with all five owner A/B members and
matching data/identities. A's public share snapshot listed the owner and XR as
`accepted` (raw 2); B listed only its owner. Both reports finished and detached
their stores before process termination. A prior read-only fresh XR replica had
stayed empty for 180 seconds while metadata was pending; the explicit old-link
acceptance is the distinguishing action in this case, not evidence of a
configurable synchronization deadline.

After retaining those reports, a **separate cleanup case**
`CFD3B045-9DF3-458F-B83E-B95F92277EAB` removed only the XR participant from
the disposable A share through `removeParticipant` and
`persistUpdatedShare`. The XR first retained a complete A3 baseline, then
observed A3→A0 in its already-open original stores during the full 180-second
window. Owner removal and an independent owner reopen retained A/B5, with A
owner-only and B unchanged. No owner object or zone was purged.

## Provenance and limits

The signed Development app targeted
`iCloud.com.valerioburiani.GraphCKDemo`, bundle
`com.valerioburiani.GraphCKDemo`; its signed entitlements specified Development
and the matching container. Xcode 27.1 / Swift 6.4 built Demo HEAD `f3601f4`
plus the focused old-link source diff (app Swift SHA256
`ac82cbc750ad85be7007daecb44aa7475a054b8caa31a605fbd5e8f5a03f76d9`),
with GraphEvo pinned to `4dc0a7f9a717ee535e9b630b998cd6c869a2d538`.
The focused lifecycle tests and complete app test suite passed on Simulator;
those tests verify the harness, not CloudKit behavior. The device binary SHA256
was `0783c10f100c744c96bef12fbd4a347a3265bdd8c0f65cd489f1ee4b3f204f9c`.

The private evidence archive is
`2026-10-26-V02-oldlink-384DF70D-841E-4823-9175-3AAB06B75F46` under the
local GraphEvoLab evidence directory, outside Git. Final reacceptance reports
have SHA256 `3cdc2275eaea9096ace621ac82a6ad492bf6ed00f29f1204465d3cf1da67648b`
(XR) and `3a0c3cbfe9e4b1136a84af62eef3c345bd6b42736e09a1a805233fd4ef2f82c6`
(iPad). Cleanup reports have SHA256
`711adc5e4d163e8d4c623029afef39a711b366939c898b26cf15e0b8655c53c6`
(XR), `03fb50a74c8d359fe8e7fe3c6f5d0a84ed081fdbb52bb03547c0fdd7cfb3a395`
(owner removal), and
`407a7c7ca46abd3555841f37c4564851076f340bbbe821816d6d1551b58a0153`
(owner reopen). The protected invitation and raw account identifiers remain
outside Git. This case does not test a new invitation after leave, concurrent
writes, selective local download or the permanence of any other share's access
policy.
