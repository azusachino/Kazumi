# Tracking UI follow-up after haru.5 device feedback

Owner report: the detail button showed `未追` or `想看 · 2`, contradicting the
tracker drawer; selected episode numbers were not indicated; use the services'
icons and Mihon-style tracking controls. The owner confirmed binding sync works.

## Diagnosis and scope

Observed on the owner's connected OnePlus Pad: the detail page for
`正反対な君と僕` displayed `想看 · 2`; the drawer displayed `在看` and `1 / 12`
for both Bangumi and AniList. The button read the local collection category,
while the drawer read each remote tracker. A local category and binding count
were presented as if they described remote tracking state.

The drawer also ignored desired outbox values while waiting for sync, and the
number wheel had neither a visible selection overlay nor selected-item
semantics. Opening the drawer only reads; no live account state was changed
during inspection. Bangumi's existing mapping tests already cover all five
statuses in both directions; no status-mapping or binding-sync change is made.

## Changes

- Replace the combined category/count button with `追踪` / `已追踪`, using a
  dedicated tracking icon and outlined action on the detail header. No numeric
  binding badge or local watch-status label appears on this action.
- Show each service's remote status; matching-generation queued status,
  progress and score take precedence while awaiting sync, with the existing
  waiting/error indicator. Ignore outbox rows belonging to an older binding.
- Clear invalidated remote snapshots rather than flashing stale state during
  refresh. Display read failures and a `重新读取` action instead of silently
  hiding them; retries do not enqueue a write.
- Highlight the wheel's center selection and selected number, update it during
  scrolling, and expose selected-value semantics for episode/score pickers.
- Use Mihon's Bangumi/AniList VectorDrawable artwork converted to local SVGs,
  with accessible service names. Source revision and Apache 2.0 license are in
  `licenses/mihon/`; the license is included in Flutter's license registry.

Local library management and authenticated writes retain their existing
ownership. Library categories are not overwritten merely by opening the drawer.
This is a focused correction to detail-page tracking actions and the drawer,
not a replacement of the overview/comments/character content.

## Verification

- Expected red: `mise exec -- flutter test test/tracking/tracking_ui_test.dart
  --name 'tracking action does not present|pending tracker status remains|episode
  wheel identifies'` exited 1: all three new symptom regressions failed.
  An earlier invocation mistakenly used `--plain-name` with regex alternation;
  it ran zero tests and is not evidence of a reproduced failure.
- Focused UI plus Bangumi adapter tests: exit 0, 35 passed. Includes remote
  planning vs local watching, pending status display, stale-generation rejection,
  failed-read retry without writes, wheel selection and existing API mappings.
- Plain `mise exec -- flutter analyze`: exit 0, no issues.
- Full `mise exec -- flutter test`: exit 0, 323 passed, including existing
  WebDAV binding/tombstone tests. The known logger fallback noise remains.
- Self-review: lead inspected the connected callers and diff. No agent reviewer
  is claimed for this follow-up; the earlier independent reports describe their
  own recorded revisions only.

That paragraph described a planned `2.4.3-haru.6` check. haru.6 (20405) was
built and installed on the pad before this cache/picker follow-up; its screen
results are superseded by the measured haru.7 and haru.8 device sections below.

## Drawer cache and compact picker (haru.7)

Owner report after haru.6: the drawer lagged while fetching Bangumi and had no
local status cache, and the episode/score picker expanded across the whole
tablet. Diagnosis: the drawer read every tracker on each open and cleared its
in-memory state on every binding/outbox notification, so a slow request left a
blank row; the number dialog used `double.maxFinite`.

### Changes

- Remember each tracker entry on this device in a Hive `Box<String>`
  (`trackingEntryCache`): optional `RemoteEntry` plus `fetchedAt`, keyed by
  account username (never a token), subject/tracker, remote id and binding
  generation. A remembered null entry is distinct from a cache miss; corrupt
  rows read as a miss.
- Fresh for five minutes: a fresh snapshot renders synchronously with no
  network read; a stale one stays visible while the background refresh runs and
  carries a plain `正在刷新追踪状态…` line. `刷新状态` and `重新读取` force a read.
  A future `fetchedAt` counts as stale.
- `TrackingSync` refreshes the snapshot from a successful remote read/write
  before it removes the outbox row, so clearing a pending edit never reverts
  the row to older state. Account scope is captured before the read and
  re-checked after the cache write, together with `mounted`, revision and
  binding generation.
- The cache is excluded from the WebDAV tracking payload: it is display state,
  not account state.
- The number picker is constrained to a Material dialog width (`min(320,
  screen - 120)`), keeping the selected highlight and semantics.

### Verification

- Expected red: `flutter test test/tracking/tracking_entry_cache_test.dart`
  exited 1, `No such file ... tracking_entry_cache.dart`; after the UI/sync
  tests were added, `flutter test test/tracking/tracking_sync_test.dart
  test/tracking/tracking_ui_test.dart` exited 1 with two load failures
  (`Setter/Member not found: GStorage.trackingEntryCache`).
- Focused cache + sync + UI: exit 0, 45 passed across the three test files.
  Covers account/generation isolation, null-entry vs miss, corrupt persisted
  rows, no duplicate read on reopen, stale row visible during a gated refresh,
  opt-out, the compact dialog, and the sync cache refresh before row removal.
- After the review guards and stale line: cache + UI exit 0, 24 passed; plain
  `flutter analyze` exit 0, no issues; full `flutter test` exit 0, 330 passed.
  The haru.8 build reuses these runtime inputs; no test was rerun for the
  docs-only commits.
- Source commits: eec75394 (cache, picker, tests), d065464f (guard, stale
  line, future-clock check).

### Device result (pad, 2f11f2ca)

- `2.4.3-haru.7` built from eec75394 (versionCode 20406), 33.5 MB, APK SHA-256
  `a77f4a1665bb9719344398808d3c3a8740c920eeac53f41796ba892432d44334`,
  signer SHA-256 `7b51900552bbc088391e28fb243914402e5fe258c33f1bed2116409dcb61c4a9`
  (matched the installed certificate before installing). `install -r`:
  Success; `firstInstallTime` stayed 2026-11-10 21:24:19, so app data was kept.
- Drawer for `追放されたチート付与魔術師…` shows both signed-in trackers with
  logos, `想看`, `0 / 12` and `0`, no blank or `读取中…` row after the first
  cold read. The number picker is a compact centered dialog with the selected
  value highlighted. Only 取消/Back were used; no remote status, progress or
  score was changed.
- Limit: haru.7 predates d065464f, so its install did not exercise the
  stale-refresh line or the post-persist guards. haru.8 below does.
- The cache is per device and per account; the first open after install is a
  cold read, and the cache does not sync over WebDAV.

### Device result (pad, 2f11f2ca) - haru.8

- `2.4.3-haru.8` (versionCode 20407) built from docs HEAD 2d6b6ff5, whose
  runtime source is d065464f. Build exit 0 in 44.5 s, 33.5 MB. APK SHA-256
  `5bca48b3a6c763982646d3189d67a338edb68f2a4c65e51f39128a2e3f92a0fe`;
  signer SHA-256
  `7b51900552bbc088391e28fb243914402e5fe258c33f1bed2116409dcb61c4a9`
  (the same certificate as the installed app). `install -r`: Success;
  `firstInstallTime` stayed 2026-11-10 21:24:19, so app data was kept.
- Opening the drawer 0.3 s after tapping `追踪` already shows both trackers
  with `想看`, `0 / 12` and `0` from the persisted snapshot, plus the quiet
  `正在刷新追踪状态…` line under the Bangumi row; three seconds later the line is
  gone after the refresh and the values are unchanged. This exercises the
  stale-refresh line and the post-persist guard path on device.
- The episode picker is again a compact centered dialog with the highlighted
  selected value; only 取消/Back were used and no remote status, progress or
  score was written. Screenshots: `.tmp/kazumi-tracking-sync/deepseek-implementation/haru8-drawer-cached.png`,
  `haru8-drawer-refreshed.png`, `haru8-picker.png` (workstation scratch).
- Phone was subsequently updated at the owner's request: OnePlus PLR110,
  adb `3B66A6009QZ00000`, `adb install -r` exited 0 with `Success` for the
  same haru.8 APK. Package inspection confirmed `2.4.3-haru.8`, code `20407`,
  and preserved `firstInstallTime=2026-11-10 20:21:19`. The signing certificate
  matched the previously verified installed fork. Both devices now have haru.8;
  phone UI acceptance remains with the owner.

## Default status on an explicit add (haru.9)

Owner report: after tapping `添加追踪`, the status cell read `状态` instead of the
expected default `想看`.

Measured cause: `BangumiBindingManager.startTracking` cleared the opt-out and
tombstone and created the binding, but never enqueued a status. Bangumi then had
no collection entry, `readEntry` returned null, and the sheet fell back to its
`状态` placeholder. `AniListBindingManager.bind` already enqueued
`TrackStatus.planning` when the remote entry was absent, so the two services
disagreed.

Fix: `startTracking` remembers whether the binding already existed and, only for
a newly created one, enqueues `TrackStatus.planning` on that tracker. An
already-bound subject keeps its tracker status, and implicit creation (Bangumi
import, WebDAV apply, startup backfill) still enqueues nothing.

Verification:

- New unit test `startTracking seeds 想看 only for a newly created binding`
  covers: one planning write on add; a second add writes nothing; an
  already-bound subject keeps `在看`; implicit `ensureBangumiBindings` creates a
  binding with no outbox row and no tracker write.
- A widget-level duplicate of this assertion was written and dropped: it waited
  on the fake tracker's save from inside the widget-test zone, where the
  enqueue → drain chain parks on Hive awaits, so it hung instead of measuring
  anything. The unit test exercises the same production path deterministically,
  and the existing sheet test already proves a pending planning row renders as
  `想看` rather than the placeholder.
- Plain `mise exec -- flutter analyze` exit 0, no issues. Full
  `mise exec -- flutter test` exit 0, 331 passed.
- Self-review only; no independent reviewer covered this commit.

### Device result (phone, 3B66A6009QZ00000)

`2.4.3-haru.9` (versionCode 20408, APK SHA-256
`6de504463102df3614d5f219b6fa761360e30649baa12107fc3061246dd5684c`) was
installed on the owner's OnePlus PLR110 at the owner's request after the
pad gate: `adb install -r` exited 0 with `Success`, package inspection
confirmed `2.4.3-haru.9` / `20408`, and `firstInstallTime=2026-11-10 20:21:19`
was preserved. The OnePlus Pad (`2f11f2ca`) was then updated with the same
APK: `adb install -r` exited 0 with `Success`, inspection confirmed
`2.4.3-haru.9` / `20408`, and its `firstInstallTime=2026-11-10 21:24:19` was
preserved. Both devices now run haru.9; owner acceptance of the
default-status behaviour is pending on device.

## Drawer status moves the show in the local library (haru.10)

Owner report: a show set to 在看 in the tracking drawer did not appear under
追番 > 在看.

Measured cause: the 追番 list reads the local `collectibles` box filtered by
local `CollectType`. The drawer's status selector only called
`trackingSync.enqueue`, which writes the tracker entry; before the sheet became
tracker-only, the 收藏 chips were what wrote the local category, so removing
them left the two stores unlinked.

Fix: after a drawer status change is enqueued for that one tracker, the sheet
also writes the equivalent local category through a new
`CollectController.addCollectFromTracker` (add/update the collectible plus its
collect change, so WebDAV still carries it). Mapping: planning→想看,
current→在看, completed→看过, paused→搁置, dropped→抛弃. It deliberately does not
call `statusChanged`, because that would also write the other tracker and can
create a binding the owner never asked for. The local write is not awaited by
the dialog: a slow local write must not delay the tracker write that already
succeeded, and a failure is logged rather than surfaced as a tracker failure.

Verification:

- Expected red before the fix: the new unit test failed `Expected: <1>` /
  `Actual: <null>` — no local collectible existed after a drawer status change.
- New unit test covers: local category written with its collect change; no
  outbox rows created by the mirror; a second status change updates the
  category without touching either tracker.
- The tracker-only sheet test asserts the mirror is called with
  在看 then 抛弃 while the outbox still separates the two trackers. It uses the
  `onMirrorStatus` seam (the same pattern as `onRemoveBinding`) because the real
  mirror is Hive I/O, which parks in the widget-test fake-async zone and
  previously deadlocked the static collect-write queue.
- Plain `mise exec -- flutter analyze` exit 0, no issues. Full
  `mise exec -- flutter test` exit 0, 332 passed.
- Self-review only.

### Status consistency follow-up (haru.11)

Plan: `docs/plans/tracking-status-consistency-plan.md`. What changed since the
audit:

- **Fixed: the row was rewritten wholesale.** `setCollectType` / the repository
  path rewrites only `type`; the stored item and its timestamp survive a
  category change.
- **Fixed: a failed mirror was silent.** The drawer keeps the tracker write and
  shows `本地追番状态未更新，追踪状态已保存`.
- **Fixed: a tracker-side edit never reached 追番.** A successful Bangumi drain
  now mirrors its status into the local category when no local edit is queued,
  writing no outbox row. (It writes a `tracker`-origin collect change; see the
  cross-device follow-up below.) AniList never drives the library.
- **Dropped, deliberately:** doing the same from the drawer's own read. A
  library write awaited in that path parks on Hive I/O in the widget-test
  fake-async zone and hangs the suite; the drain owns propagation instead, so a
  web-side edit lands on the next app start or after any local enqueue. The
  drawer row itself always shows the tracker's true status.
- **Dropped, deliberately:** making a drawer change fan out to the other
  tracker. 追番 still writes every bound tracker; the drawer writes the row the
  owner touched. Fanning out would overwrite a status set on purpose.

Still true, unchanged:

- A drained failure leaves the local category ahead of the tracker until the
  outbox retries. That is the existing optimistic local-first model; the drawer
  shows the pending or failed row.
- Nothing new is enqueued on success, and the WebDAV payload is untouched.
- AniList edits never move the library.
- The widget tests exercise seams (`onMirrorStatus`, `onRemoveBinding`), not
  real Hive writes; the controller and the sync layer are covered by plain
  tests.

Gates at this revision: plain `mise exec -- flutter analyze` exit 0, no issues;
full `mise exec -- flutter test` exit 0, 339 passed. Deviations and their
reasons are recorded in the plan. Self-review only.

### Cross-device status follow-up (haru.12)

Plan: `docs/plans/tracking-cross-device-status-plan.md`, which supersedes
`docs/plans/tracking-status-consistency-plan.md` for the cross-store and
cross-device questions. Design is rewritten in `docs/design/tracking.md`
("Watch status across stores and devices").

Coordinated now:

- **Propagation is visible to the merge.** A drained Bangumi status rewrites the
  category and appends a `tracker`-origin collect change in one write block, so
  the next collectibles sync can no longer revert it to the category the other
  device still holds. Nothing is enqueued.
- **Origin is recorded.** `CollectedBangumiChange.origin` (Hive field 5,
  default 0 = user, 1 = tracker) is backward compatible: rows written by an
  older build load as `user`, and the generated adapter gained only that field
  with no typeId change.
- **The merge is last-write-wins per subject with a symmetric tie-break.** The
  log is keyed by `(id, subject)`; per subject the winner is the greatest
  `(timestamp, origin, type)` with owner before tracker echo, then higher
  category. Two devices merging each other's data now pick the same winner
  instead of "keep local", and a same-second id minted for different subjects
  keeps both edits (the incoming one moves to a fresh local id).
- **A received category can reach Bangumi.** After a collectibles merge, a
  user-origin winning change newer than the tracker's own `updated_at`, for a
  subject with a Bangumi binding, no pending row and a differing recorded
  status, enqueues one Bangumi delta. `RemoteEntry.updatedAt` comes from the
  Bangumi collection response and is persisted in `trackingEntryCache`; it is
  never invented.

Still not coordinated, deliberately:

- No push channel: convergence happens at sync and drain points.
- Wall clocks decide; a fast clock wins, and a tie is decided by content.
- A stale local change is dropped rather than written: the tracker's own newer
  edit stands.
- AniList never drives the library and is never a propagation target.
- Deletions stay local-only; no tracker removal is propagated.
- An older build that reads the synced log drops `origin`, so it can re-enqueue
  once until it is updated.
- A drain failure still leaves the local category ahead of the tracker until the
  outbox retries.

Evidence at this revision (`task/tracking-sync`):

- `aac474ab` origin field. Red: the new test could not compile — no `origin` on
  `CollectedBangumiChange`. Adapter regenerated with build_runner; diff adds
  field 5 and the read default only, typeId 5 unchanged.
- `3c038b15` propagation records a change. Red: after a drain-style category
  write the log was empty (`Expected: an object with length of <1>`, `Actual:
  []`), which is exactly why the next merge reverted it.
- `c1d3af53` per-subject LWW. Red, four ways: the remote base won an older
  change; a same-second tie depended on which side merged; a colliding id kept
  one subject instead of two; a newer remote delete left the row in place.
- `bf9b560e` tracker `updated_at` on `RemoteEntry` and in the entry cache. Red:
  no `updatedAt` on `RemoteEntry`, and no such cache field.
- `282d3a6a` guarded enqueue after a collectibles merge. Red: the new test's
  tracker recorded no call — nothing was enqueued for a category that arrived
  over WebDAV.
- Gates: `mise exec -- flutter analyze` exit 0, no issues; `mise exec -- flutter
  test` exit 0, 355 passed (339 before this follow-up). Fakes only: no real
  account, no network write.

Not covered: the live wiring `Storage.init` → `onRemoteStatus` is not exercised
end to end by a test (the callback body is, and the drain's call to it is), and
no device has run this build yet.
