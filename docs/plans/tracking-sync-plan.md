# Plan: bindings for imported/synced shows, and AniList matches over WebDAV

Spec: `docs/design/tracking-workflow.md`. Evidence: `docs/handoff-tracking-sync-gaps.md`.
Base: kazumi `main` @ `66525302`. Gates: `mise exec -- flutter analyze` and
`mise exec -- flutter test` (baseline: 103 tests under `test/tracking` +
`collect_sync_test` + `webdav_service_test` pass). After any `flutter` run,
`git checkout pubspec.lock` if it changed and you did not mean to.

Rules for every slice: one commit per slice, message `<type>: <why>`; add the
test first and watch it fail for the stated reason; no push; do not write to
the owner's real Bangumi/AniList account in tests (use `FakeTracker` /
`FakeAdapter` from `test/tracking/`). Do not merge slices.

## Slice 1: one place that ensures bindings for collected shows (fixes the badge)

Files: `lib/services/tracking/bangumi_binding.dart`,
`lib/services/tracking/bangumi_import.dart`,
`lib/pages/settings/sync/bangumi_sync_page.dart`.

1. In `BangumiBindingManager` add
   `Future<int> ensureBangumiBindings(Iterable<BangumiItem> items)`: loops
   `_ensureBinding` inside ONE `_queued` call; returns how many were created.
   `_ensureBinding` already skips signed-out and opted-out subjects.
2. `BangumiImport` gets an optional ctor arg
   `Future<void> Function(BangumiItem)? ensureBinding`. In `run()`, call it for
   EVERY entry whose type `isCollected`, before the `if (!inserted) continue;`
   (so already-local shows get one too). It must enqueue no remote write.
   `bangumi_sync_page.dart` passes
   `GStorage.bangumiBindingManager.ensureBangumiBinding`.
3. Tests in `test/tracking/bangumi_import_test.dart` (reuse `MemoryCollect`,
   `MemoryBindings`, `FakeAdapter`): import 2 entries → 2 bindings; opted-out
   id → none; entry already local → binding created, local status untouched;
   outbox stays empty. Existing import test must still pass unchanged.

Done when: new tests pass, whole suite passes, `flutter analyze` clean on touched files.

## Slice 2: WebDAV apply and startup backfill create bindings

Files: `lib/services/sync/webdav.dart` (`_syncCollectibles`),
`lib/pages/collect/collect_controller.dart` (`syncCollectibles`),
`lib/main.dart`, `lib/services/storage/storage.dart`.

1. After `GStorage.patchCollectibles(...)` returns in `_syncCollectibles`
   (and in the no-remote early-return path), call
   `GStorage.bangumiBindingManager.ensureBangumiBindings(
   GStorage.collectibles.values.where(isCollected).map(bangumiItem))`.
   Wrap in try/catch + `KazumiLogger().e` so a binding error never fails sync.
2. Backfill: in `main.dart` next to `trackingSync.drain()`, run the same call
   once per start (idempotent, cheap). Skip silently when not signed in.
3. `isCollected`: use the `CollectType` extension already used by
   `bangumi_import.dart` (`type.isCollected`).
4. Tests: extend `test/webdav_service_test.dart` or add
   `test/tracking/collect_binding_backfill_test.dart`: collectibles present,
   no bindings → after backfill one per collected item; run twice → no
   duplicates; outbox empty; opted-out id skipped.

## Slice 3: updatedAt on bindings and tombstones

Files: `lib/services/tracking/models.dart` (+ regenerate `models.g.dart`),
`bangumi_binding.dart`, `anilist_binding.dart`, `stores.dart`,
`lib/pages/info/tracking_sheet.dart` (`_editOffset`, remove at ~line 138),
`lib/services/storage/storage.dart` (open the box).

1. `TrackingBinding`: add `@HiveField(12) final DateTime? updatedAt` (ctor
   named arg, default `null` = very old). Thread it through `synced()` (keep
   value) and the manual copy in `_editOffset` (set to `clock now`).
   Regenerate: `mise exec -- dart run build_runner build --delete-conflicting-outputs`;
   check the diff only adds field 12 and no typeId changes.
2. Tombstones: a plain `Box<int>` named `trackingTombstones` (key =
   `TrackingBinding.key`, value = deletedAt millis since epoch). No adapter.
   Open it in `storage.dart` beside `trackingBindings`; add a
   `static late Box<int> trackingTombstones`.
3. Writers: `AniListBindingManager.bind/rebind` set `updatedAt = now` and
   delete any tombstone for the key; `unbind` writes the tombstone then
   deletes the binding; `stopTracking` writes the tombstone too (keeps the
   existing exclusion list behaviour); `_editOffset` sets `updatedAt`.
   Inject a `DateTime Function() clock` (default `DateTime.now`) in both
   managers for tests.
4. Tests: bind sets updatedAt; unbind leaves tombstone and no binding;
   rebind clears tombstone; existing `anilist_binding_test.dart`,
   `bangumi_binding_test.dart`, `tracking_ui_test.dart` still pass. Add a test
   that an old box row without field 12 loads with `updatedAt == null`
   (write a binding with field 12 absent via a hand-built adapter or by
   asserting `null` default through the ctor).

## Slice 4: pure merge function for the tracking file

Files: new `lib/modules/tracking/tracking_sync_merger.dart` and
`lib/modules/tracking/tracking_sync_file.dart`; test
`test/tracking/tracking_sync_merger_test.dart`. No WebDAV code in this slice.

1. File model (JSON): `{"version":1,"bindings":[{subjectId,trackerId,remoteId,
   title,cover,total,episodeOffset,statusLocked,score,updatedAt}],
   "tombstones":[{key,deletedAt}],"bangumiExcluded":[ids]}`. Only AniList
   bindings are exported; Bangumi bindings are derived. Never export tokens,
   `generation`, `lastRemoteProgress`, `lastSyncAt`, outbox.
2. `merge(local, remote)` → `{bindings, tombstones, excluded}`, per key:
   newest of {local binding, remote binding, local tombstone, remote
   tombstone} by timestamp wins (null `updatedAt` = epoch 0; tie → keep local).
   Excluded ids: union, minus any id whose Bangumi binding is newer than the
   exclusion is not tracked (keep it simple: union only).
3. Tests (table-driven): live vs older live; live vs newer live (rebind to a
   different remoteId); tombstone vs older live → deleted; tombstone vs newer
   live → live; both absent; tie; null updatedAt; serialization round trip
   contains no `generation`/token fields.

## Slice 5: wire the tracking file into WebDAV

Files: `lib/services/sync/webdav.dart`,
`lib/services/storage/settings_keys.dart`, `lib/pages/settings/sync/webdav_sync_page.dart`,
`lib/pages/settings/sync/sync_settings_page.dart`.

1. Reuse `webDavEnableCollect` (decision recorded in the workflow doc; change
   only if the owner says otherwise). No new setting.
2. In `WebDav` add `syncTracking()` following `_syncCollectibles` +
   `_publishRemoteFile`: path `/kazumiSync/tracking.json`; download if present,
   `merge`, apply, then upload the merged file. Run it from `syncCollectibles`
   after the collectibles step, inside the same `_runWebDavExclusive`.
3. Apply: for each merged live AniList binding not equal to local, `put` a
   `TrackingBinding` with a NEW `generation` and `lastRemoteProgress=null`;
   for each winning tombstone delete the local binding and write the
   tombstone; write excluded ids to the account settings box key
   `bangumiExcludedSubjectIds`. Enqueue nothing. If AniList is signed out
   locally, still store the binding (it is inert until sign-in).
4. Status text on the WebDAV card (`sync_settings_page.dart:49` area): add
   `追踪匹配` to the list of synced items.
5. Tests in `test/webdav_service_test.dart` style with the existing fake
   client: device A has an AniList binding, device B none → after A upload and
   B sync, B has it with a different `generation`; A unbinds → tombstone →
   B loses it; B rebinds newer → A converges; file bytes contain no token.

## Slice 6: docs and verification

1. Update `docs/design/tracking.md`: Bindings section (Bangumi auto-created at
   import/sync/backfill, AniList synced), and the "outbox not synced" note
   stays. Delete nothing else.
2. Update `docs/handoff-tracking-sync-gaps.md` with a "Resolved by" line.
3. Run `flutter analyze` and the full `flutter test`; paste counts.
4. On the owner's OnePlus Pad (adb `2f11f2ca`; device test only on owner
   request, see handoff): build debug/profile APK per the fork build notes,
   install over the release app only if signatures match, otherwise ask. Check:
   open info page of やがて君になる, button reads `在看 · 1`, sheet shows bgm
   bound. Do not change any status (it writes to the real Bangumi account).

## Execution evidence

Runtime model: `codex/gpt-6-luna` (provider `magpie`); implementation owner is
hc terminal `t4d`; lead is hc terminal `t4b`. No additional peer implementation
was used.

| Slice | Commit | Expected red | Green evidence |
| --- | --- | --- | --- |
| 1 | pending | `mise exec -- flutter test test/tracking/bangumi_import_test.dart` exited 1: compile error, `BangumiImport` had no `ensureBinding` parameter. | Same focused command exited 0: 4 tests passed. |
| 2 | pending | Focused WebDAV backfill test exited 1: expected binding `41:bangumi`, actual binding set was empty. | `mise exec -- flutter test test/webdav_service_test.dart --plain-name 'collect sync backfills Bangumi bindings idempotently without outbox writes'` exited 0: 1 test passed. |
| 3 | pending | `mise exec -- flutter test test/tracking/anilist_binding_test.dart --plain-name 'binding timestamps and tombstones follow local changes'` exited 1: manager clock/tombstone arguments and `TrackingBinding.updatedAt` were absent; the initial test also missed its `models.dart` import, corrected before green. | Codegen exited 0; adapter diff adds only field 12 (typeId remains 9). The affected tracking group exited 0: 20 tests passed; after the final UI assertion additions, the removal regression exited 0: 1 test passed with tombstone, binding deletion, exclusion, empty outbox and zero tracker saves. |

The removal widget regression supplies `onRemoveBinding` to run the same
production manager inside `tester.runAsync`; its Hive completion is awaited by
the test. Without this seam, Hive's async box write yielded from the widget's
FakeAsync zone before the following binding delete could complete. The test
triggers removal through the confirmation UI and asserts tombstone, local
binding deletion, exclusion, empty outbox and zero tracker saves.

Device verification: skipped per explicit task scope; no device or real tracker
account was accessed.

## Explicitly out of scope

- Syncing the outbox, tokens, progress or `lastSyncAt`.
- Deleting from Bangumi/AniList when a show is deleted locally.
- Auto-matching AniList.
- Pushing, PRs or releases (owner decision).
