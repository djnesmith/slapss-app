# Fork features

Read this before merging upstream. Every item must still work after the merge.

Branch: `main`. Merge `upstream/main` in (never rebase) and take upstream's version numbers as they are.

Test suite (covers most items below):

```sh
xcodebuild test -project slapss.xcodeproj -scheme slapss -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

## 1. Meeting browser window placement

Two settings, both off by default: open meetings in a new browser window, and always on the built-in display. Chromium uses launch flags; Safari uses Apple events.

- Commits: `325abc0`, `86e73e3` (make-window and place-window sent as one script)
- Files: `slapss/Calendar/BrowserPlacement.swift`, `BrowserWindowOpener.swift`, `ScreenPlacement.swift`, `MeetingURLOpener.swift`, `slapss/Settings/AppSettings.swift`, `SettingsView.swift`, `slapss/Info.plist` (`NSAppleEventsUsageDescription`), `slapss/slapss.entitlements` (`automation.apple-events`)
- Check: tests `BrowserPlacementTests`, `ScreenPlacementTests`. By hand: Settings > Joining meetings, turn on "Open meetings in a new browser window" and "Always on the built-in display", join a meeting with an external display attached. It opens in a new Safari window on the laptop screen.

## 2. App Sandbox off

`ENABLE_APP_SANDBOX = NO` and no `app-sandbox` entitlement. The sandbox blocks Apple events to Safari (-600), which breaks item 1. README and SECURITY.md say so.

- Commits: `86e73e3`
- Files: `slapss.xcodeproj/project.pbxproj`, `slapss/slapss.entitlements`, `README.md`, `SECURITY.md`
- Check: `grep -n ENABLE_APP_SANDBOX slapss.xcodeproj/project.pbxproj` shows `NO` twice; `grep app-sandbox slapss/slapss.entitlements` prints nothing.

## 3. Google account picker on every calendar

"Open Google Meet as" shows for every calendar, not only ones whose account name looks like Google, so renamed Workspace accounts get it.

- Commits: `960075a`, `247fcd5`, `f63c161`
- Files: `slapss/Settings/SettingsView.swift`
- Check: tests `GoogleAuthUserCalendarIDsTests`, `BrowserPlacementTests` (authuser cases). By hand: Settings > Calendars, every calendar has an "Open Google Meet as" row.

## 4. Pause media on join

Off-by-default setting. On join it pauses Music, TV, Spotify, VLC, and playing media in Safari/Chrome tabs, only if already running. Never starts playback, no media key, no Accessibility grant.

- Commits: `ef4db36`, `054d901` (plus docs `38a3263`, `242baf1`)
- Files: `slapss/Media/MediaPausePlan.swift`, `slapss/Media/MediaPauser.swift`, `MeetingURLOpener.swift` (`pauseMedia:`), `AppDelegate.swift`, `ContentView.swift`, `AlertScheduler.swift`, `Translations.swift` (`settings.alert.pauseMedia`)
- Check: test `MediaPausePlanTests`. By hand: turn on "Pause playing media when I join", play Music, join a meeting. Music pauses; with nothing playing, nothing starts.

## 5. SimplePractice join links

`video.simplepractice.com` room links get a Join button. Exact host match, added last so other providers keep priority.

- Commits: `4a4e49b`
- Files: `slapss/Calendar/MeetingLinkDetector.swift`
- Check: test `MeetingLinkDetectorTests` (SimplePractice cases).

## 6. Unit test target and CI Test lane

Adds the `slapssTests` target (no version settings of its own, so `release-check.yml` still passes) and a Test step in `build.yml`. Also pins upstream's 2.1.1 Zoom asset-URL fix.

- Commits: `325abc0`, `247fcd5`, `0413377`, `d697dbc`
- Files: `slapss.xcodeproj/project.pbxproj`, `slapss.xcodeproj/xcshareddata/xcschemes/slapss.xcscheme`, `.github/workflows/build.yml`, `slapssTests/`, `CONTRIBUTING.md`
- Check: the test command above runs all suites with 0 failures; `grep -n 'xcodebuild test' .github/workflows/build.yml` matches; `grep -c MARKETING_VERSION slapss.xcodeproj/project.pbxproj` count did not grow.

## 7. Fork docs and TCC signing notes

CLAUDE.md and RELEASING.md describe this fork (built locally, tracks upstream, no App Store). CLAUDE.md records the TCC rule: a grant pins how the binary was signed when it was granted, so sign local installs with your own identity and check with `codesign -R`.

- Commits: `765fe19`, `38a3263`, `242baf1`, `67c67f4`
- Files: `CLAUDE.md`, `RELEASING.md`, `README.md`, `SECURITY.md`, `CHANGELOG.md`
- Check: after the merge, CLAUDE.md and RELEASING.md still name `djnesmith/slapss-app` as origin and keep the TCC gotcha; README/SECURITY.md entitlement lists match `slapss/slapss.entitlements` (3 keys).

## 8. No App Store rating prompt

Upstream 2.2.3 added Apple's rating prompt (`ReviewPrompt.swift`, `requestReview` in the popover). This build doesn't come from the App Store, so it is removed. Upstream's 2.2.3 stale-alert-after-sleep fix stays.

- Commits: "Drop the App Store rating prompt" (the commit that adds this entry)
- Files: `slapss/ContentView.swift`, `slapss/Scheduling/AlertScheduler.swift` (`handleJoin`), `slapss/ReviewPrompt.swift` (deleted), `slapssTests/NoReviewPromptTests.swift`
- Check: test `NoReviewPromptTests`; `grep -rnE 'requestReview|StoreKit|ReviewPrompt' slapss/` prints nothing. If an upstream change edits the prompt, the merge conflicts or brings the file back; delete it again.
