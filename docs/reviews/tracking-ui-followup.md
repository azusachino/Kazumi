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

Physical verification will use a new local `2.4.3-haru.6` build on the pad,
without confirming changes to tracker status, progress or score. Screenshots
are temporary workstation scratch; results will be recorded here after install.

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
- Focused cache + sync + UI: exit 0, 45 passed (cache 3, sync 20, UI 21).
  Covers account/generation isolation, null-entry vs miss, corrupt persisted
  rows, no duplicate read on reopen, stale row visible during a gated refresh,
  opt-out, the compact dialog, and the sync cache refresh before row removal.
- After the review guards and stale line: cache + UI exit 0, 24 passed; plain
  `flutter analyze` exit 0, no issues; full `flutter test` exit 0, 330 passed.
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
- Limit: the installed haru.7 predates d065464f, so the stale-refresh line and
  the post-persist guards are covered by tests, not by this install. The next
  installed build should be `2.4.3-haru.8` (20407). The phone remains haru.5.
- The cache is per device and per account; the first open after install is a
  cold read, and the cache does not sync over WebDAV.
