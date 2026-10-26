# V02 — participant creates and deletes a member in an existing share

**The explicit existing-share path passed on the iPad and the different-account
XR in this isolated run.** The participant added A-004 to A's already accepted
share, linked it to A-root, and later deleted it. The owner's already-open
container observed both transitions. This establishes feasibility for this
public-API path and fixture, not a guaranteed CloudKit delivery time or a
general result for the earlier normal relationship/save insertion.

## Preparation and the invalid preliminary variant

Both devices used the dedicated CloudKit **Development** container
`iCloud.com.valerioburiani.GraphCKDemo`. A private read-write invitation to
the XR was accepted. The owner kept A3+B2 in its private store and the XR
recovered A3 in its shared store, with no B or run rows in its private store.

A separate preliminary run `049B8F2A-BA85-42A9-A20A-0D02C2E4DDED`, case
`B42DB92C-8129-47EA-BCBA-2B0C2406331C`, placed an unconnected new object
in the participant's **private** store and called
`NSPersistentCloudKitContainer.share(_:to:)` with A's existing share. The call
returned `NSCocoaErrorDomain:134060` before the stage reported completion. Its owner
observer stayed at A3+B2 for its full 180-second window. Because this routed
the object through the private store while targeting an existing share in the
shared database, it is an invalid comparison for the shared-store path. The failed
participant store was not reopened or reused.

## Supported shared-store assignment

The corrected run `E41BC9CA-320A-42FB-9F76-7B2E604B4267`, case
`C72ECAC9-948D-4EC1-8728-D573A3B94DEF`, started from a fresh accepted A3
and owner A3+B2. The XR inserted A-004 as an **unconnected** Core Data object,
assigned it explicitly to its shared persistent store, and saved. It then
called `share([child], to: existingShare)` using the `CKShare` fetched for
A-root, linked A-004 to A-root, and saved again. This ordering avoids passing
an already-shared root through the share API's relationship traversal. The
private store remained empty for this run.

The owner observer was ready **before** the participant wrote. The XR retained
an exact A4 local result for 180 seconds (85 samples); the iPad's same open
container observed A3+B2→A4+B2 and retained the final state for its complete
180-second window (86 samples). It first saw A4 at
`2026-10-26T10:33:43Z`. The independent comparison matched every A row's
value, kind, parent, inverse children, normalized CloudKit record ID and
share ID across accounts. Existing A record/share IDs were preserved, and
owner B2 was byte-for-byte equal to its baseline. Both final reports had no
errors, detached their stores, and were retained.

The XR then used its shared-store context to delete A-004, with no new share
call. The already-open iPad observed A4+B2→A3+B2; its first exact target was
at `2026-10-26T10:39:13Z`. Both deletion reports covered 180 seconds
(owner 85 samples, participant 86), ended without errors, and detached their
stores. The final comparison found A-004 absent on both devices, the root's
inverse link restored, all surviving A record/share IDs stable, identical A
values and links across accounts, owner B unchanged, and no participant
private-store rows for this run. The processes were terminated after the
reports were retained.

## Interpretation and provenance

Apple's [Core Data sharing sample](https://developer.apple.com/documentation/coredata/sharing-core-data-objects-between-icloud-users)
documents private/shared stores and explicit assignment. The
[share API](https://developer.apple.com/documentation/coredata/nspersistentcloudkitcontainer/sharemanagedobjects%3Atoshare%3Acompletion%3A)
supports an existing `CKShare` and traverses related objects. The
[WWDC21 session](https://developer.apple.com/videos/play/wwdc2021/10015/)
states that permitted participants can add records to shared zones. The
successful run is consistent with that public contract. The earlier
[normal relationship/save crash](v02-incremental-shared-members-2026-10-26.md)
remains unresolved and must not be conflated with this explicit path.

The signed addition binary SHA256 was
`176e45711e78030aa6c76d43fc8f6c035991aaf3c85eacc721815b341344d271`
(laboratory Swift SHA256
`a7d34270bdc635ddffb4216d421bcac169611b9750f89364fa5d990baa64ce0c`).
The deletion binary SHA256 was
`a2d0e9593fb6abe57abac0a940a44f72e369a8016ca6a95826c6f9e95335a780`
(laboratory Swift SHA256
`88c6a65c31a71dd890ce09eb850c2e059f78d776d629cada5f54759f1f9971ef`).
Both used Xcode 27.1 / Swift 6.4 in Swift 5 language mode, Demo base
`0f18d6d`, and GraphEvo pin `4dc0a7f9a717ee535e9b630b998cd6c869a2d538`.
The full Simulator test suite passed after the deletion roles were added;
those local tests do not certify CloudKit behavior.

The private evidence directory
`2026-10-26-V02-explicit-shared-C72ECAC9-948D-4EC1-8728-D573A3B94DEF`
contains signed build and installation records, protected identity/invitation
envelopes, original report files, and comparison summaries outside Git. SHA256
of the add owner/participant reports:
`9bac2ef72b2189341e44ac804d856d31d242701a6289b8ba97aa6e2b9f6dff80`,
`956e5320db20cf208e9f530b415fad050c99421d786539e45dd10bfa781731cd`.
SHA256 of the delete owner/participant reports:
`ce935fe676293ad14613bba4ac073f8c0679eae46ada964dc0116db059dc3bc0`,
`cb9084dfb8a36008e3cdc3ebab13e670331f6d927d3988aeda74de3efee9ce5c`.
The comparison-summary hashes are
`a47ff2855160bb4bf661b896581eba651712630765c89413dc56a4250179d8e9`
and `e6dd92eec4449c516bd20f0aa96b78a2c7ec1f3a62a65cd21040db340f3ce92c`.
