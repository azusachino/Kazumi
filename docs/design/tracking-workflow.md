# Watch status, tracking and sync: workflow

Status: proposal for the implementing agents, 2026-11-11 (at `24e1813d`).
Evidence for the gaps is in `docs/handoff-tracking-sync-gaps.md`.

## Four stores, four owners

| Store | What it holds | Synced by |
| --- | --- | --- |
| `collectibles` + `collectchanges` | Local watch status per Bangumi subject (想看/在看/看过/搁置/抛弃) | WebDAV (`collectibles.tmp`, `collectchanges.tmp`) |
| history | Per-episode progress | WebDAV (event log + snapshot) |
| `trackingBindings` | Which remote entry a subject is matched to, per tracker (Bangumi auto, AniList manual) | **nothing** |
| `trackingOutbox` | Pending writes to Bangumi/AniList | none, per device by design |

The remote services (Bangumi, AniList) are the only places that hold the
cross-device truth for status and progress. Bindings are the glue.

## Current workflow (as built)

1. **Local status change** (`CollectController.addCollect`): write
   collectible, append collect change, then `statusChanged` → ensure a Bangumi
   binding (only if signed in and not opted out) → enqueue a status write for
   each bound tracker. Local first; a tracker failure never rolls it back.
2. **Episode watched** (`history_repository.dart:127`): `watched` → ensure
   Bangumi binding → enqueue progress. Progress only moves up; `statusLocked`
   stops auto-completing.
3. **Outbox drain** (`TrackingSync`): reads the remote entry, writes only the
   delta, retries with backoff (30s, 2m, 10m, 1h), pauses on rate limit, fails
   a row permanently on auth/request errors. Drained on app start (`main.dart:114`).
4. **Delete** (`deleteCollect`): removes the local row and logs a change;
   it does not touch trackers or bindings. Remote lists are never deleted.
5. **Import from Bangumi**: adds missing collectibles, never overwrites local
   status. **Does not create bindings** (gap A).
6. **WebDAV** (`syncCollectibles`): merges collectibles/changes by change id.
   Applying remote data enqueues nothing and creates no bindings (gap B).
7. **AniList**: bound only by hand (search, pick, confirm); `bind` seeds the
   remote entry as planning if it does not exist.

## Target workflow

Rule: a subject that is in the collection and whose tracker is signed in has
a binding. Anything that makes a subject collected also makes the binding.

1. One function, `BangumiBindingManager.ensureBangumiBinding`, is the only
   creator of automatic bindings. Call it from: status change, watched, import
   (every collected entry, new or existing), and WebDAV apply (every collected
   subject after `patchCollectibles`). It already honours sign-in and opt-out.
2. Import and WebDAV apply create bindings only; they enqueue **no** remote
   write (the remote already has this state, or the status came from there).
3. A one-time backfill at startup after sign-in: ensure bindings for all
   existing collectibles (fixes devices already in the current state).
4. Local status change and watched keep the outbox path as is.
5. `deleteCollect` stays local-only; document it in the UI string so users
   know the Bangumi/AniList entry remains.

## Should manual AniList matches sync over WebDAV? Yes

Reasons: it is the only binding that cannot be recreated automatically, and
the pad (and any second device) otherwise needs every match repicked. The
Bangumi binding is derivable and needs no file; only the AniList side is
worth carrying.

Design (follow `_syncCollectibles` / `collect_sync_merger.dart`):

- File `/kazumiSync/tracking.json` (WebDAV toggle: reuse the collect toggle,
  or a new `webDavEnableTracking`; owner decision).
- Payload per binding: `subjectId`, `trackerId`, `remoteId`, `title`,
  `cover`, `total`, `episodeOffset`, `statusLocked`, `score`, `updatedAt`,
  `deleted` (tombstone). Also the Bangumi opt-out ids.
- Never sync: tokens, outbox, `generation`, `lastRemoteProgress`,
  `lastSyncAt`. On apply, mint a new `generation` and reset sync state so the
  next drain re-reads the remote entry.
- Merge: per `key`, last `updatedAt` wins; a tombstone beats an older live
  row. This needs a new Hive field `updatedAt` on `TrackingBinding`
  (field 12) set by bind, rebind, unbind (tombstone) and offset/lock edits.
  `unbind`/`stopTracking` must write a tombstone instead of deleting, or the
  other device resurrects the binding.
- Apply must not enqueue remote writes, except: if a pulled AniList binding
  exists on a device with no outbox row, do nothing; progress reconciles on
  the next watched event.
- Skip pulled AniList bindings when AniList is not signed in locally; keep
  them in the file, do not drop.

## Test plan

- Import N entries → N Bangumi bindings; opted-out id gets none; existing local
  entry gets one; no outbox rows created.
- WebDAV apply of collectibles → bindings exist, no outbox rows.
- Tracking file merge: LWW, tombstone vs older live, tombstone vs newer
  rebind, round-trip without tokens/generation, signed-out AniList retained.
- Backfill is idempotent.
- On device: after import, badge shows `· 1`; sheet shows bgm bound; a second
  device after WebDAV sync shows the same AniList match.

## Open decisions for the owner

- New WebDAV toggle vs reuse the collect toggle.
- Whether delete should offer "also remove from tracker" (currently never).
- Whether backfill should run silently or behind a one-time prompt.
