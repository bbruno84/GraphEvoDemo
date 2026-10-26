# V02 — incremental objects in an accepted cross-account share

**Owner additions and deletions were recovered; participant addition did not
complete and the XR process crashed.** This is a mixed experimental result,
not a full pass for collaborative graph editing. The test used only public
`NSPersistentCloudKitContainer` permission, sharing and Core Data context APIs.
No Core Data internals were inspected to explain the crash.

## Fixture and successful owner transitions

New run `308AF787-A134-45F1-BAE5-3CE8709FBEE9` began with owner-only A/B
shares and five owner rows on the iPad. A private RW invitation to the
authorized different-account XR was accepted into new private/shared stores;
the XR recovered A3 and no B. The mutation case started as
`5A4B187D-E5A2-4C0B-B81C-79362CC5783C`.

The XR opened its original accepted-share stores **before** `owner-add`.
The iPad then saved A-003 related to A-root and changed A-001 to
`alpha-owner-updated`, without explicitly sharing the child. Its final report
contained A4+B2, the new child's record mapping, and the same A share zone.
The XR's already-open observer remained on A3 throughout its 90-second window
and correctly failed that bounded live criterion. A later separate, read-only
reopen showed A4, including the new relationship and mapping. Case
`C568D27B-BA0E-4FED-9918-418DCEA7E4BC` retained a full 60-second XR
confirmation of A4. All four A nodes had equal values, parents, inverse
children, normalized record IDs and share IDs on the two devices; B remained
owner-only. This supports eventual membership via normal relation/save under
these conditions, but **does not establish live delivery within 90 seconds**.

The XR next opened A4 before `owner-delete` in the resumed case. The iPad
deleted A-003 through its context and saved. The same open XR container
observed A4→A3 and the corrected inverse root link; its 180-second final
report retained exact A3 with no errors. The iPad's full 120-second report
retained A3+B2, matching surviving record/share identities and unchanged B.

## Participant creation: unresolved crash

The iPad opened its original owner stores with A3+B2 and published readiness.
The XR then began `participant-add`, which checks public RW permission advice
and attempts to insert A-004 into its explicit shared store, relate it to
A-root, change A-002 and save. Its last retained report had reserved the
stage but still had `mutationSaved=false`; the process ended before a final
report. The device crash log records `NSInvalidArgumentException` with
“key cannot be nil” during Core Data's CloudKit serialization work. This is
the observed failure boundary, **not a diagnosis of an unsupported API** or
proof that the local save did or did not happen. The owner observer completed
its full 180-second window with unchanged A3+B2 and no A-004. The XR's local
store state after the crash was not reopened, and the write was not replayed.
Participant deletion and further mutations in this run were stopped because
the participant's durable state is uncertain.

Apple's [Core Data sharing sample](https://developer.apple.com/documentation/coredata/sharing-core-data-objects-between-icloud-users)
documents private/shared stores and explicit store assignment, while the
[WWDC21 sharing session](https://developer.apple.com/videos/play/wwdc2021/10015/)
states that permitted participants can add records to shared zones. A
[separate supported-API reproduction](v02-participant-explicit-members-2026-10-26.md)
subsequently succeeded using explicit assignment to the existing share. That
positive result does not explain or erase this run's relationship/save crash.

## Provenance and retained evidence

Both devices used the dedicated CloudKit **Development** container
`iCloud.com.valerioburiani.GraphCKDemo` and a signed app with matching bundle
and entitlements. The initial mutation binary SHA256 was
`9b402ffa8e66ef66d7e52e5ab0a94b87fcc10791fa6d95c0dd4dcacf3d1f1be3`
(app Swift SHA256
`72fda25e318bc3ba337086ad030be75cf9cdd1ecc189b974b51523058d360331`).
The read-only resume and later stages used binary SHA256
`3fece755f26833c839e1625ae0d15ff85b871534337a1e288dd26f178101dc1d`
(app Swift SHA256
`b2d9cc9fbed07d231b1bb576a35c2b2a771bc2242f963980dfe52fb85986d51f`).
Xcode 27.1 / Swift 6.4, Swift 5 language mode, Demo base `3acfd5e`, and
GraphEvo pin `4dc0a7f9a717ee535e9b630b998cd6c869a2d538` were recorded.
The full Simulator suite passed after the resume change. These local checks
do not certify CloudKit behavior.

The private archive
`2026-10-26-V02-mutations-5A4B187D-E5A2-4C0B-B81C-79362CC5783C`
contains the reports, exact comparisons, build/installation records, protected
invitation and crash log outside Git. Key SHA256 values: first owner-add
`eea9dde20207c69da59e8dce3ba6e6aa9a63ff23230c852037a3fc3fa9708b13`,
missed live observer
`f7f3bed9751eebe869659f34030581b9dcae4650601d5a4d0de00161aa9b9ff0`,
later XR A4 confirmation
`3bffeea8a2a64953de09df947cfc0e52aa28a621dda34219c1f9095f4f24ba7d`,
owner deletion `0bbee572c43fe0b00137b323a9f8cc4aa6e487228c46bbaed76f3965e056cc37`,
XR deletion observer `5b53ea9d0c77caae67ddcd6da216f22cc3ef91687b216cd317d2977b0c9232e8`,
participant-add checkpoint
`071bafed3b7406195782319146428f658f45a8260352dcadef4450ac3c707fcf`,
and crash log `b33f76c315bf08a1505c68bd1525176d3b5fd7c30ac33a82d8b274dc593e806b`.
The crash report stays private because it can contain device information.
