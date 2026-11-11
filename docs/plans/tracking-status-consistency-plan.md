# Plan: make watch status consistent between the library, Bangumi and AniList

Source: the blind-spot audit at the end of
`docs/reviews/tracking-ui-followup.md` (haru.10). Owner priority: data
synchronization over UI polish.

## Problem

Three stores disagree about "what status is this show in".

| Store | Written by | Read by |
| --- | --- | --- |
| `collectibles` (local category) | 追番 screens, the WebDAV apply, and now the drawer mirror | 追番 lists, the info page's tracking entry |
| Bangumi entry | outbox drain (`TrackingSync`) | the drawer row |
| AniList entry | outbox drain | the drawer row |

Today:

- A drawer status change writes **one** tracker and the local category
  (haru.10). A 追番 status change writes the local category and **every** bound
  tracker (`BangumiBindingManager.statusChanged` enqueues with no tracker id).
- A status changed on bgm.tv, on AniList, or on another device never reaches
  the local category, so 追番 keeps showing the old bucket.
- The mirror rewrites the whole library row from the info-page item, resetting
  its timestamp and copying a possibly thinner item over a richer stored one.
- A failed mirror write is logged only; the drawer shows the new tracker status
  while 追番 keeps the old category.

## Decisions

1. **Bangumi is the canonical watch-status source for the library.** A Kazumi
   subject *is* a Bangumi subject, so its Bangumi collection is the same fact
   the library models. AniList is a manual secondary match and stays
   independent; it does not drive the local category.
2. **Local writes stay optimistic and per-action.** A drawer change writes the
   one tracker the owner touched plus the local category. A 追番 change keeps
   its existing behaviour (local + every bound tracker). We do not silently
   fan a drawer change out to the other tracker: that would overwrite a status
   the owner may have set deliberately.
3. **Remote never wins over a pending local edit.** Any remote-to-local
   propagation is skipped while that subject has an outbox row, so a queued
   local write is never visually reverted.
4. **The library row is updated in place.** Changing a category must not
   replace the stored `BangumiItem` or reset `CollectedBangumi`'s timestamp;
   only `type` changes.

## Slices

Each slice: test first, watch it fail for the stated reason, one local commit,
no push of anything else, no account writes in tests.

### Slice 1: update the library category in place

Files: `lib/repositories/collect_crud_repository.dart` (interface + impl),
`lib/pages/collect/collect_controller.dart`.

- Add `Future<void> setCollectType(int id, int type)` to the repository
  interface and implementation: if a row exists, rewrite it with the same
  `bangumiItem` and the new `type` (keep its existing timestamp field as-is);
  if not, do nothing and return `false` so the caller can insert instead.
- `CollectController.addCollectFromTracker` uses it: insert through
  `addCollectible` only when the row is absent, otherwise `setCollectType`.
  Keep the collect-change append in both cases (action 1 vs 2).
- Tests: existing row keeps its item and timestamp while only `type` changes;
  absent row is inserted; a collect change is recorded each time.

Done when: the mirror no longer clobbers the stored item or its timestamp, and
a test proves it.

### Slice 2: surface a failed mirror instead of swallowing it

Files: `lib/pages/info/tracking_sheet.dart`.

- On mirror failure, keep the tracker write (already committed) and show a
  message that names what did not happen, e.g.
  `本地追番状态未更新，追踪状态已保存`. Use the existing
  `KazumiDialog.showToast`; do not add a dialog or a retry loop.
- The mirror must still not block the dialog's completion.
- Test: a failing `onMirrorStatus` seam surfaces the message and leaves the
  tracker outbox row intact.

Done when: a local failure is visible and cannot be mistaken for a tracker
failure.

### Slice 3: propagate a Bangumi status change into the library

Files: `lib/services/tracking/tracking_sync.dart` (or a small collaborator it
calls), `lib/services/storage/storage.dart`, `lib/pages/info/tracking_sheet.dart`.

- After a successful Bangumi read in the drain, when the subject has no outbox
  row, map the remote status to a `CollectType` and update the local category
  through the same in-place path from slice 1. No enqueue, no collect change
  feedback loop: the record already reflects the remote.
  - Do this behind an injected callback so `TrackingSync` does not import the
    library directly and stays unit-testable with fakes.
  - Bangumi only. AniList rows never drive the local category.
- Apply the same rule when the drawer's own read refreshes a Bangumi row, so an
  edit made on the web shows up the next time the drawer opens.
- Skip entirely when a pending/outbox row exists for the subject (decision 3),
  and skip when the mapping is unchanged.
- Tests: remote 看过 with no pending row moves the library category; remote
  status with a pending row is ignored; an AniList-only status change never
  touches the library; a mapping no-op writes nothing.

Done when: a status set on bgm.tv (or on another device) reaches 追番 without
creating an outbox row or a collect change.

### Slice 4: docs and limits

- Update `docs/design/tracking.md`: the store table, decision 1–4, and the
  propagation rule.
- Replace the audit section in `docs/reviews/tracking-ui-followup.md` with what
  is fixed and what deliberately remains:
  - still silent-by-design: nothing enqueues on success;
  - 追番 still writes every bound tracker; the drawer still writes one;
  - a drained failure still leaves the local category ahead of the tracker
    until the outbox retries (optimistic local-first);
  - AniList edits never move the library.
- Gates: plain `flutter analyze` clean, full `flutter test` green with the new
  tests.

## Explicitly out of scope

- New settings or toggles for any of the above.
- AniList → library propagation, or making AniList canonical.
- Removing entries from the drawer (deletion stays in 追番 screens).
- Reworking the outbox retry model or the WebDAV payload.
- Merging status across devices beyond what WebDAV already does for
  `collectibles`.

## Risks

- Propagation could fight a user who edits the library while a drain is running;
  the outbox guard covers the queued case, but a read that lands mid-edit can
  still lose by one round. Accept and document; do not add locking.
- Writing the library from the drain widens the blast radius of a tracking
  error; every write must be best-effort and must never fail the drain.
