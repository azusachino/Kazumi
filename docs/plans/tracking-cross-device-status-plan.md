# Plan: coordinate watch status across Bangumi, WebDAV, the library and devices

Supersedes `tracking-status-consistency-plan.md` (haru.11) for the cross-store
and cross-device questions. Revised after the GLM review at `84342429`
(`.tmp/kazumi-plan-review/report.md`).

## Explicitly supersedes two recorded decisions

`docs/design/tracking.md` currently records:

1. "Propagation writes no outbox row and no collect change."
2. "Implicit binding creation — Bangumi import, WebDAV apply and the startup
   backfill — still enqueues nothing."

Decision 1 is reversed here: propagation must record a change or WebDAV reverts
it. Decision 2 stays true for *import* and *backfill*; it is narrowed for
**WebDAV apply**, which may enqueue a delta under the guard in slice 4. Slice 5
rewrites both sentences; until then the design doc is knowingly stale.

## Stores and the fact each owns

| Store | Owns | Travels over |
| --- | --- | --- |
| Bangumi collection entry | **canonical watch status**, with its own `updated_at` | the tracker |
| AniList entry | secondary manual match | the tracker |
| `collectibles` (在看/想看/…) | this device's projection of the status | WebDAV |
| `collectchanges` | the intent log that makes WebDAV merge possible | WebDAV |
| `trackingEntryCache` | what the drawer displays | never (display only) |
| `trackingOutbox` | pending writes | never (per device) |

Rule: **Bangumi owns the status; the local category is a projection; WebDAV
carries the projection and the intent; AniList is independent.**

## Holes this plan closes

1. **Propagation is invisible to WebDAV** — drain propagation rewrites the
   category with no change record, so the next collectibles sync reverts it.
2. **The merge is not last-write-wins by time** — remote box is the base and
   local changes replay, so the later syncer wins regardless of intent; and
   same-second ids from two devices can collide, silently dropping a change.
3. **A category arriving over WebDAV never reaches the trackers** on that device.
4. **No origin concept**, so once 1–3 make writes travel both ways nothing bounds
   a loop.

## Decisions

1. **Every category write records a change**, including propagation and apply.
2. **Changes carry an origin** (`user` / `tracker`). Origin is not the loop guard
   on its own — it is an input to it.
3. **A tracker-origin change never causes a tracker write**, so propagation
   cannot echo back.
4. **Apply may enqueue only when the winning change is newer than the tracker's
   own `updated_at`.** A user-origin change that predates a deliberate tracker
   edit must not overwrite it. This needs the tracker timestamp (slice 4a); it is
   the one piece of new data the review showed is unavoidable.
5. **Comparison is symmetric and deterministic.** Ties between two devices
   resolve by content, not by "keep local": higher origin first (`user` before
   `tracker`), then higher `type`. Both devices pick the same winner whichever
   side they are on, so a tie converges instead of oscillating.
6. **The change log is keyed by `(id, subject)`**, not `id`; an incoming change
   whose id is taken locally by a different subject gets a fresh local id, so a
   collision can never drop either edit.
7. **Apply enqueues Bangumi only.** AniList is never written from a received
   category.
8. AniList never drives the library category.

## Slices

Test first, one commit each, fakes only.

### Slice 1: change origin, on a safe Hive field

Files: `lib/modules/collect/collect_change_module.dart` (+ regenerated adapter),
`lib/services/storage/storage.dart`.

- `@HiveField(5, defaultValue: 0) int origin;` — field 4 is already `timestamp`;
  field 5 is the next free index. `defaultValue: 0` is mandatory: the generated
  adapter reads `(fields[i] as num).toInt()`, and this box is synced as raw Hive
  bytes, so rows written by older builds are everywhere. Without it the new build
  throws while opening the box and `_openBoxSafe` recovery becomes the fallback.
- `0 = user`, `1 = tracker`. `appendCollectChange` takes `origin`, default user.
- Regenerate with build_runner; verify the diff adds only field 5 and no typeId
  change.
- Tests: an old-shaped row (no field 5) loads with origin 0 and does not throw; a
  new write round-trips; the drain propagation records origin 1.

### Slice 2: propagation records a change, atomically

Files: `lib/services/storage/storage.dart` (`setCollectTypeIfPresent` →
`followTrackerStatus`), tests. Also delete the dead, now same-named
`CollectController.followTrackerStatus` (its only caller is a test) or rename it,
so two layers do not share a name with different semantics.

- The category write and the `tracker`-origin change append happen inside **one**
  `_runCollectChangesWriteExclusive` block, not two acquisitions.
- Test: after propagation, merging against a remote box that still holds the old
  category keeps the new one (hole 1), and no outbox row is created.

### Slice 3: per-subject LWW with a symmetric tie-break

Files: `lib/modules/collect/collect_sync_merger.dart`, its tests.

- Identity is `(id, subject)`. Union both logs; on an id collision between
  different subjects, keep both (the incoming one gets a fresh id at apply time).
- Per subject, the winning change is the greatest `(timestamp, originRank, type)`
  tuple; apply winners over the remote base, including `action == 3` deletes.
- Tests: remote newer wins; local newer wins; same-second tie resolves by content
  identically from either side (assert by merging in both directions and
  comparing); id collision between different subjects keeps both edits; delete
  beats an older add; unrelated subjects untouched.

### Slice 4: apply enqueues a guarded delta

Files: `lib/services/tracking/models.dart` (`RemoteEntry.updatedAt`),
`lib/services/tracking/bangumi_tracker.dart` (populate from the collection
response's `updated_at`), `lib/services/tracking/tracking_entry_cache.dart`
(persist it), `lib/services/sync/webdav.dart`, `test/webdav_service_test.dart`.

- 4a: carry the tracker's `updated_at` on `RemoteEntry` and cache it, so a
  comparison against change timestamps is possible at all.
- 4b: after `patchCollectibles`, for each subject whose **local category differs
  from the tracker status this device last recorded**, where the winning change is
  user-origin, **newer than that recorded tracker `updated_at`**, a Bangumi
  binding exists, and no outbox row is pending → enqueue the category with
  `trackerId: TrackerId.bangumi`. Everything else enqueues nothing.
- Tests: A sets 看过 and syncs; B syncs, then **B drains** and writes 看过 exactly
  once; a second sync enqueues nothing. A stale user change older than a newer
  bgm.tv edit enqueues **nothing** and the tracker keeps the web edit. A
  tracker-origin winner enqueues nothing. An AniList binding is never the target.

### Slice 5: docs, evidence, limits

- Rewrite the two superseded sentences in `docs/design/tracking.md`; add the
  ownership table, the origin rule, the symmetric tie-break, the collision rule
  and the timestamp guard.
- Update `docs/reviews/tracking-ui-followup.md`: what is coordinated now, what is
  not.
- Gates: plain `flutter analyze` clean, full `flutter test` green.

## Accepted limits

- Eventual convergence at sync/drain points; no push channel.
- Wall clocks decide LWW; a fast clock wins. Ties resolve by content, not time.
- Downgrade: an old build drops origin and can re-enqueue once.
- A drain failure leaves the local category ahead until retry.
- Deletions stay local-only against trackers; AniList is never propagated to.

## Risks

- Adding a field to a synced box: forward-safe, downgrade lossy (above).
- Apply can now write to a tracker; it must never fail the collect sync and never
  touch a subject the owner did not act on.
- The merge change sits on the most-travelled sync path; single-device behaviour
  must stay pinned by the existing tests.
