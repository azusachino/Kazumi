# Plan: coordinate watch status across Bangumi, WebDAV, the library and devices

Follows `tracking-status-consistency-plan.md` (haru.11), which fixed single-device
consistency. This plan closes the cross-store and cross-device holes that remain.

## The stores and who owns each fact

| Store | Owns | Travels over |
| --- | --- | --- |
| Bangumi collection entry | **canonical watch status** for a subject | the tracker |
| AniList entry | secondary manual match | the tracker |
| `collectibles` (在看/想看/…) | what 追番 lists | WebDAV (`collectibles.tmp` + `collectchanges.tmp`) |
| `trackingEntryCache` | what the drawer displays | never (per device, display only) |
| `trackingOutbox` | pending writes | never (per device) |

Coordinate on one rule: **Bangumi owns the status of a show; the local category
is this device's projection of it; WebDAV carries the projection and the intent
between devices; AniList is independent.**

## Holes this plan closes

1. **Propagation is invisible to WebDAV.** `GStorage.setCollectTypeIfPresent`
   rewrites the category with no `CollectedBangumiChange`. `CollectSyncMerger`
   only replays *recorded* changes over a remote base, so the next collectibles
   sync reverts the propagated category. A bgm.tv edit shows once, then is
   undone.
2. **WebDAV merge is not last-write-wins by time.** Remote box is the base and
   local changes replay in id order, so the device that syncs later wins
   regardless of when the user acted.
3. **A category arriving over WebDAV never reaches the trackers.** Apply
   enqueues nothing, so a device that receives 在看 keeps Bangumi at 想看 until
   someone edits locally.
4. **No loop protection exists for 1–3 once writes travel both ways.**

## Decisions

1. Every category write records a change, including propagation and WebDAV
   apply. The change log is the only channel WebDAV merges, so a silent write is
   a lost write.
2. A change carries its **origin**: `user` or `tracker`. Origin decides whether
   applying it may enqueue a tracker write. A tracker-origin change never
   enqueues, which bounds the loop: tracker → local → other devices → their
   local, and stop.
3. The merge is **last-write-wins per subject by change timestamp**, ties keep
   local. The box rows are a projection, not the ordering input.
4. Apply may enqueue **only a delta**: a subject whose merged category differs
   from the local one, whose winning change is `user` origin, and which has no
   outbox row.
5. AniList stays out of this plan: it is a manual match and never drives the
   library.

## Slices

Test first, one commit each, no live accounts in tests.

### Slice 1: record the origin of a category change

Files: `lib/modules/collect/collect_change_module.dart` (+ regenerated adapter),
`lib/services/storage/storage.dart`, `lib/pages/collect/collect_controller.dart`,
`lib/services/sync/webdav.dart` (call site), `app` migration if needed.

- Add `@HiveField(4) int origin` with `0 = user`, `1 = tracker`; absent rows in
  older boxes read as `0` (additive field, no typeId change). Regenerate the
  adapter and verify the diff adds only that field.
- `GStorage.appendCollectChange` takes `origin` (default `user`); the drain
  propagation passes `tracker`.
- Tests: a user write records no new fields beyond origin 0; propagation records
  origin 1; an existing row without the field loads as user.

### Slice 2: make the propagation survive WebDAV

Files: `lib/services/storage/storage.dart` (`setCollectTypeIfPresent` →
`followTrackerStatus`), tests.

- Propagation appends a `tracker`-origin change together with the category
  write, in the same serialized write, so the pair is atomic from the merger's
  point of view.
- Test: after propagation, a `mergeWebDav` against a remote box that still holds
  the old category keeps the new category (this is exactly hole 1).

### Slice 3: last-write-wins merge per subject

Files: `lib/modules/collect/collect_sync_merger.dart`, its tests.

- Build the union of local and remote changes by id; per subject keep the change
  with the greatest `timestamp` (tie → local). Apply those winners to the remote
  box base, as today, including `action == 3` deletes.
- Keep the returned `changes` as the union so both sides converge on the same
  log.
- Tests: remote newer wins; local newer wins over a newer remote box row; tie
  keeps local; a delete beats an older add; unrelated subjects untouched.

### Slice 4: apply enqueues only a user-origin delta

Files: `lib/services/sync/webdav.dart`, `test/webdav_service_test.dart`.

- After `patchCollectibles`, compare each merged subject's category with what
  the tracker currently reflects. For subjects where it differs, the winning
  change is user-origin, a binding exists, and no outbox row is pending,
  enqueue that category (no progress, no score).
- Tracker-origin winners and unchanged subjects enqueue nothing.
- Two-device test with the in-memory client: A sets 看过 and syncs; B syncs and
  its trackers receive 看过 exactly once; a second sync on either device
  enqueues nothing.

### Slice 5: docs, evidence, limits

- Update `docs/design/tracking.md` with the ownership table, origin rule, LWW
  rule and the delta rule.
- Update `docs/reviews/tracking-ui-followup.md`: what is now coordinated and
  what still is not.
- Gates: plain `flutter analyze` clean, full `flutter test` green.

## Known limits this plan accepts

- Convergence is eventual, at sync/drain points; there is no push channel.
- Change ids are second-granularity; two same-second edits on different devices
  resolve by tie-break, not by real order.
- AniList is never propagated to and never drives the library.
- A drain failure still leaves the local category ahead until retry.
- Deletions stay local-only against the trackers.

## Risks

- Adding a Hive field to a synced box: older app versions ignore it (safe), but
  a downgrade will drop origin information; a tracker-origin change read by an
  old build looks like a user change and can re-enqueue. Accept, note it.
- Apply now writes to trackers on some paths; it must never fail the collect
  sync, and it must never enqueue for a subject the owner did not touch on this
  device.
- The merge change touches the most-used sync path; keep the existing behaviour
  for a single device unchanged, which the current tests already pin.
