# Tracking redesign (fork only)

Status: implemented on `feat/tracking` (2026-11-10), not yet verified with
live accounts; see "Implementation notes". Branch `feat/tracking` on
`azusachino/Kazumi`.
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
| Bangumi sign-in | OAuth authorization code with refresh. A pasted-token fallback was planned, then dropped: OAuth only for both trackers. |

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

Tokens are sent only to the official hosts: `api.bgm.tv`, `bgm.tv` (OAuth)
and `graphql.anilist.co`. Upstream Kazumi sends authenticated Bangumi calls
to a hardcoded third-party mirror (`api.bgmapi.com`), and its default
"mirror" acceleration rewrites `api.bgm.tv` to `api.kazumi.fyi` with the
`Authorization` header intact. Tracker requests therefore never go through
a mirror; ECH is allowed because it still reaches the official host. Public,
unauthenticated browsing keeps its mirror settings.

Bangumi:

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
  keeps it.
- AniList: implicit grant, redirect `kazumi://anilist-auth`.
- Sign-in is OAuth only (owner decision, 2026-11-10): there is no pasted
  token. A build without app IDs cannot sign in, so tracking is off.
  Upstream's `bangumiAccessToken` and any pasted session are deleted at
  startup.
- Every token is validated with `viewer` before it is stored. Tokens live
  in the settings box, never in logs, backups, WebDAV or fixtures.
- App IDs/secrets come from an untracked `--dart-define-from-file`
  (`.env.local.json`, gitignored), never committed.
- `kazumi://` is registered on Android, iOS and macOS. Windows and Linux
  cannot complete the redirect, so they have no tracking sign-in.

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
| 5 | Fold collection status into the outbox; remove `BangumiSyncService`, merge planner, priority setting and full-sync dialog; one-way import; move any remaining authenticated `BangumiApi` calls off `api.bgmapi.com`; tests | 3, 4 | luna |
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

## Implementation notes

Where the code differs from, or adds to, the design above:

- Bindings carry a random generation minted at bind time; a queued write
  whose generation no longer matches is dropped before the remote read and
  again before the write. A request already in flight when a binding is
  removed is not cancelled, so at most that one write lands.
- An explicit status change always wins over derived rules; the "keep
  remote completed" rule and `statusLocked` apply only to derived status.
- A new enqueue clears a row's failure; signing in retries that tracker's
  failed rows.
- Errors that are not `TrackerException` are retried like server errors.
- Removing a Bangumi binding records an opt-out so the show is not re-bound
  on the next watch; "开始追踪" clears it.
- Editing the episode offset mints a new binding generation, which drops
  writes queued under the old offset; the next watch re-queues.
- The watched signal compares consecutive saved progress samples within a
  session. Opening an episode already past 90% does not count, but a seek
  from early in the episode to the end does; fixing that needs seek events
  from the player.
- Removing a show from the local list no longer offers to mark it dropped on
  Bangumi; removal is local only.
- Slice 5 ran on terra instead of luna because of its size.

## Tracking UX v2 (Mihon-style), 2026-11-10

The first sheet worked but read as a list of controls. The owner wants
Mihon's experience: both trackers managed in one place, each in the same
shape. Reference: `refs/media-tracking-apps/mihon` at `0c55527`,
`app/src/main/java/eu/kanade/presentation/track/` (`TrackInfoDialogHome.kt`,
`TrackerSearch.kt`, `TrackInfoDialogSelector.kt`).

### Tracking sheet

- One block per **signed-in** tracker, Bangumi first, same layout for both.
  Signed-out trackers are not shown; with none signed in, the sheet shows a
  short message and a button to 追踪账号.
- **Not tracked:** tracker logo + a full-width "添加追踪" text button.
  AniList opens the tracker search. Bangumi binds the current subject
  directly (Kazumi items are Bangumi subjects), clearing any opt-out.
- **Tracked:**
  - Header row: logo (tap: open in browser; long-press: copy link), the bound
    title (tap: search again, AniList only; long-press: copy title), a
    vertical divider, and a `⋮` menu (open in browser, copy link, 集数偏移,
    remove).
  - Details box (rounded, `surfaceContainerHighest`): three equal cells
    separated by dividers: status | progress `3 / 12` (or `3` when the total
    is unknown) | score (placeholder "评分" when unset).
  - A sync line under the box only when there is something to say:
    "等待同步" or the failure message with "重试".
- **Selectors** (dialogs, Mihon's `BaseSelector` shape: title, content,
  取消 / 确定):
  - status: radio list 想看 / 在看 / 看过 / 搁置 / 抛弃;
  - progress: number picker from 0 to the known total (free number field when
    the total is unknown);
  - score: number picker 0–10, 0 meaning unscored.
- Remove asks for confirmation and says the remote list is not changed; for
  Bangumi it also says the show will not be tracked automatically again.

### Tracker search (AniList)

- Full-screen page: back button, a search field in the top bar with a clear
  button, results below.
- The query is prefilled with the **original title** (`BangumiItem.name`,
  falling back to `nameCn`) regardless of the display setting: AniList does
  not match Chinese titles, and Japanese titles match on both platforms.
- Each result is a card: cover, title (native, then romaji), and small
  details (format, year, episodes). Tapping selects it (highlighted border);
  a bottom "追踪" button binds the selection. A result's menu offers open in
  browser.

### Prefer original title

A switch in Settings → 界面: "显示原名", description "在番剧列表、详情页和播放器优先显示原名（通常为日文），而非中文名".
It follows the owner's animeko setting (fork PR #2,
`feat/original-title-display`). Off (default) keeps upstream behaviour.

- One helper decides the display title: on → `name`, falling back to
  `nameCn`; off → `nameCn`, falling back to `name`. Where a screen shows a
  secondary title line, it shows the other name.
- Applies to subject titles only (cards, info page header, collection and
  history lists, search results, player and download titles, comments
  sheet headers); character and staff names are unchanged.

## Building and verifying the fork

- Toolchain is pinned in `.mise.toml` (Flutter, CMake, Ninja; `ech_http`
  builds native code and needs CMake and Ninja).
- `flutter analyze` reports 17 pre-existing infos and exits 1 even then.
  Compare the issue count with 17, not the exit code.
- `flutter build macos` rewrites `macos/Podfile` (deployment target 10.15 →
  12.0) and `project.pbxproj`. Revert both after a build; they are not part
  of any change.
- Release builds: `--dart-define-from-file=.env.local.json` (app IDs) and a
  fork version such as `--build-name 2.4.3-fork.3`, so installed builds are
  distinguishable from upstream 2.4.3. macOS shortens a non-numeric build
  name (`2.4.3-fork.3` shows as `2.4.3.3`).
- Android release APKs are signed with the debug key, so they install fresh
  but cannot replace an upstream Kazumi install without uninstalling it.
  Android SDK on harus-macmini: `ANDROID_HOME=/opt/homebrew/share/android-commandlinetools`.

## App registrations

Kazumi has its own Bangumi app and AniList client, registered with
`kazumi://bangumi-auth` and `kazumi://anilist-auth`. Reusing Hana's
registrations (`hana://…`) was tried and dropped: on a phone with Hana
installed, Android hands the redirect to Hana. Redirect URIs remain
build-time values (`BANGUMI_REDIRECT_URI`, `ANILIST_REDIRECT_URI`) that
default to the `kazumi://` URIs.

## Not in v1

Comments, notes, start/finish dates, private flag, other trackers, syncing
the outbox across devices.
