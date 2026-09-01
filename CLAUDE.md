# Slapss — Claude Project Context

macOS menu bar app (SwiftUI + AppKit hybrid). Shows meetings from macOS Calendar / Exchange and fires a full-screen overlay alert at meeting start. Distributed via App Store.

Two repos:
- `slapss-app` — macOS app (this repo). **Public**, Apache-2.0. See `CONTRIBUTING.md`.
- `slapss-web` — marketing site on Cloudflare. **Private**, not published. The user-facing changelog is served from it at <https://slapss-app.com/changelog.html>.

`CHANGELOG.md` in this repo is the source of truth for user-facing release notes; `changelog.html` and GitHub Releases are copied from it. The "Changelog log" at the bottom of this file is the separate engineering record — different audience, keep both.

---

## Rules

- **Never bump version numbers without asking Can first.** He decides the version.
- **Release process is in `RELEASING.md`.** Follow it in order; the ordering is what keeps the App Store, the tag, the GitHub Release, and the marketing site in step.
- **After every user-visible change, update `CHANGELOG.md` first**, then mirror it into `slapss-web/changelog.html` (separate private repo). Record the engineering detail in the Changelog log at the bottom of this file. No exceptions.
- Never touch `slapss-web` unless the change requires updating privacy/terms or the changelog.

---

## Architecture

### Entry point
`slapssApp.swift` — `@main`. Creates all `@StateObject`s and injects them as `environmentObject` into every scene.

### Core objects (all `ObservableObject`, injected via environment)
| Object | Responsibility |
|---|---|
| `CalendarAggregator` | Merges EventKit + Microsoft Graph sources, publishes `upcomingMeetings` |
| `AppSettings` | All user preferences, persisted to UserDefaults |
| `AlertScheduler` | Timers, watchdog, App Nap prevention, fires/queues overlays |
| `LocalizationManager` | Runtime language switching without restart |
| `PopoverVisibilityMonitor` | Tracks real popover open/close via NSWindow notifications |

### Key files
- `ContentView.swift` — popover UI (hero card, agenda, `BlobsBackground`, `FloatingDotsBackground`)
- `AlertView.swift` — full-screen overlay card
- `OverlayWindowController.swift` — manages the screen-saver-level `NSWindow`(s) hosting `AlertView`
- `AlertScheduler.swift` — all scheduling logic, App Nap, watchdog, missed-fire recovery
- `CalendarAggregator.swift` — merge + poll loop
- `EventKitSource.swift` — EventKit fetch (Calendar + Reminders)
- `GraphSource.swift` — Microsoft Graph fetch (Exchange)
- `AppSettings.swift` — all `@Published` preferences + UserDefaults persistence
- `PopoverVisibilityMonitor.swift` — NSWindow notification observer
- `Theme.swift` — `AppTheme` (sunset/ocean/forest) + `AppTheme.Accents` color sets + `ThemeSwatchPicker` (shared by Settings and Onboarding)
- `Calendar/MeetingURLOpener.swift` — the one entry point for opening a join link
- `Calendar/BrowserPlacement.swift` — pure: the two join preferences, the browser family, and which combinations need the Automation grant
- `Calendar/ScreenPlacement.swift` — pure: built-in-display selection and the AppKit → AppleScript coordinate conversion
- `Calendar/BrowserWindowOpener.swift` — the only file that touches NSWorkspace launch arguments, NSScreen, and Apple events

---

## Non-obvious patterns and gotchas

### The project requires Xcode 26+ — older Xcode fails with actor-isolation errors

`project.pbxproj` sets `SWIFT_APPROACHABLE_CONCURRENCY = YES` and
`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (Swift 6.2 / Xcode 26 settings), with
`SWIFT_VERSION = 5.0`. Every declaration is therefore implicitly `@MainActor`,
which is why so little of this codebase carries explicit `@MainActor` annotations
despite being almost entirely UI code.

Xcode versions older than 26 do not recognise those build settings. They don't
error on the unknown setting — they **silently ignore** it, compile everything as
nonisolated, and then emit a wall of *"call to main actor-isolated instance
method ... in a synchronous nonisolated context"* errors in `MeetingEvent.swift`,
`StatusMenuController.swift`, and `AlertView.swift`. The code is not broken; the
toolchain is too old. This is what broke the first public CI run on a `macos-15`
runner (Xcode 16).

Consequences:
- CI must run on `macos-26` or newer. See `.github/workflows/build.yml`.
- Don't "fix" those errors by sprinkling `@MainActor` or `nonisolated` around.
  Check the Xcode version first.
- If the implicit-MainActor default is ever turned off, the annotations it was
  standing in for have to be added back by hand across the whole codebase.

### MenuBarExtra(.window) keeps the view graph alive permanently
`onAppear` fires once on first popover open. `onDisappear` **never fires** on popover close — the window hides, it is not destroyed. Consequences:
- Never use `onAppear/onDisappear` to gate `.repeatForever()` animations. They will run at 60 fps indefinitely with nothing on screen.
- Use `PopoverVisibilityMonitor.isVisible` instead, which listens to real `NSWindow` key/close notifications.

### Color.clear flips NSView coordinate system on macOS
In a `ZStack` on macOS, `Color.clear`'s NSView backing can leak a flipped coordinate context into sibling views, mirroring glyphs. Always use `.frame(maxWidth: .infinity, maxHeight: .infinity)` to expand a transparent area. Never use `Color.clear` as a spacer in a ZStack.

### Timer.scheduledTimer is App Nap-vulnerable
Menu-bar apps are aggressively enrolled in App Nap. `.scheduledTimer` is added to `.default` runloop mode, which the OS throttles or suspends. Always use `Timer(...) + RunLoop.main.add(timer, forMode: .common)`. `GraphSource.startPollTimer` was the last holdout in the codebase and was converted in 2.0.1 — it matters most there, because a Microsoft 365-only user never starts EventKit's 30-second poll (it is gated on calendar permission), so the Graph timer is their only refresh path.

### refreshEventKitOnly must cancel its previous Task
Any async Task started on a repeating timer must store its handle and cancel before starting a new one. If EventKit is slow, tasks accumulate and each completion triggers a full Combine cascade, growing CPU unboundedly over days.

### AppKit-hosted views don't inherit SwiftUI environment
`OverlayWindowController` builds `NSHostingView` directly. SwiftUI `environmentObject` values are not propagated automatically — must be passed explicitly: `rootView.environmentObject(lm)`.

### OverlayWindow must become key for ESC to work
A borderless `NSWindow` (`.borderless` style) cannot become key by default. `OverlayWindow` overrides `canBecomeKey` and `canBecomeMain` to `true`, and `slapssApp.activate(ignoringOtherApps: true)` is called before `makeKeyAndOrderFront`. On dismiss, the previously frontmost app is reactivated.

### Overlay controls that expand must stay inside the overlay window
The full-screen alert runs in a borderless `.screenSaver`-level `NSWindow`. SwiftUI `.popover`, `Menu`, system tooltips, and similar presentations can create separate system-managed windows that macOS may place behind or suppress relative to the overlay. Render expanded controls directly in `AlertView` with an in-window `.overlay` instead. The snooze dropdown follows this pattern; the attendee tooltip does too.

### Calendar filter is not auto-seeded at launch
`CalendarAggregator.start(enabledEventKitCalendars:enabledGraphCalendars:)` must receive the persisted selection from `AppSettings` to seed the source filters before the first fetch. An empty set in `EventKitSource` means "all calendars."

### MenuBarExtra window identification
`menuBarExtraWindows()` identifies the popover window by three properties: no `.titled` style mask, level above `.normal`, and top edge near the menu bar. This same heuristic is used by `PopoverVisibilityMonitor`. Don't change one without the other.

### Presenting Now is intentionally manual, not detected
v1.8 originally scoped "suppress the overlay while screen sharing" using `INFocusStatusCenter` (Focus/DND detection). Abandoned before implementation: that API requires a restricted `com.apple.developer.focus-status` entitlement that needs separate approval from Apple (like CarPlay), not a self-serve Xcode capability — too risky to gate a shipping feature on. There is also no reliable *public* API to detect "this screen is being captured by another app" on macOS (Zoom/Teams/Meet each implement capture differently). Shipped instead as `AlertScheduler.presentingModeEnabled` — a session-only (never persisted) manual toggle. Every `fireMeetingStart` call is redirected into `pendingAlerts` while it's on, using the same FIFO that handles back-to-back meetings, and drained via `togglePresentingMode()` when switched off. If Apple's Focus Status entitlement becomes self-serve in the future, revisit — it would be a strictly better UX than remembering to flip a toggle.

### StatusMenuController is localized via a borrowed weak reference
`StatusMenuController` is a plain AppKit singleton instantiated before any SwiftUI environment exists, so it can't use `@EnvironmentObject`. It holds `weak var lm: LocalizationManager?`, wired once from `MenuBarContentView.onAppear` (same pattern already used for `onOpenPreferences`). If `lm` is nil (a right-click landing before the popover's first appearance), menu strings fall back to English literals rather than crashing.

### EventKit reuses one identifier for every occurrence of a recurring event

`EKEvent.eventIdentifier` is identical for Monday's stand-up and Tuesday's. Before v2.0 `MeetingEvent.id` was just `"ek:" + eventIdentifier`, so a whole recurring series collapsed into a single id — and everything keyed by that id (`dismissedIDs`, `snoozeUntil`, `menuBarMutedIDs`, `scheduledEffectiveStart`) treated the series as one item.

The user-visible bug: dismissing one occurrence's overlay inserted the shared id into `dismissedIDs`, which is **insert-only and never cleared**, so `reschedule` skipped every future occurrence at the `guard !dismissedIDs.contains` line and no timer was ever created again. Meanwhile the menu-bar countdown reads `aggregator.upcomingMeetings` directly (`ContentView`), which has no dismissal filter — so the countdown looked perfect while the alert silently never fired. Reported from the field as "the first meeting of each day never alerts" (it was the reporter's daily recurring stand-up).

`toMeetingEvent` now appends `"#<occurrence-start-epoch>"`. Microsoft Graph was never affected: `calendarView` expands series into per-occurrence objects with distinct ids.

Consequences:
- A detached instance moved to a different time gets a new id. That's intended — it's a different slot and deserves its own alert.
- `dismissedIDs` no longer collapses across a series, so it grows by roughly one entry per dismissed occurrence over long uptimes. Deliberately **not** pruned against the current meeting set: a transient EventKit fetch hiccup would resurrect an alert the user already dismissed, which is worse than a set of short strings.
- `eventIdentifier` can still be nil, in which case the id falls back to a fresh `UUID()` on every fetch. Pre-existing and untouched; only affects unsaved events.

### `eventKitIdentifier` parses the `id` prefix AND the occurrence suffix — don't change either scheme without updating it
`MeetingEvent.eventKitIdentifier` (used by "Open in Calendar") strips both the `"ek:"` prefix and the trailing `"#<occurrence-epoch>"` that `EventKitSource.toMeetingEvent(_:EKEvent)` puts on the `id`. It uses `lastIndex(of: "#")` so an identifier that itself contains `#` survives intact. It intentionally does NOT add a new stored property for this — if `EventKitSource`'s id-prefixing convention (`"ek:"` / `"reminder:"`) ever changes, this computed property needs to change with it.

### "Open in Calendar" uses an undocumented URL scheme
`MeetingURLOpener.openInCalendar` opens `ical://ekevent/<identifier>`. This is **not** a public Apple API — it's a widely-reported-working but undocumented Calendar.app URL scheme. If it silently stops working after a macOS update, this is why; there's no public alternative as of this writing.

### Themed colors go through `settings.theme.accents`, not static Tokens
The accent layer (blobs/dots, pill, hero tints, join-button fill, brand gradient) lives in `AppTheme.Accents` (Theme.swift) and is read as `settings.theme.accents.<name>` via `@EnvironmentObject var settings`. Do NOT reintroduce these as `Tokens` statics: SwiftUI skips re-rendering sub-structs whose stored inputs didn't change, so a static-token color swap doesn't reliably propagate — the ObservableObject path does. Neutral surfaces/ink stay in `Tokens` and are intentionally theme-independent; light/dark remains a separate axis handled inside each `Accents` color via dynamic NSColor providers. The full-screen overlay can't use the environment (see AppKit gotcha above), so `AlertScheduler` passes `settings?.theme ?? .sunset` by value into `OverlayWindowController.show(theme:)` at fire time — a theme change while an overlay is up applies from the next alert. The overlay mesh maps sunset→`.sunset`, ocean→`.cool`, forest→`.forest` (the latter two existed unused in `MeshBackground.Palette` since v1). Default is `.sunset`, which byte-for-byte matches the pre-theming colors — existing users see no change.

### RSVP filter is scheduler-only and fails open
`MeetingEvent.rsvp` drives the `onlyAcceptedMeetings` overlay filter in `AlertScheduler.reschedule` — not `CalendarAggregator`, so tentative/declined meetings stay visible in the popover agenda; only their overlay/lead notification is suppressed. RSVP defaults to `.unknown` and only `.tentative`/`.declined` are filtered, so anything the source can't classify (organizer, local/personal calendars, EventKit's `isCurrentUser` not matching) still fires — the filter never hides a meeting it isn't sure about. EventKit's `isCurrentUser` match is unreliable for some account types; that's the accepted tradeoff for failing open.

---

### "Do we have calendar data?" is not the same question as "do we have EventKit permission?"
`CalendarAggregator.permissionState` mirrors EventKit only — Graph has its own `GraphSource.state`, and `performRefresh` fetches Graph regardless of the EventKit verdict. Any UI that gates on `permissionState` alone strands Microsoft 365 users who never grant Calendar.app access. `OnboardingView.canFinishOnboarding` had the right rule (`granted || isGraphSignedIn`) since 1.8; the popover did not, and until 2.0.1 it replaced a fully working M365 agenda with a red "Calendar access denied" screen while the menu bar — which reads the merged event list and has never been permission-gated — kept showing the same meeting. Reported by a user, 2026-08-25.

### A nested ObservableObject's changes don't reach views that observe only the parent
`CalendarAggregator.graph` is itself an `ObservableObject`. SwiftUI does not forward a nested object's `objectWillChange` to views that observe the parent, so a view holding only `@EnvironmentObject var aggregator` will not re-render when `graph.state` changes. `OnboardingView` works around it with child views that `@ObservedObject` the `GraphSource` directly (`MicrosoftStep`, `GraphCalendarsList`). When the parent itself needs the fact, mirror it instead: `CalendarAggregator.isGraphSignedIn` is a Combine `assign(to:)` mirror of `graph.$state`, added in 2.0.1 for the popover gate. Prefer mirroring over spreading child-view workarounds.

### The shipped binary carried a fourth entitlement that was not in the entitlements file (removed in 2.0.1)

`slapss/slapss.entitlements` lists three. `codesign -d --entitlements :- /Applications/slapss.app`
on an App Store build **up to 2.0.0** reports four: the extra one is
`com.apple.security.files.user-selected.read-only`, injected at build time by
`ENABLE_USER_SELECTED_FILES = readonly`, set in both configurations of the pbxproj.
No code path opens an `NSOpenPanel` or a `fileImporter`, so it was never used.

This matters more than its permission scope does. The privacy claim is "the
entitlements are the whole story", so a reader who runs `codesign` and counts four
against a document that says three has caught the project overstating, on exactly
the claim the open-sourcing was meant to make checkable. Found 2026-08-24 while
preparing a Show HN post, before anyone else found it.

2.0.1 sets `ENABLE_USER_SELECTED_FILES = NO` in both configurations — an explicit
`NO` rather than a deleted line, matching the neighbouring `ENABLE_RESOURCE_ACCESS_*
= NO` entries. Validated, not assumed: an ad-hoc-signed local **Release** build was
inspected with `codesign -d --entitlements :-` and reports exactly the three from
the entitlements file. `README.md` and `SECURITY.md` say three again and record
what older builds carried.

One report that will keep coming back: a copy someone builds themselves also
carries `com.apple.security.get-task-allow`, which Xcode adds to any
non-distribution build so a debugger can attach. App Store builds don't have it.
Both documents say so, because "I built it myself and I count four" is the obvious
next message.

**Superseded in part:** the entitlements file lists **four** as of the
new-browser-window work. `com.apple.security.automation.apple-events` was added
deliberately, and `README.md` / `SECURITY.md` were updated in the same change —
the count in those documents is load-bearing (see above), so anything that adds
or removes an entitlement has to move them too.

### The App Sandbox makes Apple events to ordinary apps impossible — this is why the app is no longer sandboxed

Measured 2026-09-01, on the ad-hoc-signed sandboxed build, with Safari running:

```
safari-by-id-activate    -> -600  Safari got an error: Application isn't running.
safari-by-name-activate  -> -600
finder-by-id-activate    -> -600  (Finder was running too)
sysevents                -> error=none                     <- succeeded
AEDetermine(askUserIfNeeded: true)  -> -600, no prompt shown
```

`-600` is `procNotFound`. TCC is never consulted when the target can't be
resolved, so **no Automation prompt is ever presented and no grant can exist** —
which is exactly how the bug was reported: "it opened in a reused window on the
external display, and I was never asked for permission." `BrowserWindowOpener`
then took its `NSWorkspace.open` fallback, which is correct behaviour for a
failure and is why the meeting still opened.

Three facts fix the cause on the sandbox and not on anything else. A sandboxed
process **can** send Apple events — System Events succeeded from the same binary.
Finder, unquestionably running, failed identically to Safari, so it is not
Safari-specific. And the error is `-600`, not `-1743`
(`errAEEventNotPermitted`) — `-1743` is what a TCC or code-identity refusal looks
like, and we never reach it. The pattern is that a sandboxed client may launch and
talk to a faceless helper like System Events but may not address an ordinary
running GUI app.

**Ad-hoc signing is not the cause and was ruled out**, which matters because it is
the obvious suspect: the same ad-hoc binary talked to System Events, and the
`kTCCServiceCalendar` grant survives a rebuild under an ad-hoc identity.

Confirmed by A/B on 2026-09-01 — same code, same ad-hoc signing, `ENABLE_APP_SANDBOX
= NO` the only variable:

```
DIAG newWindow script error = NONE (success)
windowCount BEFORE -> 1   AFTER -> 2
ALL window bounds -> [ [2, 32, 1922, 2162], [3840, 848, 5568, 1932] ]
TCC: com.cancetin.slapss | com.apple.Safari | 2        <- its own grant, prompt approved
```

So `ENABLE_APP_SANDBOX = NO` in both configurations and `com.apple.security.app-sandbox`
is gone from `slapss.entitlements`. **This diverges from the App Store build, which
is sandboxed**, and `README.md` / `SECURITY.md` say so — an unsandboxed app is not
confined by its entitlements, so that count stops being a boundary and becomes a
statement of intent. Do not quietly re-enable the sandbox to "fix" the entitlement
story: it silently kills the feature, with no error the user can see.

**When running the A/B, launch through LaunchServices (`open -a`), not the binary
directly.** TCC attributes an Apple event to the *responsible process*; a binary
started from a terminal is attributed to the terminal, so the first attempt
recorded `com.googlecode.iterm2 -> com.apple.Safari` and proved nothing about
slapss. Launched with `open -a`, slapss got its own grant.

**A sandboxed and an unsandboxed build read different preference domains.** The
sandboxed app reads `~/Library/Containers/com.cancetin.slapss/Data/Library/Preferences/`,
where `defaults write com.cancetin.slapss` is redirected; an unsandboxed build reads
`~/Library/Preferences/com.cancetin.slapss.plist`. Turning the sandbox off therefore
looks like every preference reset to its default. Worth knowing before diagnosing
"my settings vanished."

### The Automation grant is the whole cost of the browser-window feature — keep it earned

`BrowserPlacement.requiresAutomation(in:)` is the single place that decides
whether the user gets asked for anything. The rules it encodes are not arbitrary:

- Chromium takes `--new-window`, `--window-position` and `--window-size` as launch
  arguments, so **new window + built-in display on Chromium costs no permission at
  all**. Firefox takes `-new-window` (one dash) but has no geometry flags.
- Safari has no new-window flag. `make new document` via Apple events is the only
  route, which is why Safari — the case that had to work — needs the grant for
  either preference on its own.
- Moving a window that *already exists* is always an Apple event. No browser can
  position a window it isn't creating. So "built-in display" **without** "new
  window" needs the grant even on Chromium.
- **Firefox is never asked for the grant at all.** It ships essentially no
  AppleScript dictionary and has no scriptable `bounds`, so the event would cost a
  permission and then fail. `supportsWindowPlacementScript` is false for it,
  `isFullySupported(in:)` returns false, and Settings says the browser can't be
  positioned instead. Positioning Firefox would need the Accessibility API — a
  different, heavier grant this feature deliberately does not ask for.

Two consequences worth not relearning:

- The Settings toggles ask about the placement that would *result* from the flip,
  not the one being flipped (`SettingsView.placement(enabling:)`). Turning on "new
  window" while "built-in display" is already on can *remove* the need for the
  grant on Chromium.
- Permission state is read with `AEDeterminePermissionToAutomateTarget(…,
  askUserIfNeeded: false)`. That variant never raises the system prompt, which is
  what makes it safe to call every time the Settings window appears. Pass `true`
  and merely opening Settings would ask the user for Automation access.

Every failure path — no grant, grant refused, browser launch failed, script error
— ends in a plain `NSWorkspace.open`, and exactly one of them runs: the URL is
opened in the script's completion handler, never both by the script and by the
fallback.

**Making the window and placing it must travel as one script.** Sent as two,
`front window` in the second is whatever the browser has in front by then —
measured 2026-09-01, that was the user's *pre-existing* page, so the wrong window
moved to the built-in display while the meeting stayed put. `newWindowScript`
takes the bounds and emits `make new document` followed by `set bounds of front
window` inside a single `tell` block; `NewWindowScriptTests` holds that ordering.
The separate `placeFrontWindow` path remains only for reusing an existing window,
where "whichever window the browser used" is the defined behaviour.

**Apple events must never be sent on the main thread here.**
`NSAppleScript.executeAndReturnError` is synchronous and exposes no timeout, and
the *first* send is also when macOS presents the Automation consent dialog. A join
happens while the full-screen overlay is up — a borderless `.screenSaver`-level
window covering every display — so blocking main freezes the overlay with no way
out: ESC and Return are handled on that run loop, and so are `AlertScheduler`'s
timers and watchdog. `BrowserWindowOpener.runScript` therefore sends on a private
serial queue and calls back on the main actor. This is the same family of problem
as the "Overlay controls that expand must stay inside the overlay window" gotcha
above.

### AppleScript window `bounds` and `NSScreen.frame` disagree on origin *and* y direction

AppleScript's window `bounds` (and Chromium's `--window-position`, which uses the
same space) measure from the **primary display's top-left**, y growing downward.
`NSScreen.frame` measures from the **primary display's bottom-left**, y growing
upward. A display arranged below the primary one therefore has a negative
`frame.origin.y` in AppKit and a large positive `top` in AppleScript.

Measured on the development machine 2026-09-01: the Dell U4320Q is primary at
`(0, 0, 3840, 2160)` and the built-in panel sits to its **right and raised**, at
`frame (3840, 228, 1728, 1117)` / `visibleFrame (3840, 228, 1728, 1085)`. The
shipped code turns that into `{3840, 847, 5568, 1932}` — `top = 2160 - (228 +
1085)`. Both axes are non-zero, which is why
`testRealMeasuredTwoDisplayArrangement` exists alongside the synthetic fixtures: a
conversion that silently dropped one axis still passes the others. Flipping the
sign parks the window off-screen, or on the very monitor the user turned the
preference on to avoid. The conversion is `ScreenPlacement.windowBounds(for:
primaryFrame:)`, kept pure and covered by `slapssTests/ScreenPlacementTests.swift`
against that real arrangement plus side-by-side, single-display and Dock-inset
cases.

Two related details:

- The anchor is the **primary** display (the one whose frame origin is `.zero`),
  **not** `NSScreen.main` — `main` is the screen with the key window, so it moves
  as the user clicks around and is nil when nothing is key.
- The built-in panel is identified with `CGDisplayIsBuiltin` on the screen's
  `NSScreenNumber`, which is public API and needs no permission.


## Versioning

- `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` live in `slapss.xcodeproj/project.pbxproj` (two occurrences each — Debug + Release).
- **Only `MARKETING_VERSION` matters for a release.** Bump both its occurrences together, and always ask Can for the number first.
- **`CURRENT_PROJECT_VERSION` is dead weight.** Xcode Cloud assigns the build number itself, sequentially per product, and overrides whatever the project says. The committed value reads `15` while App Store Connect has already delivered build 17 and is on 19 next. Don't bump it, and don't trust it — the real counter lives in App Store Connect → Xcode Cloud → Settings → Build Number.
- Current version: **2.0.1**
- The tree is **not sandboxed** as of the browser-window work; the App Store build is. See the App Sandbox gotcha before changing `ENABLE_APP_SANDBOX`.

---

## Changelog log

Brief record of what shipped in each version. Full user-facing changelog is in `slapss-web/changelog.html`.

- **Unreleased (version number is Can's call; `MARKETING_VERSION` deliberately left at 2.0.1)** — Two independent, default-off preferences for how a join link opens: `openMeetingsInNewWindow` and `openMeetingsOnBuiltInDisplay` (`AppSettings`, new "Joining meetings" section in `SettingsView.generalTab`, 9 new keys ×6 languages incl. `general.cancel`). Resolved into one `BrowserPlacement` value and threaded through `MeetingURLOpener.open(_:authUser:placement:)`, whose new third parameter defaults to `.browserDecides` — i.e. the old `NSWorkspace.open`, so nothing changes until a user opts in. All three join call sites pass it: `ContentView.JoinButton`, `AlertScheduler.handleJoin`, and `AppDelegate`'s notification Join action, which has no SwiftUI environment and so reads `AppSettings.persistedBrowserPlacement()` straight from UserDefaults (same constraint that makes it build its own `LocalizationManager`). The `msteams://` branch is untouched on purpose: a native Teams window is not a browser window. — Design deliberately splits pure from impure: `BrowserPlacement` + `BrowserFamily` (which browser, which route, does it cost a permission) and `ScreenPlacement` (built-in selection, coordinate conversion) are `nonisolated` value logic with 38 unit tests; `BrowserWindowOpener` is the only file touching NSWorkspace/NSScreen/NSAppleScript. Browser is detected via `urlForApplication(toOpen:)` on an https probe and classified by bundle-identifier **prefix**, so beta/canary/nightly channels and Chromium forks (Brave, Edge, Vivaldi, Opera, Arc) resolve without an exact-match list — Safari is never hardcoded. — **New TCC surface, and the first in this app:** `com.apple.security.automation.apple-events` added to `slapss.entitlements` plus `NSAppleEventsUsageDescription` in `Info.plist`. See the two new gotchas for why it can't be avoided for Safari and why Chromium avoids it entirely. `README.md` and `SECURITY.md` moved from "three entitlements" to four in the same change — that count is load-bearing (2.0.1's whole point). The grant is requested at first use by the user, not at launch: switching a toggle on raises an in-app explanation alert first, and the OS prompt follows on the next join. **This is a Mac App Store app, so the entitlement is a review-risk decision, not just a code change — Can's call before submission.** — **Test target added** (`slapssTests`, `com.apple.product-type.bundle.unit-test`, hosted by the app, wired into the shared scheme). The same target already exists on the unmerged local branch `diagnostic-overlay-logging`; the pbxproj objects here are byte-identical to that branch's on purpose, so whichever lands second merges instead of producing two targets. — Also added `SystemSettingsOpener.openAutomationPrivacy()` for the denied state, and a CI `Test` lane in `.github/workflows/build.yml` so the new target actually runs. — **Self-review pass changed four things in the code, not just the prose:** Apple events moved off the main thread (see the gotcha — this was a frozen-overlay bug, not a style point); the URL is now opened exactly once, in the script completion, so a failed script can't double-open or silently skip; `open()` bails out when the browser's bundle identifier can't be read, so the plain path runs instead of reporting success for work that never happens; and Firefox stopped being asked for a grant it can't use. The Chromium launch-argument route (`NSWorkspace.openApplication` with `createsNewApplicationInstance` + `arguments`) remains **unverified** — but with the sandbox off it is no longer the only thing that can work, and the development machine's default browser is Safari, so it stays off the critical path (Can's call, 2026-09-01). It is still worth keeping: it is the one path that costs a Chromium user no permission at all. Superseded note, kept because the reasoning matters: while the tree was sandboxed this route was briefly the *only* possible one, since Apple events were impossible — see the App Sandbox gotcha. Original wording: `arguments` from inside the sandbox is **unverified** — it needs a Chromium browser, and the development machine's default is Safari, so it is off the critical path (Can's call, 2026-09-01). — **Validated on real hardware 2026-09-01, ad-hoc-signed Release build installed over `/Applications/slapss.app`:** `codesign -d --entitlements :-` reports the four from the entitlements file plus `get-task-allow` (local-build only, as `README.md` already documents); `files.user-selected.read-only` is gone, confirming 2.0.1's `ENABLE_USER_SELECTED_FILES = NO`. The `kTCCServiceCalendar` grant **survived** replacing the bundle — an ad-hoc identity does hold TCC grants across a rebuild here, which is worth knowing before anyone assumes a local build needs re-authorising. `ScreenPlacement` was run against the live `NSScreen` arrangement (see the coordinate gotcha for the numbers) and produced the correct built-in-display bounds. **Not** validated: the Safari Apple event itself — sending it needs a click on Join, which cannot be scripted without the Accessibility grant this feature deliberately avoids. **`slapss-web/changelog.html` NOT mirrored** — separate private repo, not present in this worktree; owed before release.
- **v2.0.1 (Can's call: patch bump)** — **User-reported bug (email, 2026-08-25):** a Microsoft 365 user who had not granted macOS Calendar access saw the menu bar counting down to the next meeting, but the popover showed the red "Calendar access denied" state instead of the agenda. `MenuBarContentView.regularView` switched on `aggregator.permissionState`, which is EventKit-only, while the menu-bar label reads `scheduler.currentMenuBarMeeting` off the merged event list — that asymmetry is why the two surfaces disagreed and why it read as "the agenda is broken" rather than "a permission is missing". The gate now short-circuits on `aggregator.isGraphSignedIn`, the same rule `OnboardingView.canFinishOnboarding` has had since 1.8. Settings needed no change: its denied state, with the "Open System Settings" button, was already scoped to the macOS-calendars section, and that remains the place to fix the permission. `isGraphSignedIn` is a new `@Published` on the aggregator mirroring `graph.$state` through Combine `assign(to:)`, **not** folded into `graph.onChange` — that callback fires only on completed sign-in and sign-out, so an expired-token `.error` would leave the flag stuck at `true` (see the nested-ObservableObject gotcha). — **Second fix, in the same file:** `GraphSource.startPollTimer` was the codebase's last `Timer.scheduledTimer` (`.default` runloop mode, App Nap-throttled); converted to `Timer(...)` + `RunLoop.main.add(_:forMode: .common)`. Highest impact for Microsoft 365-only users, whose EventKit safety-net poll never starts at all. The file header also claimed a 5-minute cadence while the timer has been 2 minutes since it was written — corrected. — **Third change:** `ENABLE_USER_SELECTED_FILES = NO` in both configurations, dropping the unused fourth entitlement from the shipped binary (see the entitlement gotcha); `README.md` and `SECURITY.md` are back to three. — No user-facing string changed, so `Translations.swift` is untouched and the six-language rule doesn't apply this time. **Validation:** `xcodebuild build` succeeded (local Xcode 27 beta; CI runs macos-26), and an ad-hoc-signed **Release** build was inspected with `codesign -d --entitlements :-` — three entitlements, as documented. The popover fix is **not** hand-validated: it needs a Mac with a signed-in Microsoft 365 account *and* calendar access denied, which this machine can't produce. Can to confirm before submitting. `MARKETING_VERSION` 2.0.0 → 2.0.1 (both configurations); `CURRENT_PROJECT_VERSION` untouched, Xcode Cloud owns it.
- **v2.0.0 (Can's call: major bump marks the open-source release)** — **Bug fix, found in pre-release user feedback:** recurring meetings stopped alerting permanently after their overlay was dismissed once. `EKEvent.eventIdentifier` is shared by every occurrence of a series, so the single `dismissedIDs` entry suppressed the whole series while the menu-bar countdown kept rendering normally (it reads the aggregator, which has no dismissal filter) — which is exactly why it read as "the first meeting of each day never fires" rather than as a dismissal problem. `toMeetingEvent` now qualifies the id with the occurrence start epoch; `eventKitIdentifier` strips it back off for the `ical://` scheme. Same fix repairs snooze and menu-bar-mute leaking across occurrences. Graph unaffected. — Repository published at `theshiver/slapss-app` under Apache-2.0; see `RELEASING.md` for the process that now spans four surfaces. Only code change is a `settings.about.sourceCode` row in `SettingsView.aboutTab`, matching the existing website/support `LabeledContent` + `.buttonStyle(.link)` pattern, localized in all 6 languages. Placed in About deliberately: that tab is where a user goes to check a privacy claim, and onboarding is for setup, not links. This also keeps 2.0.0 from being a pure label — without it the build would be byte-identical to 1.8.2. `MARKETING_VERSION` 1.8.2 → 2.0.0 (both configurations); `CURRENT_PROJECT_VERSION` untouched on purpose, Xcode Cloud owns it (see Versioning).
- **v1.8.2** — Fixed the full-screen alert's Snooze button appearing to do nothing on macOS 27 beta 3. The duration picker no longer uses SwiftUI `.popover` (a separate system-managed window that can be suppressed behind the app's borderless `.screenSaver`-level overlay); it is now an in-window dropdown rendered inside `AlertView`. Snooze scheduling behavior is unchanged. Fixed the macOS calendar catalog staying stale after a Calendar account was removed and re-added while Slapss remained open: `CalendarAggregator` now fingerprints and refreshes the EventKit catalog on store-change notifications, the 30-second safety-net, Settings appearance, and app reactivation. Permission changes are re-read on the same paths. Calendar-selection persistence is intentionally untouched: empty still means all calendars, while an explicit non-empty ID set remains explicit even if an account re-add changes identifiers, so newly discovered calendars are not silently enabled. Catalog publishing remains deduplicated to avoid unnecessary SwiftUI/scheduler work; the repeating safety-net timer now runs in `.common` mode.
- **v1.8.1 (UX review pass, Can's call: stays on 1.8.1, no version bump)** — Design-critique fixes across all four surfaces. **Popover:** agenda area now scrolls — `regularView` wraps the permission/agenda switch in a `ScrollView` whose height tracks measured content via `.onGeometryChange` (requires Xcode 16 SDK; back-deploys fine) up to `MenuBarContentView.agendaMaxHeight = 560pt`, header/footer stay pinned; short days render identically to the old intrinsic layout. `AgendaRow.expanded` lifted from local `@State` to `MenuBarContentView.expandedEventIDs: Set<String>` (binding via `expandedBinding(for:)`) so the reworked `NoUpNextLine` — now a real Button with hover fill + rotating chevron — can toggle the referenced meeting's row. `HideReminderBar` moved from above the hero into `agendaSections` below the hero (secondary action, shouldn't own the top slot). Reminder-complete button hit area widened to ~24pt with the `.padding(6).contentShape(Rectangle()).padding(-6)` trick (no layout shift). Header date now uses `setLocalizedDateFormatFromTemplate("EEEMMMd")` so element order follows the locale (TR: "13 Tem Pzt"). `TickClock` switched off `Timer.scheduledTimer` to the `.common`-mode pattern (per the App Nap gotcha — the menu bar counter froze while menus were open). **Overlay:** Join/Complete CTA is now themed — `AppTheme.Accents` gained `overlayCtaTop/Bottom` (sunset orange 0xE8732A→0xC2571F, ocean blue, forest green; was hardcoded green 0x2da14a for all themes — note sunset users see orange now, Can approved). New `keyboardHint` line under the actions ("↩ Join · esc Dismiss", reuses existing action-label keys, ↩ half hidden when no primary button). Status pill now says MEETING for calendar events (new `alert.status.meeting` key ×6 languages); REMINDER only for EKReminders. **Settings:** caption rows added under the lead-time picker, the overlay slider, and `onlyAcceptedMeetings` (new keys `settings.leadTime.caption`, `settings.alert.showEarly.caption`, `settings.alert.onlyAccepted.caption` ×6); Calendars tab no longer dead-ends without permission — mirrors the popover's notDetermined/denied states with request/System Settings buttons. **Onboarding:** step badge numbers computed from `visibleSteps` (`StepID` enum) instead of hardcoded — previously showed gaps (1,2,3,4,6,7,8) when the Microsoft or calendar-picker step was hidden; `MicrosoftStep` now takes `number:` as a param. Numbers renumber live when a gated step appears — intended. Overlay `timeString` intentionally stays on the system locale (12/24h preference); only date *words* follow `lm.language`. **Post-review fix:** Settings window opened BEHIND other apps' windows — since macOS 14 `NSApp.activate(ignoringOtherApps:)` is *cooperative* (may be deferred/ignored) and nothing else forces an accessory app's new window front. `MenuBarContentView.bringSettingsWindowToFront()` runs one tick after `openSettings()` (when the window is registered in `NSApp.windows`), finds it by identifier `contains("Settings")` — the observed-but-undocumented `com_apple_SwiftUI_Settings` — with a titled-visible-non-onboarding structural fallback, then `makeKeyAndOrderFront` + `orderFrontRegardless`. The right-click context menu's Preferences item now routes through the same `openPreferences()` instead of duplicating the open logic.
- **v1.8.1** — Overlay lead time rebuilt as a **discrete slider** (fourth design; Can rejected the TextField+unit-Picker version on UX grounds after it briefly landed — the three earlier iterations were an extended dropdown, a preset-list+stepper, and the field+unit picker, all in git history). The "Show alert:" row in `SettingsView` (Alert section) is a `LabeledContent` containing a right-aligned `VStack`: a live secondary-text label ("30 seconds before" / "5 minutes before" / "At meeting start") above a 200pt `Slider`. The slider has 17 evenly spaced detents — `SettingsView.overlayLeadSteps = [0, 30] + (1...15).map { $0 * 60 }` — i.e. at start, 30 s, then 1–15 whole minutes (15 min is Can's cap for the full-screen alert). Key design point: the `Binding<Double>` maps slider position to a step *index*, not seconds, so detents stay uniform even though the value space isn't linear. Still backed by the same `overlayLeadTimeSeconds: Int` setting, so `AlertScheduler.scheduleStart` needed no change. Legacy stored values that don't fall on a detent (e.g. 45 s free-typed in the short-lived field design) snap to the *nearest* step on read (`overlayLeadStepIndex`) — derive-on-read, no migration. The live label doubles as `accessibilityValue` on both the slider and the row, satisfying Can's standing requirement that a number is never shown or announced without its unit. Localization: the slider reuses the existing `settings.alert.early.{0,secondsFormat,minutesFormat}` keys; the now-unused `early.{secondsUnit,minutesUnit}` keys were removed from all 6 languages. Onboarding untouched — it only has the *notification* lead picker (`leadTimeMinutes`), not the overlay one. Originally prompted by user feedback: someone needed a longer walk-to-room lead than the old 1-min max.
- **v1.8** — Theme support (Can's call: ships as part of 1.8, no version bump): `AppTheme` (sunset = original look and default, ocean, forest) persisted as `AppSettings.theme`; accent tokens moved from static `Tokens` to `AppTheme.Accents` consumed via `settings.theme.accents` (see gotcha); overlay `MeshBackground` palette now theme-driven (previously hardcoded `.sunset` in the removed `AlertState.palette`), passed by value through `OverlayWindowController.show(theme:)`; `ThemeSwatchPicker` in Settings (new Theme section under Language) and onboarding (new step 2, later steps renumbered 3–8); theme names + picker strings localized in all 6 languages; onboarding `NumberBadge`'s hardcoded brown ink replaced with themed `pillInk` (same value in sunset). Plus UX pass (13 items): manual "Presenting Now" toggle (`AlertScheduler.presentingModeEnabled`, footer + status-menu item) suppresses/queues the overlay instead of Focus-based detection (entitlement risk, see gotcha above); lead-time notifications gained a localized "Join" `UNNotificationAction` (`NotificationManager.registerCategories`, handled in `AppDelegate`); overlay responds to Return/Enter via `OverlayWindow.onPrimaryAction`; permission-denied states (popover + onboarding + settings) got a one-click "Open System Settings" button (`SystemSettingsOpener`); onboarding's Get Started no longer requires EventKit permission when Microsoft 365/Exchange is signed in; `StatusMenuController` and `NotificationManager` fully localized (previously hardcoded English); agenda row expand/collapse rebuilt as a real `Button` sibling to the reminder-complete button (was nested inside an `onTapGesture`, invisible to VoiceOver/keyboard) plus a cursor fix; popover header date now locks its `DateFormatter` to `lm.language` instead of system locale; Settings split "About" into its own tab; overlay glass card respects Reduce Transparency; new "Open in Calendar" button on agenda rows (`MeetingEvent.eventKitIdentifier`, `MeetingURLOpener.openInCalendar` — undocumented URL scheme, see gotcha); empty-agenda state redesigned with icon + subtitle; duration strings ("30m" / "1h 15m") localized — `MeetingEvent.durationString` changed from a computed property to `durationString(lm:)` since the model has no environment access, using new `duration.hoursMinutes` / `duration.hoursOnly` / `duration.minutesOnly` format keys (`relativeStartString` is unused elsewhere and was left as-is). Post-release addition (Can's call: stays on 1.8, no version bump): menu bar icon now uses the Slapss brand mark (fist + motion lines) instead of the SF Symbol bell fallback — added `MenuBarIcon.imageset` (1x/2x PNG, `template-rendering-intent: template` in Contents.json) to `Assets.xcassets`, generated as a monochrome silhouette cropped from `AppIcon.appiconset/icon_512x512.png`. No Swift changes needed: `MenuBarLabel.menuBarLogoImage` (ContentView.swift) already looked up `NSImage(named: "MenuBarIcon")` and set `isTemplate = true`, so it was only ever missing the asset. Template rendering means macOS recolors it automatically for light/dark menu bars — no manual dark-mode handling required.
- **v1.7** — `onlyAcceptedMeetings` setting (default off): overlay filter that skips meetings the user marked tentative/declined; `rsvp` added to `MeetingEvent`, populated from Graph `responseStatus.response` and EventKit `participantStatus` (via the `isCurrentUser` attendee); filter is scheduler-only so tentative meetings still show in the agenda. Missed-fire staleness grace: `fireMeetingStart` skips meetings whose effective start was missed by more than 10 min (fixes the morning overlay flood after overnight sleep), measured from effective start so snooze re-fires aren't suppressed.
- **v1.6** — Background CPU fix: `PopoverVisibilityMonitor` gates animations on real popover visibility; Reduced Motion accessibility support in all animated views (`BlobsBackground`, `FloatingDotsBackground`, `MeshBackground`, `PulsingDot`, hero pill); "1 minute before" option added to overlay lead time picker; About section: personal email removed, website (slapss-app.com) and support (info@slapss-app.com) added; version display shows only marketing version without build number; onboarding: language selection added as step 1, "1 minute" option added to lead time picker, all step numbers updated
- **v1.5** — Full-screen overlay for Reminders; in-app reminder completion from overlay and popover
- **v1.4** — Multi-language support (6 languages); expandable agenda rows; configurable overlay lead time; CPU leak fix in `refreshEventKitOnly`
- **v1.3** — Calendar filter seeded at launch (bug fix); hero/menu-bar consistency; Google Meet `authuser` per calendar; multi-display overlay; optional menu-bar text
- **v1.2** — Menu bar fallback icon changed from hand to bell; full-screen card layout fix; ESC to dismiss overlay
- **v1.1** — Alert scheduling reliability (App Nap, watchdog, missed-fire recovery, pending queue); mirrored text fix
- **v1.0** — Initial release
