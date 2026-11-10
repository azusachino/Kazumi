# Tracking redesign (fork only)

Status: plan, 2026-11-10. Branch `feat/tracking` on `azusachino/Kazumi`.
This fork is used only by its owner; nothing here goes upstream.

## Goal

Push what you watch in Kazumi to Bangumi and AniList: episode progress,
collection status and score. Watching must never wait on, or be undone by, a
tracker failure.

## Decisions (owner, 2026-11-10)

| Question | Decision |
| --- | --- |
| Existing `BangumiSyncService` (status-only, two-way merge) | Fold into the new design: Bangumi becomes one tracker behind the shared interface. The old service and its merge planner are removed. |
| Providers in v1 | Bangumi and AniList. |
| When an episode counts as watched | 90% of a known duration. Seeking alone does not count; a manual mark exists. |
| Bangumi sign-in | OAuth authorization code with refresh, plus a pasted personal token as fallback. |

## Prior art

- `vendor/hana` (Kotlin, main): decisions 0003 (AniList) and 0005 (Bangumi),
  `shared/.../tracker/TrackerApi.kt`, `TrackerSync.kt`, `BangumiClient.kt`.
  The design below follows Hana; both apps talk to trackers directly from
  the client.
- `vendor/animeko-clean` (fork PR #5): retry on start/login/before each
  watch, contract tests per provider, bindings in backups without tokens.
- `vendor/animeko-tracking-foundation` (fork PR #7) is shaped around Ani's
  server and upstream review; not followed here.

## Design

### Tracker interface

Stateless; every call takes the token.

```dart
abstract interface class Tracker {
  TrackerId get id;               // bangumi, anilist
  Future<TrackerUser> viewer(String token);
  Future<List<TrackerSearchResult>> search(String query, {String? token});
  Future<RemoteEntry?> readEntry(String token, String remoteId);
  /// Writes only the given fields; returns the progress actually stored.
  Future<int> save(String token, String remoteId,
      {int? progress, TrackStatus? status, int? score});
}
```

- `TrackStatus`: planning, current, completed, paused, dropped. Each tracker
  maps it to its own values (Bangumi collection type 1-5).
- Score is stored internally as 0-100 and rendered per tracker.
- `TrackerException` is sealed: `auth`, `rateLimited(retryAfter)`, `server`,
  `request` (permanent), `network`.

### Bindings

One binding per Bangumi subject per tracker, in a new Hive box:
`subjectId`, `trackerId`, `remoteId`, `episodeOffset` (default 0),
`statusLocked`, `score`, `lastRemoteProgress`, `lastSyncAt`, title/cover
snapshot.

- Bangumi: Kazumi items already are Bangumi subjects, so the binding is
  created automatically with `remoteId = subjectId`.
- AniList: manual. Search prefilled with the title, pick, confirm. No
  auto-matching.
- Removing a binding deletes local rows only; the remote list is untouched.

### Episode numbering

Plugin episodes are playlist positions, not Bangumi episode IDs. Progress
sent to a tracker is `localEpisode + episodeOffset`. The default assumes the
playlist matches Bangumi's main-episode order (`type = 0`, by `sort`); the
offset fixes split cours and shifted numbering. Specials and episodes whose
number can't be read are never pushed.

### Watched signal

`HistoryRepository.updateHistory` emits `EpisodeWatched(subjectId, episode)`
when progress first reaches 90% of a known duration for that episode. The
existing 5-second near-end reset of the resume position is unchanged. A
manual "mark watched" on the episode list emits the same event. Private
mode emits nothing.

### Outbox and sync

- One owed write per (subject, tracker): desired progress as a high-water
  mark, plus optional pending status/score. Re-enqueueing only raises the
  mark, so retries are idempotent.
- Drain order per row: read remote, compute the delta, write only what
  differs.
- Rules:
  - Progress never decreases.
  - Status: a locked status is sent as-is. Completed is set when progress
    reaches the known episode total. A remote completed is left alone on a
    re-watch. A new remote entry gets current (or the status chosen at bind
    time). Remote is never un-marked.
  - Score is sent only when it differs.
  - A row whose binding was removed or re-bound is dropped.
- Drain triggers: app start, sign-in, each enqueue, and backoff timers.
- Failures: network/server back off 30 s, 2 m, 10 m, 1 h, then mark the row
  failed with a visible message. Rate limits wait at least 60 s or
  `Retry-After` and pause that tracker. Auth failure fails that tracker's
  rows with "sign-in expired". Request rejection fails the row permanently.
  Calls to one tracker are spaced 500 ms apart.
- The outbox is per device and not synced over WebDAV. Two devices pushing
  the same show are safe because progress only goes up.

### Collection status (replaces `BangumiSyncService`)

- Changing a show's collection type in Kazumi saves locally first, then
  enqueues a status write for every bound tracker. The current behaviour of
  rolling back the local change when Bangumi fails is removed.
- The two-way merge, its priority setting and the full-sync dialog are
  removed. A one-way "Import from Bangumi" action adds remote entries that
  are missing locally and never overwrites local ones (proposed; drop it if
  not wanted).

### Providers

Bangumi (through the existing `BangumiClient`, so the mirror/acceleration
settings still apply):

- `GET /v0/me`
- `GET /v0/users/{username}/collections/{subject_id}` (404: no entry)
- `POST /v0/users/-/collections/{subject_id}` with `type` and `rate`
- Progress: `GET /v0/users/-/collections/{subject_id}/episodes?episode_type=0`,
  then `PUT /v0/users/-/collections/-/episodes/{episode_id}` with
  `{"type": 2}` for each of the first N main episodes not yet watched.
  `ep_status` is not written.

AniList: GraphQL at `https://graphql.anilist.co`: `Viewer` (also reads the
score format), `Page.media` search, `Media.mediaListEntry` read,
`SaveMediaListEntry(mediaId, progress, status, scoreRaw)`.

### Auth

- Bangumi: OAuth code flow, redirect `kazumi://bangumi-auth`, token exchange
  at `https://bgm.tv/oauth/access_token`, refresh when within 1 hour of
  expiry. A refresh Bangumi rejects signs the account out; a network failure
  keeps it. A pasted personal token is accepted and never refreshed.
- AniList: implicit grant, redirect `kazumi://anilist-auth`, pasted token as
  fallback.
- Every token is validated with `viewer` before it is stored. Tokens live
  in the settings box, never in logs, backups, WebDAV or fixtures.
- App IDs/secrets come from an untracked `--dart-define-from-file`
  (`.env.local.json`, gitignored), never committed.
- `kazumi://` is already registered on Android, iOS and macOS. On Windows
  and Linux, the pasted token is the supported path.
- Existing `bangumiAccessToken` migrates to a pasted-token Bangumi account.

### UI

- Show page: a tracking button opens a sheet with one row per tracker: "Track
  on X", or the bound title with progress, status, score and sync state or
  error. Tapping status/progress/score edits them; the row menu has open in
  browser, search again (AniList), and remove.
- Settings → Accounts: sign in/out per tracker, and the import action.

## Slices

Each slice is one worker turn: implement, run `flutter analyze` and the
relevant `flutter test`, report. The lead reviews and commits. Slices run
one at a time in this checkout.

| # | Slice | Depends on | Worker |
| --- | --- | --- | --- |
| 1 | Core: models, `Tracker`, exceptions, binding store, outbox store, sync engine with rules, retry and rate limit; tests with a fake tracker | none | terra |
| 2 | Watched signal at 90% plus manual mark, wired to enqueue; tests | 1 | luna |
| 3 | Bangumi tracker over `BangumiClient`: read, save, episode PUTs, status mapping, offset; tests with a fake transport | 1 | terra |
| 4 | Bangumi accounts: OAuth flow, deep link, refresh, pasted token, migration from `bangumiAccessToken`; tests | 3 | terra |
| 5 | Fold collection status into the outbox; remove `BangumiSyncService`, merge planner, priority setting and full-sync dialog; one-way import; tests | 3, 4 | luna |
| 6 | AniList tracker, implicit-grant account, manual bind search; tests | 1 | terra |
| 7 | UI: tracking sheet and Settings → Accounts | 4, 5, 6 | luna |

## Verification

- Per slice: `flutter analyze` clean for touched files, `flutter test` green.
- End to end, on the owner's devices with real accounts: sign in to both
  trackers; watch past 90% and see progress on bgm.tv and anilist.co; change
  status and score; go offline, watch, reconnect and see the outbox drain;
  revoke a token and see the expired-sign-in state.

## Needs from the owner

- Register a Bangumi app (callback `kazumi://bangumi-auth`) before slice 4.
- Register an AniList client (redirect `kazumi://anilist-auth`) before
  slice 6.

## Not in v1

Comments, notes, start/finish dates, private flag, other trackers, syncing
the outbox across devices.
