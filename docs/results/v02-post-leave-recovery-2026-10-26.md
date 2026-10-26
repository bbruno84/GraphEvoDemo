# V02 — fresh recovery and old-URL metadata after leave

Status: **bounded post-leave behavior observed**. In fresh XR private/shared
stores, all 86 snapshots remained empty across the full 180-second window,
without another invitation or acceptance. The old URL returned matching
participant metadata before and after: private-user role, read-write permission,
and `pending` acceptance, not `accepted`. The owner retained A/B and also listed
the XR as pending. This supports loss of accepted participation for this case
and absence of automatic recovery during the observed window. It does not prove
permanent revocation or whether the old URL can be accepted again.

## Procedure and observations

This follows the [partial reinvite/leave case](v02-reinvite-voluntary-leave-2026-10-26.md).
The original run is `8A6E6A45-2D7D-44C9-B127-32A552C1F773`; prior lifecycle case
`88DA5EBE-FBD8-4A71-8B0F-E6D959703807`; new read-only case
`90B97D91-5F58-4C27-A91C-42096AB12404`. The owner remained the iPad and the
participant the different-account XR. The [probe guide](../features/v02-post-leave-recovery.md)
describes the capability boundary, protected existing invitation and paths.

The participant opened a new isolated private/shared SQLite pair, with both
store IDs distinct from its original normal stores. No seed, save, invitation,
acceptance or purge was called. The initial and final snapshots were empty;
86 of 86 successful snapshot reads were empty. Neither A nor B appeared, no
private copy appeared and no first-recovery time was recorded. The snapshot
window ran 09:09:53–09:12:54 UTC and completed the configured 180 seconds.
The fresh path is permanently consumed and must not reopen.

`CKContainer.shareMetadata(for:)` read the prior lifecycle URL before opening
and again after the observation. Both XR calls returned metadata without error:

| Public metadata field | Both XR reads |
|---|---|
| Participant status | `pending` (raw 1) |
| Participant role | `privateUser` (raw 3) |
| Participant permission | `readWrite` (raw 3) |
| Public permission | `none` (raw 1) |
| Container, owner and share matching flags | All true |

Thus the old URL still resolves to a pending invitation. This stage deliberately
does not accept it. A returned pending invitation is distinct from active
accepted membership and from a tested ability to regain data by accepting again.

In parallel, a new owner process reopened the original store IDs. It made
85 successful snapshot reads during its 180-second window
(09:09:51–09:12:51 UTC). The retained opening and final rows contain all five
original A/B values, links and cloud record IDs. The opening snapshot lacks
share DTOs; the final snapshot contains all five, with original share IDs and
complete unchanged B. Final `ownerDataMatches` is true. A's final participants
are the accepted owner and pending RW XR; B contains only the accepted owner.
The report retains the sample count and endpoints, not every intermediate DTO,
so it does not establish 85 complete share-identity comparisons.

The owner's two old-URL metadata reads returned the owner's role and accepted
status, with container/share matching flags true. **Their `ownerMatches` flags
are false.** This is retained as an unresolved metadata identity-comparison
limitation; no aliasing or propagation explanation is inferred. It does not
change the XR reads' three true matching flags or the independent owner record/
share ID comparison. Do not summarize all metadata checks on both sides as
matching. No owner write or participant-management operation occurred.

## Meaning and limits

Apple describes acceptance state as controlling record availability: accepted
participants can access shared records, while pending participation has an
acceptance step. Metadata reports the retrieving user's participation state.
See [CKShare.Participant](https://developer.apple.com/documentation/cloudkit/ckshare/participant)
and [CKShare.Metadata](https://developer.apple.com/documentation/cloudkit/ckshare/metadata).
Here, pending XR metadata and a wholly empty fresh replica agree with loss of
accepted access during the test. The retained invitation is still pending.
Whether the old URL can be reaccepted without a new owner invitation was not
tested; no acceptance operation belongs to this read-only stage.

The previous strict owner-only lifecycle criterion remains unmet: pending XR
still appears in the owner participant list. This result refines the functional
meaning of that state without erasing the prior two failed owner-only checks.
No permanent access-denial guarantee, synchronization deadline, offline behavior,
account change, general privacy guarantee or complete V02 result follows.
A negative observation of 180 seconds is bounded evidence, not proof that a
future import is impossible. Metadata reads do not certify import completion.

## Provenance and retained reports

Source `f5a182c964d71dc6aafcb1474af186ec8ae09339`; app Swift source SHA256
`a755b6d07ca14415fa523c59a04db60b245da4a93bc2d9726f6fa6bb91ab0ffe`.
The simulator suite passed 88 tests before the hardware run. Toolchain:
Xcode 27.1 (27A9275), Swift 6.4 in Swift 5 mode; original owner iPadOS 27 and
XR iOS 18.7.10; Development resources. GraphEvo develop pin remained
`4dc0a7f9a717ee535e9b630b998cd6c869a2d538`.

All intervals are UTC on 2026-10-26:

| Stage | Whole-stage interval | Final report SHA256 |
|---|---|---|
| participant-fresh | 09:09:50–09:12:55 | `b6f347ecfcd36fcdaece6a71a262ece9bc867db57893183f97ff8b8c58eb83c7` |
| owner-snapshot | 09:09:50–09:12:53 | `361b850cb026e31590ca069ad5459fcfeb620a42c7529aaf33eb1550d31e5ec4` |

Both final reports were retained, stores detached and processes stopped.
Stage/snapshot/metadata errors, dropped events, dropped trace entries and trace
write failures were zero. Independent review decoded the raw reports, recomputed
these hashes, checked the whole-window counters and metadata states, compared
store inventories, and compared owner opening/final data and final share IDs
against the pre-reinvitation fixture. The unresolved owner matching flags and
missing opening share DTOs remain explicit.

Private archive:
`2026-10-26-V02-postleave-90B97D91-5F58-4C27-A91C-42096AB12404` under the local
GraphEvoLab evidence directory. Sensitive invitations, raw reports and device
logs remain outside Git. No GraphEvo facade API is certified by this direct-
framework control.
