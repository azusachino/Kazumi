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

Resolved by [`tracking-sync-plan.md`](plans/tracking-sync-plan.md), slices 1–7:
collected Bangumi bindings are ensured during import, WebDAV sync and startup
backfill; AniList bindings, tombstones and Bangumi opt-outs merge through
`/kazumiSync/tracking.json`. The outbox remains per-device. The tracking sheet
now contains tracker-specific controls only; local collection remains managed
through collection/library flows. Verification uses fake trackers and a fake
WebDAV client; no live account or device was used.

Slice-6 gate evidence: `mise exec -- flutter test` exited 0 with 311 tests
passing. Plain `mise exec -- flutter analyze` exited 1 with 17 info findings.
The exact transcript is temporarily saved at
`/Users/azusachino/Projects/project-github/harus-workstation/.tmp/kazumi-tracking-sync/luna/flutter-analyze-slice6.log`.
Findings were `unnecessary_underscores` at
`lib/pages/info/info_comments_view.dart:103:43,141:38`,
`lib/pages/player/danmaku_source_sheet.dart:57:39,477:35`,
`lib/pages/timeline/timeline_page.dart:69:37`,
`lib/utils/async_single_flight.dart:17:38`, and
`test/plugin_import_parser_test.dart:212:28,212:32`;
`use_null_aware_elements` at
`lib/pages/player/syncplay_sheet.dart:144:19`,
`lib/pages/search/image_search_page.dart:384:9`,
`lib/pages/video/video_controller.dart:248:7`, and
`lib/services/plugin/rule_engine.dart:317:7`; `avoid_print` at
`lib/services/logging/logger.dart:116:7,143:9,250:5`,
`lib/webview/video/impl/video_webview_android_impl.dart:35:11`, and
`lib/webview/video/impl/video_webview_impl.dart:33:11`.

The lead authorized a separate eighth local commit to repair these
mechanical findings without weakening analysis configuration. The affected
suite (`test/async_single_flight_test.dart`, `test/api_rule_engine_test.dart`,
`test/rule_engine_test.dart`, and `test/plugin_import_parser_test.dart`) exited
0 with 44 tests passing. Final plain `mise exec -- flutter analyze` exited 0
with `No issues found!`; full `mise exec -- flutter test` exited 0 with 312
tests passing. The tracker UI file separately passed all 13 tests.

A focused test command was once started from the shared checkout by mistake.
Flutter changed only `pubspec.lock`'s `uuid` dependency marker there; that exact
hunk was restored. The shared checkout has no tracked diff from this incident;
the untracked `.worktrees/` directory was left untouched. The authorized
worktree contains the implementation commits. No device or real tracker
account was used. The suite still prints logger file-write fallback messages
in history tests where Flutter's `ServicesBinding` is not initialized; these
tests pass.

## Post-review fix (against edb4abf4)

The independent review is preserved verbatim, followed by the lead's
post-review disposition, in
[`docs/reviews/tracking-sync-verification.md`](reviews/tracking-sync-verification.md).
Its initial verdict applies to `edb4abf4dedd84ab3955a6c8c740beec1840aaa8`.
The completed focused recheck below covers the subsequent recovery fix.

F1 is fixed in the ninth local slice: the pure merger resolves a same-side
binding/tombstone pair by timestamp, preferring the tombstone on an equal-time
same-side tie. Equal timestamps across local and remote still keep local.
Remote JSON decoding remains strict and rejects duplicate keys. New tests first
failed with `ArgumentError` on both the pure merger and real local Hive/WebDAV
path. Green evidence: `tracking_sync_merger_test.dart` exited 0 with 13 tests;
the fake WebDAV local-box normalization/idempotence test exited 0 with 1 test;
the badge-after-uncollect test exited 0 with 1 test. The combined merger,
WebDAV and tracking UI run exited 0 with 39 tests. The collection controller
integration stays on the direct controller test seam because local collection
controls no longer belong to the tracker sheet.

F2/F3/F7 limits, strict malformed-remote handling, and the inferred F4
simultaneous-edit race are documented in `docs/design/tracking.md`. On the
ninth-slice source, `973aa8330476fdec4b15eefb85dc7888665d86a0` on
`task/tracking-sync`, plain `mise exec -- flutter analyze` exited 0 with no
issues; full `mise exec -- flutter test` exited 0 with 318 tests passed.
DeepSeek independently rechecked that exact revision: all eight recovery
criteria met, plain analysis exit 0, and all 39 focused merger/WebDAV/UI tests
passed (exit 0). The lead also reran the full suite at that revision: 318
passed, exit 0, with a clean tree afterward. The recheck is preserved in
[`tracking-sync-recheck.md`](reviews/tracking-sync-recheck.md).

Execution is complete locally. The following closeout commit changes only
Markdown records; runtime source, tests, dependencies and generated inputs
remain identical to the reviewed revision, so the recorded gate results apply
to those unchanged inputs. No push, PR, release, installation, account write or
device verification was performed. The branch/worktree is retained for owner
review; no work remains uncommitted. The next owner action is to review the
local branch and decide separately whether to request device verification or
remote publication. Known limits are in `docs/design/tracking.md`; the inferred
simultaneous manual-edit/WebDAV race remains follow-up work.
