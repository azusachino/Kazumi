# Plan: keep fork logic in fork-only files and gate it behind one flag source

Goal: make the next upstream merge cheap. Today the fork's tracking work edits 28
files that upstream also owns, and some of those edits are large
(`webdav.dart` +200, `storage.dart` +110, `collect_sync_merger.dart` +76/−47).
Every one of them is a future conflict, and a clean merge can still be wrong.

Two moves:

1. **Fork logic lives in fork-only files.** A shared upstream file keeps at most a
   few delegation lines: a call, a one-line override, or an interface it
   implements.
2. **One flag source controls the fork's behaviour**, so a feature can be turned
   off on a device without reverting code, and a bad merge shows up as a flag
   default rather than a silent behaviour change.

Behaviour must not change in this refactor: the suite must pass with the same
count, and the only other acceptance signal is that the shared-file diffs shrink.

## Baseline to beat (measured 2026-11-12, `origin/main...HEAD`)

| Shared file | Now | Target after |
| --- | --- | --- |
| `lib/services/sync/webdav.dart` | +200 −3 | ≤ +30 (implements clause, one call) |
| `lib/modules/collect/collect_sync_merger.dart` | +76 −47 | ≤ +15 (one delegation) |
| `lib/services/storage/storage.dart` | +110 −14 | ≤ +25 (fields, one wiring call) |
| `lib/modules/collect/collect_type_mapper.dart` | +31 −0 | 0 (moved out) |
| `lib/pages/collect/collect_controller.dart` | +21 −0 | ≤ +5 |
| `lib/repositories/collect_crud_repository.dart` | +21 −0 | ≤ +5 |
| `lib/main.dart` | +16 −0 | ≤ +4 |
| `lib/bean/widget/collect_button.dart` | +21 −48 | ≤ +10 (thin shim) |

The 12 one-line analyzer-cleanup files and `logger.dart` stay as they are: they
are small, and reverting them would put the analyzer back to failing.

## Slices

No behaviour change anywhere. One commit per slice; the full suite must stay at
its current count after each one (355 at `d1edafc8`, plus whatever slice 8 adds).

### Slice 1: extract the WebDAV tracking exchange

New files: `lib/services/sync/tracking_webdav_exchange.dart` (fork-only).

- Define a small transport the exchange needs: list a directory, download a file,
  publish a file, and a scratch directory. `WebDav` implements it with
  one-line methods over what it already does.
- Move into the new file: `_syncTracking`, `_localTrackingFile`,
  `_applyTrackingFile`, `_sameSyncedBinding`, `_enqueueReceivedStatuses`,
  `_ensureCollectedBangumiBindings` and the `/kazumiSync/tracking.json` path
  constant.
- `webdav.dart` keeps: the `implements` clause, the transport methods, and one
  call from `_syncCollectibles` where the group of calls is today.
- Tests: the existing `webdav_service_test.dart` must pass unchanged. If a test
  reaches a now-private member, expose it on the exchange rather than reaching
  back into `WebDav`.

### Slice 2: extract the collect merge decision

New file: `lib/modules/collect/collect_change_merge.dart` (fork-only).

- Move the fork's merge semantics there as a pure function:
  `mergeCollectChanges({localCollectibles, localChanges, remoteCollectibles,
  remoteChanges})`, including the `(id, subject)` identity, the
  `(timestamp, origin, type)` winner and `winnerFor(subjectId, changes)`.
- `CollectSyncMerger.mergeWebDav` becomes a delegation returning that result, so
  upstream can rewrite the surrounding class and the function survives verbatim.

### Slice 3: extract the storage helpers

New file: `lib/services/tracking/tracking_storage.dart` (fork-only).

- Move `setCollectTypeIfPresent` and `followTrackerStatus` out of `GStorage` into
  free functions over the boxes, or extensions if that reads better without
  widening visibility.
- `storage.dart` keeps: the box fields, the `trackingEntryCache` wiring, and the
  `onRemoteStatus` line, each of which is unavoidable because the boxes are
  opened there.

### Slice 4: the small shared files

- `collect_type_mapper.dart`: move the fork's `TrackStatus`↔`CollectType`
  extension to a fork-only file; leave the upstream file untouched.
- `collect_controller.dart` / `collect_crud_repository.dart`: replace the added
  methods with calls into fork-only functions, keeping the upstream files at the
  interface/one-method level.
- `main.dart`: replace the inline startup block with one `await
  KazumiTrackingStartup.run()` call in a fork-only file.
- `collect_button.dart`: keep the upstream widget's name and constructor as a
  thin shim whose body delegates to a fork-only `TrackingEntryButton`.

### Slice 5: one flag source

New file: `lib/services/tracking/tracking_features.dart` (fork-only).

- A single settings-backed map under one key. Do not add constants to
  `settings_keys.dart`, which upstream edits often; keep the key literal here.
- Flags, all defaulting to `true` (absent key = enabled), each guarding one
  seam:
  - `bindingsOnSync` — binding creation after import, WebDAV apply and startup
    backfill;
  - `statusMirror` — the drawer's status change writing the local category;
  - `remoteStatusFollow` — the drain writing a Bangumi status into the library;
  - `writeBackOnSync` — a received category enqueuing a Bangumi delta.
- Reading the flags must be one synchronous call at the seam, not a subscription.
- Tests: each flag off suppresses exactly its behaviour and nothing else; all
  flags on reproduces today's behaviour, which the existing tests already pin.

### Slice 6: record the layout rule

- `docs/design/tracking.md`: a short "Where fork code lives" section — fork logic
  in fork-only files, a shared file gets at most a delegation line, and the flag
  names with their defaults.
- Note in the PR body: the shared-file diff table above, before and after.

## Verification

- `mise exec -- flutter analyze` exit 0.
- Full `mise exec -- flutter test` green, with the same count as before the
  refactor plus the new flag tests.
- Re-measure the table in this plan and record the actual numbers. A slice that
  does not reduce its target file is not done.
- No behaviour change: the existing tests are the specification and must not be
  edited except where a private member moved.

## Out of scope

- Changing any user-visible behaviour, default, or status semantics.
- Adding settings UI for the flags (they are read from the existing settings box
  until someone needs a switch).
- Touching the 12 analyzer-cleanup files or `logger.dart`.

## Risks

- Moving code can silently change evaluation order; keep the call sequence inside
  `_syncCollectibles` identical.
- An interface added for the transport is a new abstraction in a hot file; keep it
  to the four operations the exchange actually uses.
- Flags multiply test combinations; four flags with one off-test each is the
  limit, and each off-test asserts only its own seam.
