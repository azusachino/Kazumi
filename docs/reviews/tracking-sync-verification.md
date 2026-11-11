# Independent final review — Kazumi tracking sync

Reviewer: t4g, fresh Pi session, runtime `opencode-go/deepseek-v4.1-flash`
(provider `magpie`, reasoning medium). Method: independent verification contract
(`.agents/skills/independent-verification/SKILL.md`), workstation task playbook,
tier 1. Read-only source/index; gates run locally; no delegates, no commits, no
account/device use, no remote writes.

## Reviewed revision (verified first)

| Item | Value |
| --- | --- |
| Checkout | `vendor/kazumi/.worktrees/tracking-sync` |
| Branch | `task/tracking-sync` |
| HEAD | `edb4abf4dedd84ab3955a6c8c740beec1840aaa8` |
| Baseline | `f44f363652e8f65cb5aa41e696e4ca9b315ada4e` (`main`) |
| Commits in range | 8 (`git rev-list --count` = 8) |
| Tree at review start | clean (`git status --porcelain` empty) |
| Tree after gates | clean, no `pubspec.lock` delta (`git diff --stat` empty) |
| Toolchain | Flutter 3.47.9 stable, Dart 3.13.7 (macos_arm64) |

Commits: `14af1716` slice 1, `e095ac48` slice 2, `c2899fdd` slice 3,
`8169de29` slice 4, `c684f4fc` slice 5, `485bd39d` slice 6,
`86f10536` slice 7 (tracker-only UI), `edb4abf4` slice 8 (analyzer repair).

No docs-only shortcut was claimed: the gates below were re-run by me on this
exact revision, so I did not need to judge the equivalence of earlier evidence.

## Gates (measured, my own runs)

| Command (cwd = reviewed worktree) | Result | Exit |
| --- | --- | --- |
| `mise exec -- flutter analyze` | `No issues found! (ran in 1.4s)` | 0 |
| `mise exec -- flutter test` | `+312: All tests passed!` | 0 |
| `git status --porcelain` after both | empty | 0 |
| `git diff --stat` after both | empty (no lockfile churn) | 0 |

Both were run as the only concurrent Flutter process in the checkout. The
documented evidence in `docs/plans/tracking-sync-plan.md:145-176` and
`docs/handoff-tracking-sync-gaps.md:89-118` reports 312 tests / analyze 0 on this
source; my independent runs agree, so the evidence and the source correspond.
The lead separately reran the same two commands at `edb4abf4` with the same
results (analyze exit 0, `+312` exit 0, clean tree), so gate evidence is
corroborated by two independent runs on the held revision.

## Criterion verdicts

Verdicts cover the six plan slices, the tracker-only UI steering, and the
mechanical analyzer repair.

### A1 Slice 1 — bindings ensured for collected shows — **met**

- `BangumiBindingManager.ensureBangumiBindings` loops `_ensureBinding` inside one
  `_queued` call and returns the created count
  (`lib/services/tracking/bangumi_binding.dart:72-78`). `_ensureBinding` still
  skips signed-out and opted-out subjects and returns whether it created a row
  (`:46-68`).
- Import calls the injected `ensureBinding` for every collected entry before the
  `if (!inserted) continue;` gate, so already-local shows are covered
  (`lib/services/tracking/bangumi_import.dart:41` vs `:42`); `count++` and the
  collect-change write keep their old meaning (`:43-52`).
- The production call site passes the manager method
  (`lib/pages/settings/sync/bangumi_sync_page.dart:113`).
- `_ensureBinding` enqueues no outbox row; test
  `test/tracking/bangumi_import_test.dart:119-167` proves 2 bindings, opted-out
  `3` skipped, pre-existing local status `4` preserved, outbox empty.

### A2 Slice 2 — WebDAV apply and startup backfill — **met**

- Backfill runs after `patchCollectibles` and in the no-remote early-return path
  (`lib/services/sync/webdav.dart:222`, `:258`, helper `:389-399`), wrapped in
  try/catch with `KazumiLogger().e`, so a binding error cannot fail collectibles
  sync.
- Startup backfill sits beside `trackingSync.drain()`, skips silently when
  signed out, and is itself guarded
  (`lib/main.dart:116-128`).
- Selection uses `CollectType.fromValue(item.type).isCollected` over
  `GStorage.collectibles`, matching the plan.
- Covered by the backfill tests in `test/webdav_service_test.dart` (run twice →
  no duplicates; opted-out id skipped; outbox empty) and the import test above.

### A3 Slice 3 — `updatedAt` and tombstones — **met**

- `TrackingBinding.updatedAt` is Hive field 12
  (`lib/services/tracking/models.dart:21,48-49`), carried through `synced()`
  (`:65`), and the generated adapter writes byte 13 fields with
  `fields[12] as DateTime?`, so pre-existing rows load as `null`
  (`lib/services/tracking/models.g.dart:31,39,63-64`). Type id remains 9; no
  other adapter churn in the diff.
- `trackingTombstones` is a plain `Box<int>` opened beside `trackingBindings` and
  injected into both managers (`lib/services/storage/storage.dart:41,192,215-226`).
- Writers: `_ensureBinding` (`bangumi_binding.dart:62`), `stopTracking` tombstone
  (`:92-94`), `startTracking` clears it (`:103`), AniList `bind` clears it
  (`anilist_binding.dart:48`), `unbind` writes it before delete (`:53-57`),
  `rebind` = unbind + bind (`:58-64`), offset edit sets `updatedAt`
  (`lib/pages/info/tracking_sheet.dart:149`).
- Tests: `test/tracking/anilist_binding_test.dart:18-79` (bind/unbind/rebind
  timestamps, tombstone key/value, legacy `null` default),
  `test/tracking/bangumi_binding_test.dart`, `tracking_ui_test.dart` still green
  in the full run.

### A4 Slice 4 — pure merge and file model — **met**

- File model exports only AniList bindings and `\d+:anilist` tombstones, with a
  strict schema; tokens, `generation`, `lastRemoteProgress`, `lastSyncAt` and the
  outbox have no field (`lib/modules/tracking/tracking_sync_file.dart:38-52`,
  `:110-142`).
- LWW: newest of local/remote binding/tombstone, `null updatedAt` = 0, tie keeps
  local (`lib/modules/tracking/tracking_sync_merger.dart:17-39`, `:51`).
- Exclusions are a sorted union (`:34-38`), as the plan limits them to.
- Table tests cover local-newer, remote-rebind, tombstone-vs-live both ways,
  both-absent, tie and null-timestamp cases; a round-trip test asserts allowed
  fields and absent secrets (`test/tracking/tracking_sync_merger_test.dart:26-135`).

### A5 Slice 5 — WebDAV wiring — **met**

- `syncCollectibles()` runs collectibles then tracking inside one
  `_runWebDavExclusive` (`lib/services/sync/webdav.dart:201-204`); `_syncTracking`
  never re-enters the queue, so no deadlock (verified by reading
  `AsyncSerialQueue` at `lib/utils/async_serial_queue.dart:7-20`).
- Path `/kazumiSync/tracking.json`, download-if-present → merge → apply → upload
  merged bytes, with the same publish/temp pattern as the other files
  (`webdav.dart:265-295`).
- Apply mints a new generation and null sync state because it constructs
  `TrackingBinding` without `generation`, `lastRemoteProgress` or `lastSyncAt`
  (`:344-361`); tombstones delete bindings (`:366-372`); pulled bindings are
  stored regardless of AniList sign-in (no sign-in branch in apply).
- UI strings updated (`lib/pages/settings/sync/sync_settings_page.dart:69`,
  `webdav_sync_page.dart:99,145`).
- Measured by `test/webdav_service_test.dart:128-230` (token-free upload,
  Bangumi-only rows excluded, generation differs on apply, signed-out retention,
  stale outbox untouched then dropped without remote calls),
  `:231-286` (tombstone blocks resurrection, newer rebind converges) and
  `:287-311` (malformed/failed downloads never upload, local row preserved).

### A6 Slice 6 — docs and verification — **met, with doc gaps (F8)**

- `docs/design/tracking.md:59-73` records automatic Bangumi binding origins,
  AniList sync of bindings/tombstones, signed-out retention, and the exclusion of
  tokens/outbox; the per-device outbox note survives at `:112-114`.
- `docs/handoff-tracking-sync-gaps.md:89-118` has the "Resolved by" section with
  gate evidence and the authorization/scope of slice 8.
- `docs/plans/tracking-sync-plan.md:145-176` carries a per-slice expected-red /
  green table with real hashes for slices 1-7.

### A7 Tracker-only sheet steering — **met**

- The `收藏` heading, the `ChoiceChip` row, `_selectCollectType`,
  `inject<CollectController>`, the collectibles listenable/listener and both now
  unused imports are gone; no compensating local picker was added
  (`lib/pages/info/tracking_sheet.dart`, whole-file search finds neither `收藏`
  nor `ChoiceChip`).
- Per-tracker affordances remain: status dialog, score, progress, offset, remove,
  open, copy (rows built per signed-in tracker, `:269-284`, `:374-430`).
- Library storage/sync untouched: `CollectController.addCollect/deleteCollect`
  and `appendCollectChange` are unchanged, and the replacement test drives the
  owning controller (`test/tracking/tracking_ui_test.dart:469-500`) proving
  collectibles type, Bangumi binding, outbox status and `在看 · 1` badge, plus
  local-only delete leaving binding and outbox intact. A second test proves the
  sheet renders no picker and that each tracker's status writes only its own
  outbox row (`:418-467`).
- Durable record: `docs/handoff-tracking-sync-gaps.md:96-101` states the sheet is
  tracker-only and collection stays in library flows.

### A8 Mechanical analyzer repair — **met**

- Only the 17 baseline findings are addressed, in exactly the 12 affected files
  plus the two docs; category math 8 + 4 + 5 = 17 matches the baseline log.
- Wildcards `(_, _)` / `(_, _, _)`; null-aware elements `?primaryAction`,
  `?action`, `?preferredDisplayRoad`, `'user-agent': ?verifiedUserAgent` (no `!`
  dropped incorrectly, same insertion semantics); `avoid_print` replaced by the
  logger package's own `ConsoleOutput` inside `KazumiLogOutput` and
  `KazumiLogger().d` in the two WebView creation callbacks, with `stderr.writeln`
  for the two fallback paths (`lib/services/logging/logger.dart:99,115,142,249`).
- No recursion: the logger's console path delegates to `ConsoleOutput`, and its
  error fallback uses `stderr` directly.
- No config weakening or suppressions: diff over
  `analysis_options.yaml`, `pubspec.yaml`, `pubspec.lock` is empty; no added
  `// ignore` / `ignore_for_file` anywhere in the range.
- Measured: plain analyze exits 0 with no issues at `edb4abf4`.

## Findings

Severity: P2 = user-visible failure or silent loss with a plausible trigger;
P3 = narrow, cosmetic, documentation, or coverage. Measured items say so; the
rest are inferred from source.

**F1 (P2, inferred) — a local binding and tombstone for the same AniList key
makes every later tracking sync fail.** `bind` writes the binding and then
clears the tombstone (`lib/services/tracking/anilist_binding.dart:38-48`);
`unbind` writes the tombstone and then deletes the binding (`:53-57`). A crash
or process kill between those two writes leaves both rows. `_localTrackingFile`
exports bindings and tombstones independently with no mutual exclusion
(`lib/services/sync/webdav.dart:296-327`), and the merger throws
`ArgumentError('Tracking key has both binding and tombstone')` for that key
(`lib/modules/tracking/tracking_sync_merger.dart:42-48`). The file is built, not
decoded, so the decode-time duplicate guard does not apply; `_syncTracking`
throws every run, no upload happens, and `syncCollectibles()` reports failure
until the user happens to rebind. Repro path is a kill between two Hive writes,
so I did not reproduce it; the code path is unambiguous. Candidate fixes
(reviewer does not implement): filter local tombstones whose key has a live
binding (or compare timestamps) when building the local file, or treat the merge
conflict as "repairable" by preferring the newer local entry.

**F2 (P2, documented plan limit) — Bangumi opt-outs can never be undone across
devices.** `_applyTrackingFile` unions `bangumiExcluded` and calls `stopTracking`
for each id that has a local Bangumi binding
(`lib/services/sync/webdav.dart:329-340`), while `startTracking` only clears the
local list and tombstone (`bangumi_binding.dart:96-104`). The next sync re-adds
the exclusion from the other device and deletes the binding again. This is the
plan's explicit "union only" simplification
(`docs/plans/tracking-sync-plan.md:100-101`), so it is not a defect against the
plan, but `docs/design/tracking.md` does not state it, and the in-app "开始追踪"
action visibly does not stick. Recommend one sentence in the Bindings section.

**F3 (P2, plan limit) — startup backfill never re-runs after a late sign-in.**
`main.dart:118` returns silently when not signed in at launch; nothing re-runs
the backfill on the sign-in callbacks that `trackingSync.retryFailed` already
uses (`lib/services/storage/storage.dart:200,206`). A device that signs in after
launch keeps badge `0` until the next start, which is exactly the symptom this
plan set out to fix. Plan-sanctioned ("skip silently"), but the residual gap is
not written down.

**F4 (P3, inferred) — user edits racing a WebDAV apply; classified by
interleaving.** `_applyTrackingFile` writes `GStorage.trackingBindings` directly
(`webdav.dart:344-361`), and `AniListBindingManager` has no serialization queue
at all, so nothing excludes a manual bind from an in-flight apply
(`anilist_binding.dart:19-48`). The vulnerable window opens at the local snapshot
inside `merge(_localTrackingFile(), remote)` (`webdav.dart:278`) and closes when
the tombstone loop finishes (`:366-372`).

- *Interleaving A (material, bounded): a fresh bind is deleted by a winning
  remote tombstone.* Requires the user to confirm a bind while a sync is running:
  `bind` checks for an existing row, awaits the network `readEntry`, then writes.
  If the apply's tombstone loop lands after that write, the new row is deleted
  and the remote tombstone (older than the bind's `updatedAt`) is stored; the
  next upload propagates the deletion. Impact: one manual AniList match silently
  disappears. It self-heals only if the user rebinds (`bind` clears the
  tombstone), which they will do because the row visibly vanished. Not a blocker
  for this change: the window needs a deliberate bind during an active sync, and
  the result is recoverable in one action. A minimal mitigation, if the writer
  wants it later, is to re-read the local row's `updatedAt` immediately before
  each apply write and skip when the local row is newer than the merged
  candidate.
- *Interleaving B (not material, inherent to the design): a stale upload
  overwrites a newer remote rebind.* Device A downloads, device B rebinds and
  uploads, then A uploads its merged snapshot. Because `updatedAt` travels with
  the binding, B's next sync re-merges its newer row and re-uploads it, so the
  pair converges; only a device that never syncs again keeps the loser. This is
  the same last-writer-wins/inherent-no-etag pattern the collectibles sync
  already uses and is outside this change's blast radius.
- *Interleaving C (not material): startup backfill vs apply.* Both go through
  `BangumiBindingManager._queued` (`bangumi_binding.dart:24-36`), so Bangumi-side
  operations are serialized; only the AniList direct writes above are
  unsynchronized.

**F5 (P3) — a malformed or newer remote tracking file fails the whole
`syncCollectibles()` report.** Decode throws `FormatException` inside
`_syncTracking` (`webdav.dart:273-276`), after collectibles already synced, and
`CollectController` reports the generic "WebDAV 同步失败"
(`lib/pages/collect/collect_controller.dart:102-114`). Data safety is correct
(no upload, local rows preserved — test at `webdav_service_test.dart:287-311`);
only the reporting and the versioning behaviour are coarse: version 1 with an
exact key set means a future file version is rejected rather than ignored.

**F6 (P3) — a binding error aborts an in-progress import.**
`bangumi_import.dart:41` awaits the injected callback unguarded, so a Hive
failure surfaces as an import failure after some entries were already written;
`count` is not returned and the UI shows the failure instead of a partial
import. Only a local box write can fail here, so risk is low.

**F7 (P3, plan limit) — tombstones are never pruned.** Encoded tombstones and
local `trackingTombstones` rows grow without bound
(`webdav.dart:296-327`, `tracking_sync_file.dart:31-36`). Harmless at current
scale; worth a line in the design doc.

**F8 (P3) — documentation gaps, one already assigned.** (a) The plan's slice-8
row says "full hash in closeout" (`docs/plans/tracking-sync-plan.md:160`) and no
hash appears in the docs (`rg edb4abf4 docs/` is empty); the lead has assigned a
docs-only closeout to persist the slice-8 hash and this review's result, so this
item is tracked, not a defect in the reviewed source. (b) F2, F3, F7 and the F1
crash-window recovery are not stated in `docs/design/tracking.md`; one line each
for the writer, not criterion failures.

**F9 (P3) — coverage seams.** The removal regression injects
`onRemoveBinding` (`lib/pages/info/tracking_sheet.dart:22-24,119-126`), so the
widget test exercises the real manager only through the test callback
(`test/tracking/tracking_ui_test.dart:295-345`); the production branch at
`:123-125` is covered only indirectly by the manager tests. The replacement
collect test also drops the old `未追 · 1` badge assertion after
`deleteCollect` (`tracking_ui_test.dart:469-500` compares with the removed test),
so badge-after-uncollect is no longer asserted.

## Privacy and safety checks

- Tracking file payload: read `toJson`/`encode` and the test assertions — no
  token, no `generation`, no `lastRemoteProgress`, no `lastSyncAt`, no outbox
  fields; the test asserts the actual fake token strings
  (`fake-bangumi-token`, `fake-anilist-token`) are absent from the uploaded
  bytes (`test/webdav_service_test.dart:178-182`).
- Only Bangumi subject ids are shared beyond the AniList binding snapshot
  (title/cover/total/offset/lock/score); no account identifiers.
- Tests use fake trackers and an in-memory WebDAV client; no live host, account
  or device was contacted by the change or by this review. No `dart:io` was
  introduced into web-targeted code; `logger.dart` already imported it.

## Limits of this review

- Structural and unit/integration verification only: no device, no real
  Bangumi/AniList account, no second physical device, no Android/web build, and
  no manual UI walkthrough. Browser/native acceptance remains project-owned and
  the plan's device step was explicitly skipped.
- Concurrency findings (F1, F4, F5) are inferred from source, not stress-tested;
  F1 additionally requires a crash window.
- WebDAV behaviour is verified against the repository's in-memory fake client,
  not a real server (no etag/rename/partial-write semantics).
- Test-count evidence is the whole-suite run; I did not audit every pre-existing
  test for weakening outside the tracking changes.
- `hc --skill` was used to confirm the CLI surface; gates were run through
  `hc run --bg` terminals `t4g-analyze` and `t4g-test`, both task-created.

## Verdict

All eight acceptance areas are **met** at
`edb4abf4dedd84ab3955a6c8c740beec1840aaa8`: plain `flutter analyze` exits 0 with
no issues, and the full `flutter test` suite reports 312 passing, reproduced by
me on a clean tree and independently by the lead. The review found no defect
against the plan's own criteria and no new feature was introduced.

Findings are bounded to: F1, a crash-window state (local binding plus tombstone
for one AniList key) that can wedge tracking sync — the only finding I would put
on the follow-up list; F2 and F3, plan-sanctioned limitations whose user-visible
consequences are not yet written down; F4, a narrow recoverable user-edit race;
and F5-F9 documentation and coverage notes. None of these blocks the delivered
work; F8(a) is already assigned to the lead's docs-only closeout.

## Lead disposition after the reviewed revision

The report above is preserved as received and applies only to the reviewed
revision `edb4abf4dedd84ab3955a6c8c740beec1840aaa8`. The following are
subsequent dispositions. DeepSeek's completed focused recheck of
`973aa8330476fdec4b15eefb85dc7888665d86a0` is preserved in
[`tracking-sync-recheck.md`](tracking-sync-recheck.md).

- **F1 fixed in the ninth local commit:** same-device binding/tombstone pairs
  now resolve to their newer timestamp, with tombstone winning an equal-time
  same-side pair. Cross-device equal timestamps still keep local as the plan
  specifies. The new fake WebDAV regression seeds the actual Hive boxes with
  both rows, checks successful normalized upload and decoded output, then
  verifies a second sync is idempotent.
- **R7 retained:** remote JSON decoding still rejects duplicate candidates for
  one key. Local snapshot recovery handles interrupted Hive writes; ambiguous
  remote input remains a strict format error and is not uploaded.
- **F2, F3 and F7 documented** in `docs/design/tracking.md` as current sync
  limits: exclusion union can undo `startTracking`, signed-out startup
  backfill waits for a later start or collection/watch event, and deletion
  tombstones are retained without pruning.
- **F4 remains a follow-up risk:** a simultaneous manual AniList edit and
  in-flight WebDAV apply is still an inferred race; no concurrency changes were
  made in this bounded fix.
- **F5 and F6 unchanged:** malformed/failed remote downloads still fail safely
  without upload or local-row replacement; an import binding write failure
  still surfaces as an import failure. Their existing behavior and tests are
  retained.
- **F8 resolved:** this durable review artifact records the exact full hash
  `edb4abf4dedd84ab3955a6c8c740beec1840aaa8` that DeepSeek reviewed and the
  scope of its verdict.
- **F9 restored:** the collection widget regression now asserts `未追 · 1`
  immediately after the owning `CollectController.deleteCollect` call and again
  after closing the sheet. It uses the existing direct-controller test seam
  because the tracker sheet intentionally no longer owns local collection
  controls; the UI test still proves the real collection → binding/outbox →
  badge path and the local-only delete behavior.

The focused DeepSeek recheck passed at
`973aa8330476fdec4b15eefb85dc7888665d86a0`: R1–R8 met, plain analyzer exit 0,
and 39 focused tests passed (exit 0). The lead independently reran the full
suite on that exact source: 318 passed, exit 0, with the tree clean afterward.
No P1/P2 finding remains in the recovery delta. O1 is a nonblocking mirror-case
integration coverage note, O2 is a compiler cache notice with repeated passing
checks, and O3 is resolved by the exact revision and full-suite evidence here.
The original report's documented plan limits and inferred simultaneous-edit
race remain as scoped above. No account, device or remote service was used.

Coordination closeout: Pi Codex/Luna (`magpie/codex/gpt-6-luna`, high) in
Herdr `t4d` implemented the slices and recovery fix with exclusive checkout
ownership. Pi DeepSeek (`magpie/opencode-go/deepseek-v4.1-flash`, medium) in
Herdr `t4g` independently reviewed the full range and then the recovery delta.
The lead inspected committed diffs, reconciled findings and reran the required
gates. Both task-created peer roles are complete, their child test terminals
have been removed, and the peers are closed at task closeout. The worktree and
local branch remain for owner review. No remote publication or device check
was authorized; those steps were skipped.
