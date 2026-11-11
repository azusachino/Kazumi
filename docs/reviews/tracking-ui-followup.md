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
