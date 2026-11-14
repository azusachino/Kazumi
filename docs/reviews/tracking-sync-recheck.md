# Focused recheck — F1 fix delta on Kazumi tracking sync

Reviewer: t4g (same read-only independent role). Scope: **only**
`edb4abf4dedd84ab3955a6c8c740beec1840aaa8..973aa8330476fdec4b15eefb85dc7888665d86a0`.
The earlier full-range audit is not repeated; this note adds the delta result to
`final-review.md`.

## Revision verified first

| Item | Value |
| --- | --- |
| Checkout | `vendor/kazumi/.worktrees/tracking-sync` (same absolute worktree) |
| Branch | `task/tracking-sync` |
| HEAD | `973aa8330476fdec4b15eefb85dc7888665d86a0` |
| Delta commits | 1 (`973aa833 fix(tracking): recover interrupted binding deletion`) |
| Delta files | 8 (merger, 3 test files, 3 docs, 1 new review doc) |
| Tree | clean before and after my runs; no `pubspec.lock` delta |
| Toolchain | Flutter 3.47.9 / Dart 3.13.7 |

Delta stat: `lib/modules/tracking/tracking_sync_merger.dart` +15/-1,
`test/tracking/tracking_sync_merger_test.dart` +74,
`test/webdav_service_test.dart` +42, `test/tracking/tracking_ui_test.dart` +1,
`docs/design/tracking.md` +16, `docs/handoff-tracking-sync-gaps.md` +27,
`docs/plans/tracking-sync-plan.md` +10/-2, new
`docs/reviews/tracking-sync-verification.md` +374. No dependency, analyzer
configuration, generated-adapter or unrelated source change.

## Gates (measured, my own runs, at `973aa833`)

| Command (cwd = worktree) | Result | Exit |
| --- | --- | --- |
| `mise exec -- flutter analyze` | `No issues found! (ran in 1.4s)` | 0 |
| `mise exec -- flutter test test/tracking/tracking_sync_merger_test.dart test/webdav_service_test.dart test/tracking/tracking_ui_test.dart` (run twice) | `+39: All tests passed!` both runs | 0 |
| `git status --porcelain` after runs | empty | — |
| `git diff --stat` after runs | empty | — |

The 39 decomposes as merger 13, `webdav_service_test` 13, `tracking_ui_test` 13,
matching the writer's claim. Both focused runs printed
`File modified during build. Build must be rerun.` once; that is the
incremental-compiler mtime/kernel-cache notice (the delta files carry
commit-time mtimes newer than the cached kernel), not a source change during my
run: the tree was clean at the same hash before and after, and all 39 tests
executed and passed identically twice (O2).

Evidence reuse: I did not reuse the writer's full-suite `318` figure as
independent evidence, because the durable record says "the ninth-slice source"
without naming `973aa833` yet (plan row 9 says "hash in closeout"). The full
range up to `edb4abf4` was verified by me at 312; the delta touches only the
merger and tests, and my focused run covers every changed path. Recorded as O3.

## F1 recheck matrix

| Item | Result | Evidence |
| --- | --- | --- |
| R1 same-side both, binding newer → live wins | met | `tracking_sync_merger.dart:46-60`; test `tracking_sync_merger_test.dart:107-119` asserts live remoteId, empty tombstones, single candidate |
| R2 same-side both, tombstone newer → deleted | met | same branch; test `:121-133` asserts empty bindings, `deletedAt 20` |
| R3 same-side equal → tombstone wins | met | `>=` comparison at `:53` with the crash-recovery comment `:50-52`; test `:135-147` |
| R4 cross-side tie still keeps local | met | `merge()` tie rule unchanged (`tracking_sync_merger.dart:22-24`); the 7-case table including `equal timestamps keep local` runs green in the 13 |
| R5 output never carries both; encoded bytes still decode | met | `expectSingleCandidate` (`tracking_sync_merger_test.dart:27-31`) asserts one candidate **and** round-trips `decode(encode())` |
| R6 real crash residue converges in one sync, idempotent | met | `webdav_service_test.dart:288-324` seeds the real Hive boxes with both rows, asserts upload decodes to a single live binding, local tombstone cleared, local binding kept, and a second sync is byte-identical; apply order makes this sound (`webdav.dart:344-361` binding loop clears a same-key tombstone, `:366-372` tombstone loop deletes the binding) |
| R7 strict remote decode retained, documented | met | `tracking_sync_file.dart` duplicate guard untouched; new test `tracking_sync_merger_test.dart:163-175` asserts `throwsFormatException`; documented at `docs/design/tracking.md` Sync limits |
| R8 badge after uncollect restored | met | `tracking_ui_test.dart:501` after `deleteCollect` and `:505` after closing the sheet |
| F9 seam unchanged | accepted | the direct-controller seam stays justified (tracker sheet no longer owns collection controls); durable note at `docs/reviews/tracking-sync-verification.md:365-370` |

Semantics I checked beyond the tests: for a same-side pair the candidate's
timestamp is the winner's own timestamp, so the local-vs-remote comparison stays
LWW-correct (a remote live row newer than a locally winning tombstone still
resurrects the binding, and vice versa). `decode` uniqueness plus unique box keys
mean `binding.first` / `tombstone.first` cannot mask duplicates. A legacy
`null updatedAt` binding paired with any tombstone resolves to the tombstone
(epoch 0), which is the conservative reading the plan already specifies.

## Documentation truthfulness

- `docs/design/tracking.md` (new "Sync limits") states the F2 union-only
  re-tracking consequence, F3 no-rerun backfill, F7 unpruned tombstones, the F1
  same-device recovery plus strict remote reject, and F4 as an inferred narrow
  follow-up with no concurrency change. All five match the code and this review.
- `docs/handoff-tracking-sync-gaps.md` post-review section scopes the verbatim
  review to `edb4abf4`, records the fix, the strict-reject decision and the
  ninth-slice gate results; the "hold the source for DeepSeek's focused recheck"
  sentence is now superseded by this note (lead to update).
- `docs/reviews/tracking-sync-verification.md` reproduces my report verbatim with
  an accurately scoped lead disposition; the F9 sentence matches both restored
  assertions, and F8 is correctly closed by naming `edb4abf4`.
- `docs/plans/tracking-sync-plan.md` row 9 records expected-red on
  `ArgumentError`, the 13/1/1/39 focused results, analyze 0 and full 318, and
  still says "hash in closeout" — the only doc item left for the closeout (O3).

## Findings (delta)

**O1 (P3, coverage) — the deleted-wins direction of the crash window is covered
only by the merger unit test.** `webdav_service_test.dart:288-324` seeds
binding-newer-than-tombstone (live survives). The mirror seed
(tombstone newer, binding must disappear and the tombstone must survive a second
sync) is proven only at merger level (`tracking_sync_merger_test.dart:121-133`),
not through the real Hive/WebDAV path. The apply code is symmetric and was
inspected (`webdav.dart:344-372`), so this is a coverage note, not a defect.

**O2 (P3, environment) — `File modified during build. Build must be rerun.`**
appears once per focused run. Benign mtime-versus-kernel-cache notice; the tree
was clean at `973aa833` before and after, and the same 39 tests passed twice.
Recorded so a future recheck does not read it as concurrent source edits.

**O3 (P3, record) — the 318 full-suite figure is not yet tied to
`973aa833` in a durable record.** Plan row 9 and the handoff say "ninth-slice
source"/"hash in closeout". Once the closeout names the hash, the full-suite
evidence becomes reusable without a rerun; until then it is lead-corroborated,
not independently reproducible from the docs.

No P1/P2 finding in the delta. F1 is closed as delivered; F2/F3/F7 remain the
documented plan limits; F4 stays an inferred, explicitly out-of-scope follow-up;
F5/F6 unchanged and accepted.

## Limits of this recheck

- Delta-only: I did not re-audit the unchanged original range, per assignment.
- Focused suites plus plain analyze only; I did not run the full 318-test suite.
- No device, real account, remote WebDAV server or second physical device; the
  crash-window integration uses the repository's fake client and real Hive boxes.
- Concurrency behaviour (F4) remains inferred; no stress or lock test was run.

## Result

The F1 fix is **met** and the delta is internally consistent with the reviewed
baseline: R1-R8 as tabulated, F9 restored, docs truthful with the three P3 notes
above and one pending closeout hash. Source held stable at
`973aa8330476fdec4b15eefb85dc7888665d86a0`; my runs made no tracked change.
