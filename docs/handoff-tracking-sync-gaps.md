# Handoff: tracking bindings vs. Bangumi import and WebDAV

Investigated 2026-11-11 at `86254f41` (main). Read-only; no code changed.

## Symptoms

1. After "从 Bangumi 导入", 在看 lists the shows, but the front page (collect
   button) shows no tracking match.
2. Question: does WebDAV sync the tracking matchings (bindings)?

## Findings (measured by reading code)

### A. Import creates collectibles but never bindings (cause of the symptom)

- `lib/services/tracking/bangumi_import.dart` `run()` only calls
  `repository.addCollectibleIfMissing(...)` and records a collect change.
  It never calls `BangumiBindingManager.ensureBangumiBinding`.
- `lib/bean/widget/collect_button.dart` derives its label/badge from
  `GStorage.trackingBindings` (count of bindings per `subjectId`), so imported
  shows have count 0 and no badge.
- `docs/design/tracking.md` says the Bangumi binding "is created automatically
  with `remoteId = subjectId`", but in code it is created only lazily by
  `statusChanged` / `watched` in `bangumi_binding.dart` (a later local status
  change or watched episode).
- Also: `if (!inserted) continue;` skips shows already in the local
  collection, so those never get a binding from import either.
- Also: `bangumiExcludedSubjectIds` (opt-out set by `stopTracking`) must be
  respected when creating bindings in import (`_ensureBinding` already does).

### B. WebDAV does not sync tracking data

- `lib/services/sync/webdav.dart` syncs: `collectibles`, `collectchanges`,
  history, danmaku shield. Nothing for `trackingBindings` (Hive box, typeId 9),
  `trackingOutbox` (typeId 10, per device by design, tracking.md:108), or
  `bangumiExcludedSubjectIds` (stored in the account settings box).
- Result: a second device receives collection status via WebDAV but has no
  bindings, so the same missing-badge state appears there. AniList bindings
  are manual and never travel, so they must be re-picked per device.
- tracking.md:30 and :157 intend "bindings in backups without tokens"; that is
  not implemented.

## Suggested fix (for the implementing agent)

1. Import: after a successful or already-present entry, call
   `ensureBangumiBinding(item)` for every imported/existing collected item
   (skip when opted out). Add a unit test with a fake store: import N items,
   assert N bindings; excluded id gets none; existing local item gets one.
2. Optional one-time backfill: on sign-in/startup, ensure Bangumi bindings for
   all collectibles (cheap, same code path).
3. WebDAV: add a `tracking` file (bindings + exclusions, no tokens, no outbox)
   with a merge keyed on `TrackingBinding.key`. Decide a conflict rule
   (last `lastSyncAt` wins? deletes need tombstones, otherwise a removed
   binding is resurrected by the other device). Keep the AniList `remoteId`
   and `episodeOffset`; regenerate `generation` on apply.
   Follow the pattern of `_syncCollectibles` / `collect_sync_merger.dart`.
4. Verify on the owner's device (OnePlus 8, adb 0cadf428): import, check
   badge on the front page; sync WebDAV to a second install, check badge.

## Not checked

- Did not run the app or tests; the front page claim is from reading
  `collect_button.dart`, not from a screenshot.
- Did not check whether other front-page widgets (popular/my) read other state.

## Verification (2026-11-11)

Unit repro (throwaway test, deleted): two 在看 entries imported through
`BangumiImport` give `collectibles=2 imported=2 bindings=0`; the importer has
no binding code (`grep ensureBangumiBinding|bindings bangumi_import.dart`
finds nothing).

On-device (OnePlus Pad OPD2404, adb 2f11f2ca, release build
`2.4.3-haru.4`, read-only taps, screenshots in workstation `.tmp/kazumi-pad/`):

- 追番 > 在看 lists 26 shows, imported earlier.
- Info page of やがて君になる: the collect button reads `在看` with no
  `· N` suffix, so the binding count is 0.
- Its tracking sheet: 收藏 = 在看 (checked), 追踪 rows `bgm` and `AL` both
  show `添加追踪` (no binding on either tracker).
- Settings > 同步设置 > 追踪账号: Bangumi signed in (mikufan2039) and
  AniList signed in, so the "not signed in" skip path in `_ensureBinding` is
  ruled out; missing bindings come from import never creating them.
- WebDAV card lists what it syncs: `观看记录 · 收藏 · 弹幕屏蔽词`; tracking
  bindings are not among them.

Not tested: a second device receiving WebDAV data; whether changing a status
on the pad creates the binding (expected per `statusChanged`).

## Resolution

Resolved by [`tracking-sync-plan.md`](plans/tracking-sync-plan.md), slices 1–6:
collected Bangumi bindings are ensured during import, WebDAV sync and startup
backfill; AniList bindings, tombstones and Bangumi opt-outs merge through
`/kazumiSync/tracking.json`. The outbox remains per-device. Verification uses
fake trackers and a fake WebDAV client; no live account or device was used.
Pre-slice-7 gates: `mise exec -- flutter test` exited 0 with 311 tests
passing. `mise exec -- flutter analyze` exited 1 with 17 info-level findings,
all in untouched files; the modified files had no findings after removing the
one redundant import. These results will be rerun after the tracker-only sheet
follow-up. Final commit IDs and gate evidence will be recorded after that run.
