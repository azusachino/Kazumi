# haru.5 Android verification delivery

The owner authorized installation on the pad followed by the phone, and a PR to
`azusachino/Kazumi`, after the tracking-sync implementation and review.
No GitHub release, tag, upstream PR, uninstall, data clear or manual tracker
status change is included in that request.

## Build identity

- Source: `3f3649f0` on `task/tracking-sync`; runtime/test inputs are identical
  to reviewed `973aa8330476fdec4b15eefb85dc7888665d86a0` (only Markdown changed).
- Package: `com.predidit.kazumi`.
- Version: `2.4.3-haru.5`, Android version code `20404`.
- Release APK: `build/app/outputs/flutter-apk/app-release.apk` in the task
  worktree; SHA-256 `c9e537c4addd51037e43a5505bf4c99ee129ae77131f140fc6850463d6148a10`.
- Signing certificate SHA-256:
  `7b51900552bbc088391e28fb243914402e5fe258c33f1bed2116409dcb61c4a9`.
- Build command: `mise exec -- env ANDROID_HOME=<installed Android SDK>
  JAVA_HOME=<installed JDK 21> flutter build apk --release
  --target-platform android-arm64 --build-name 2.4.3-haru.5
  --build-number 20404 --dart-define-from-file=<owning checkout>/.env.local.json`.
  OAuth configuration remained local and ignored; no secrets are committed.
- Result: exit 0, APK about 33.5 MB. Gradle took 325.6 seconds. Existing
  future-support, SDK XML, obsolete Java-source and native compiler cache
  warnings appeared; no validation bypass flags were used.
- Automated source checks: plain Flutter analysis clean; full suite 318 passing.
  Independent review and focused recheck are preserved beside this record.

## Installation evidence

Pad: OnePlus Pad OPD2404, adb `2f11f2ca`. Before install, the existing APK was
pulled for certificate comparison; both certificates matched the digest above.
`adb -s 2f11f2ca install -r <APK>` exited 0 with `Success`. Package inspection
confirmed version `2.4.3-haru.5`, code `20404`, and the original
`firstInstallTime=2026-11-10 21:24:19` remained unchanged. App data was preserved.

Phone: OnePlus PLR110, adb `3B66A6009QZ00000`. Its existing Kazumi version was
`2.4.3-haru.4`, code `20403`; the pulled APK's signing certificate matched the
digest above. `adb -s 3B66A6009QZ00000 install -r <APK>` exited 0 with
`Success`. Package inspection confirmed `2.4.3-haru.5`, code `20404`, with the
original `firstInstallTime=2026-11-10 20:21:19` unchanged. Hana was untouched.

Both requested devices have the same APK installed as an in-place update.
The PR to the owner's fork is https://github.com/azusachino/Kazumi/pull/2;
owner acceptance remains pending. All commits after the APK's source identity
above only record verification/delivery; runtime and build inputs are unchanged.

## Owner verification

Device behavior is pending owner acceptance. Check the imported-show tracking
badge and tracker-only sheet, then AniList match/tombstone convergence over
WebDAV between devices. The installer did not change a live account status.
Known limits remain in `docs/design/tracking.md`.
