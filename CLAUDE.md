# Slapss — Claude Project Context

macOS menu bar app (SwiftUI + AppKit hybrid). Shows meetings from macOS Calendar / Exchange and fires a full-screen overlay alert at meeting start. Can Cetin's upstream is distributed via the Mac App Store; this fork is built and installed locally and does not submit to the App Store.

Two repos:
- `slapss-app` — macOS app (this repo). David's fork: `origin` = `djnesmith/slapss-app`, `upstream` = `theshiver/slapss-app` (Can Cetin's original — **public**, Apache-2.0, and where the App Store build comes from). `main` tracks `origin/main` in git; it is kept in step with `upstream/main` by merge, for parity so bug fixes are never missed, and version numbers follow upstream's. See `CONTRIBUTING.md`.
- `slapss-web` — Can's marketing site on Cloudflare. **Private**, not published, and not checked out on this machine (see Rules). The user-facing changelog is served from it at <https://slapss-app.com/changelog.html>.

`CHANGELOG.md` in this repo is the source of truth for user-facing release notes; `changelog.html` and GitHub Releases are copied from it. `ENGINEERING-LOG.md` is the separate engineering record — different audience, keep both.

---

## Rules

- **Never bump version numbers without asking David first.** He decides the version.
- **`RELEASING.md` describes Can's upstream release process** (App Store, tag, GitHub Release, marketing site). This fork does not ship through it: releases here are local builds, and version numbers follow upstream's for parity. Don't run its Xcode Cloud / App Store steps from here.
- **After every user-visible change, update `CHANGELOG.md` first**, and record the engineering detail in `ENGINEERING-LOG.md`. No exceptions.
- `slapss-web` (the marketing site, separate private repo) is **not checked out on this machine**. When a change needs the user-facing changelog or privacy/terms mirrored there, say so and stop — do not treat the mirror as a step you can complete.

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
| `PopoverVisibilityMonitor` | Tracks real popover open/close via NSWindow key and occlusion notifications |

### Key files
- `ContentView.swift` — popover UI (hero card, agenda, `JoinButton`, `RowJoinButton`), plus the shared `glassSurface` and `Tokens.edgeTop/edgeBottom`
- `AlertView.swift` — full-screen overlay card
- `OverlayWindowController.swift` — manages the screen-saver-level `NSWindow`(s) hosting `AlertView`
- `AlertScheduler.swift` — all scheduling logic, App Nap, watchdog, missed-fire recovery
- `CalendarAggregator.swift` — merge + poll loop
- `EventKitSource.swift` — EventKit fetch (Calendar + Reminders)
- `GraphSource.swift` — Microsoft Graph fetch (Exchange)
- `AppSettings.swift` — all `@Published` preferences + UserDefaults persistence
- `PopoverVisibilityMonitor.swift` — NSWindow key + occlusion observer (the hidden popover never sends `willClose`)
- `Theme.swift` — `AppTheme` (sunset/ocean/forest) + `AppTheme.Accents` color sets + `ThemeSwatchPicker` (shared by Settings and Onboarding) + `meshCard` / `ctaFill`
- `DemoMode.swift` — Debug-only demo data / overlay / popover launch flags (see the demo-mode gotcha)
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
- Use `PopoverVisibilityMonitor.isVisible` instead. It must watch **occlusion**: the hidden window never sends `willClose` either, and until 2.2.0 the monitor relied on it, so `isVisible` stuck at true after the first open.
- Gating isn't enough on its own. A `.repeatForever` curve also loops on the way *back* (value → false), so give the "off" direction a finite animation; and a `repeatForever` rotation survived opacity 0 and a nil animation, so remove such a view from the hierarchy when inactive (`GlowRing` does). Check with the demo mode: open and close the popover and read `ps -o %cpu`, which should drop to 0.

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

### Overlay motion: spin with Core Animation, don't redraw per frame
The overlay is full-screen, possibly on several displays, so any per-frame redraw costs real CPU. The first 2.2.0 `GlowRing` recomputed and re-blurred an `AngularGradient` inside a `TimelineView` and doubled the app's CPU in the live state; spinning a fixed gradient with a `repeatForever` rotation under a mask fixed it. `MeshBackground`'s `TimelineView` is the one deliberate per-frame redraw (20 fps, paused under Reduce Motion). Measure with the demo overlay before adding another. Also: `hide()` fades windows out *before* teardown and empties `windows` first. Keep that ordering, or a `show()` arriving during the fade gets its fresh windows torn down.

### Debug demo mode, and what an unsigned Debug build does to your settings
`DemoMode.swift` (Debug builds only) has two launch flags: `-SlapssDemoData <seconds>` replaces the calendar with a fixed demo day (hooked into `CalendarAggregator.start/performRefresh/refreshEventKitOnly`; the real scheduler runs on it, so its overlay fires too), and `-SlapssDemoOverlay <seconds>` shows the alert for a fake meeting (negative = live/late). Either flag skips onboarding. Theme and language come from UserDefaults' argument domain (`-slapss.theme forest`, `-slapss.appLanguage tr`). Numbers are parsed by hand, because the argument domain reads `-297` as the next flag.

**The popover can't be opened from inside the app.** The MenuBarExtra's `NSStatusBarButton` has no target/action, and SwiftUI ignored `performClick`, NSEvents (sent or posted), and a CGEvent posted to our own pid. It needs a real click on the icon. With demo data on, each open prints `SLAPSS_POPOVER_WINDOW <id>`, and `screencapture -o -l <id>` then captures only the popover. The app also owns several `NSStatusBarWindow`s parked off-screen at y = -33, so a status-window search has to filter on screen position.

`-SlapssDemoPopover` (with demo data) also shows the popover content in a borderless window under the menu bar, capturable with no click; its chrome is approximated. After an icon change, a Debug build may still show the old icon in the popover header and onboarding: LaunchServices caches it per bundle id. `lsregister -f <app>` on the built app fixes it.

For video, record the demo app's windows with ScreenCaptureKit (`SCContentFilter(display:including:[app])`), not `screencapture -v`: it starts before the alert window exists, so the entrance is caught, and it works with the screen locked. The tool and the store/site render scripts live in the workspace's `store-assets/<version>/tools`.

**In this fork a demo run uses the real app's settings.** Upstream's note here says an unsigned Debug build escapes the sandbox, writes a stray `~/Library/Preferences/com.cancetin.slapss.plist`, and that you should delete it afterwards. That is backwards for this fork: the installed app is unsandboxed and **that plist is where it keeps David's settings**. Never delete it. Every build of this tree, signed or not, Debug or Release, shares the bundle id `com.cancetin.slapss` and so reads and writes that same domain.

`DemoMode.swift` itself writes nothing: demo meetings replace the fetch, and the onboarding skip is assigned in `init`, where `didSet` does not persist. What can still write is the ordinary app code running alongside it. Changing any setting in the demo writes through `didSet`, and `LocalizationManager` stores a detected language on first run. `-slapss.theme` / `-slapss.appLanguage` launch arguments go into the argument domain and are not written back. Before a demo run, back the settings up with `defaults export ~/Library/Preferences/com.cancetin.slapss.plist <file>` and restore them afterwards with `defaults import ~/Library/Preferences/com.cancetin.slapss.plist <file>`. Name the plist by path: the bare domain `com.cancetin.slapss` resolves to the old sandbox container (see the next-but-one gotcha), which is not what this build reads. Use `defaults`, not `cp`, because `cfprefsd` caches the plist and a copied file can be overwritten from its cache.

### `@Published` emits before the property changes
A `settings.$foo.sink` runs in `willSet`: inside it, `settings.foo` still holds the **old** value. `AlertScheduler`'s settings sinks call `reschedule`, which reads `settings`, so a change there applies only on the next 30-second poll. Harmless so far, but a sink that must act on the new value immediately needs the value passed in, or `.receive(on: DispatchQueue.main)` (as `$alertExcludedKeywords` has since 2.2.1).

### Testing a Debug build while another copy runs
Two running processes named `slapss` confuse System Events: it resolves both to the first pid, so AppleScript/JXA reads and clicks land in the wrong app, and ⌘, goes to whichever is frontmost. Quit the other copy first. Also: `defaults read/write/export com.cancetin.slapss` (the bare domain) targets the sandbox container `~/Library/Containers/com.cancetin.slapss` once one exists, not `~/Library/Preferences/com.cancetin.slapss.plist`, which every build of this unsandboxed fork reads. A container left by earlier sandboxed builds still exists on David's machine, so the bare domain returns stale values there; pass the plist path instead. To try a value in a Debug build without writing David's real settings, seed it through the argument domain (`-slapss.alertExcludedKeywords '(Lunch, "Focus time")'`; quote anything with a space or the whole value silently parses as a string).

### One design language since 2.2.0, built from three shared pieces
The alert, popover, onboarding and Settings share: `meshCard(theme:cornerRadius:energy:animating:)` and `ctaFill(_:cornerRadius:enabled:)` (Theme.swift), and `glassSurface(cornerRadius:fill:)` + `Tokens.edgeTop/edgeBottom` (ContentView.swift). New surfaces should use these rather than restyling locally. The mesh appears only on "brand moment" cards (popover hero, onboarding welcome, About banner, theme swatches); lists stay calm. Settings keeps the native grouped `Form` on purpose. Every animated mesh takes an `animating` flag tied to real visibility: `PopoverVisibilityMonitor` in the popover, `controlActiveState == .key` in windows.

### The app icon is an Icon Composer file
`slapss/AppIcon.icon` (hand-written `icon.json` + `Assets/`), no `.appiconset`. Xcode 26 compiles it into a layered Liquid Glass icon for macOS 26 and flattened images for older systems, so it needs no deployment-target change. Edit it in Icon Composer (Xcode → Open Developer Tool) and rebuild; check `Assets.car` with `assetutil --info` for both `IconGroup` and `Icon Image` renditions.

### Calendar filter is not auto-seeded at launch
`CalendarAggregator.start(enabledEventKitCalendars:enabledGraphCalendars:)` must receive the persisted selection from `AppSettings` to seed the source filters before the first fetch. An empty set in `EventKitSource` means "all calendars."

### MenuBarExtra window identification
`menuBarExtraWindows()` identifies the popover window by three properties: no `.titled` style mask, level above `.normal`, and top edge near the menu bar. This same heuristic is used by `PopoverVisibilityMonitor`. Don't change one without the other.

### Presenting Now is intentionally manual, not detected
v1.8 originally scoped "suppress the overlay while screen sharing" using `INFocusStatusCenter` (Focus/DND detection). Abandoned before implementation: that API requires a restricted `com.apple.developer.focus-status` entitlement that needs separate approval from Apple (like CarPlay), not a self-serve Xcode capability — too risky to gate a shipping feature on. There is also no reliable *public* API to detect "this screen is being captured by another app" on macOS (Zoom/Teams/Meet each implement capture differently). Shipped instead as `AlertScheduler.presentingModeEnabled` — a session-only (never persisted) manual toggle. Every `fireMeetingStart` call is redirected into `pendingAlerts` while it's on, using the same FIFO that handles back-to-back meetings, and drained via `togglePresentingMode()` when switched off. If Apple's Focus Status entitlement becomes self-serve in the future, revisit — it would be a strictly better UX than remembering to flip a toggle.

### StatusMenuController is localized via a borrowed weak reference
`StatusMenuController` is a plain AppKit singleton instantiated before any SwiftUI environment exists, so it can't use `@EnvironmentObject`. It holds `weak var lm: LocalizationManager?`, wired once from `MenuBarContentView.onAppear` (same pattern already used for `onOpenPreferences`). If `lm` is nil (a right-click landing before the popover's first appearance), menu strings fall back to English literals rather than crashing.

### EventKit reuses one identifier for every occurrence of a recurring event

`EKEvent.eventIdentifier` is identical for Monday's stand-up and Tuesday's, so `toMeetingEvent` appends `"#<occurrence-start-epoch>"` to `MeetingEvent.id`. Without the suffix everything keyed by that id (`dismissedIDs`, `snoozeUntil`, `menuBarMutedIDs`, `scheduledEffectiveStart`) treats a whole series as one item: `dismissedIDs` is **insert-only and never cleared**, so dismissing one occurrence silences every future one, while the menu-bar countdown (which reads `aggregator.upcomingMeetings` with no dismissal filter) keeps looking correct. Microsoft Graph was never affected: `calendarView` expands series into per-occurrence objects with distinct ids.

Consequences:
- A detached instance moved to a different time gets a new id. That's intended — it's a different slot and deserves its own alert.
- `dismissedIDs` grows by roughly one entry per dismissed occurrence over long uptimes. Deliberately **not** pruned against the current meeting set: a transient EventKit fetch hiccup would resurrect an alert the user already dismissed, which is worse than a set of short strings.
- `eventIdentifier` can still be nil, in which case the id falls back to a fresh `UUID()` on every fetch. Pre-existing and untouched; only affects unsaved events.

### `eventKitIdentifier` parses the `id` prefix AND the occurrence suffix — don't change either scheme without updating it
`MeetingEvent.eventKitIdentifier` (used by "Open in Calendar") strips both the `"ek:"` prefix and the trailing `"#<occurrence-epoch>"` that `EventKitSource.toMeetingEvent(_:EKEvent)` puts on the `id`. It uses `lastIndex(of: "#")` so an identifier that itself contains `#` survives intact. It intentionally does NOT add a new stored property for this — if `EventKitSource`'s id-prefixing convention (`"ek:"` / `"reminder:"`) ever changes, this computed property needs to change with it.

### "Open in Calendar" uses an undocumented URL scheme
`MeetingURLOpener.openInCalendar` opens `ical://ekevent/<identifier>`. This is **not** a public Apple API — it's a widely-reported-working but undocumented Calendar.app URL scheme. If it silently stops working after a macOS update, this is why; there's no public alternative as of this writing.

### Themed colors go through `settings.theme.accents`, not static Tokens
The accent layer (mesh card bases, pill, hero tints, the gradient CTA) lives in `AppTheme.Accents` (Theme.swift) and is read as `settings.theme.accents.<name>` via `@EnvironmentObject var settings`. Do NOT reintroduce these as `Tokens` statics: SwiftUI skips re-rendering sub-structs whose stored inputs didn't change, so a static-token color swap doesn't reliably propagate — the ObservableObject path does. Neutral surfaces/ink stay in `Tokens` and are intentionally theme-independent; light/dark remains a separate axis handled inside each `Accents` color via dynamic NSColor providers. The full-screen overlay can't use the environment (see AppKit gotcha above), so `AlertScheduler` passes `settings?.theme ?? .sunset` by value into `OverlayWindowController.show(theme:)` at fire time — a theme change while an overlay is up applies from the next alert. The overlay mesh maps sunset→`.sunset`, ocean→`.cool`, forest→`.forest` (the latter two existed unused in `MeshBackground.Palette` since v1). Default is `.sunset`, which byte-for-byte matches the pre-theming colors — existing users see no change.

### RSVP filter is scheduler-only and fails open
`MeetingEvent.rsvp` drives the `onlyAcceptedMeetings` overlay filter in `AlertScheduler.reschedule` — not `CalendarAggregator`, so tentative/declined meetings stay visible in the popover agenda; only their overlay/lead notification is suppressed. RSVP defaults to `.unknown` and only `.tentative`/`.declined` are filtered, so anything the source can't classify (organizer, local/personal calendars, EventKit's `isCurrentUser` not matching) still fires — the filter never hides a meeting it isn't sure about. EventKit's `isCurrentUser` match is unreliable for some account types; that's the accepted tradeoff for failing open.

### `EKSource.title` is a user-editable nickname, not a provider
Public EventKit tells you nothing about who hosts a CalDAV account. The only identity `EKSource` carries is `sourceType` — `.calDAV` for iCloud, Google and generic CalDAV alike — plus `title` and `sourceIdentifier`; the rest of the class is calendar accessors and `isDelegate`, none of which name a provider. `title` is the account's **Description** field in System Settings → Internet Accounts, which the user can type anything into, so a Google Workspace account routinely appears as an abbreviation, a company name, or a domain and never has to contain the string "Google". The per-calendar Google `authuser` picker used to filter on that title and so hid itself from renamed Workspace accounts; it now offers every calendar (`SettingsView.googleAuthUserCalendarIDs`). Don't reintroduce a detector here — there's no public API to base one on, and the setting is already inert on non-Meet links.

### `priorityMeeting` is shared by the menu bar and the popover hero — only the menu bar's horizon is user-configurable
`AlertScheduler.priorityMeeting(now:includeReminders:respectMutes:horizon:)` backs both the menu-bar label (`currentMenuBarMeeting`) and the popover's hero card (`ContentView`), so the two never disagree about which meeting is "current". Its `horizon` parameter (rule 3's upper bound) defaults to 15 minutes and **only `currentMenuBarMeeting` passes a different one**, from `AppSettings.menuBarMeetingVisibility` via `menuBarHorizon(now:)`. Don't widen the default to "fix" the hero card: the card answers "what is happening now", the menu bar answers "what is next today". Two more things that look adjustable and are not — the 5-minute floor on rule 3 is rule 1's promotion boundary (imminent meeting preempts a running one), not a visibility setting; and `.allDay` must clip at start-of-tomorrow because the aggregator's pool spans 24h ahead, so an unclipped horizon surfaces tomorrow's first meeting from a late-evening lookup.

`.off` is handled inside `currentMenuBarMeeting`, not in the view, so it also silences the right-click status menu's meeting title and the popover's "Hide from menu bar" link — both call the same accessor. Intended (there is no label left to hide from), but it differs from the pre-2.1.0 bool, which gated only the label.

---

### "Do we have calendar data?" is not the same question as "do we have EventKit permission?"
`CalendarAggregator.permissionState` mirrors EventKit only — Graph has its own `GraphSource.state`, and `performRefresh` fetches Graph regardless of the EventKit verdict. Any UI that gates on `permissionState` alone strands Microsoft 365 users who never grant Calendar.app access. `OnboardingView.canFinishOnboarding` had the right rule (`granted || isGraphSignedIn`) since 1.8; the popover did not, and until 2.0.1 it replaced a fully working M365 agenda with a red "Calendar access denied" screen while the menu bar — which reads the merged event list and has never been permission-gated — kept showing the same meeting. Reported by a user, 2026-08-25.

### A nested ObservableObject's changes don't reach views that observe only the parent
`CalendarAggregator.graph` is itself an `ObservableObject`. SwiftUI does not forward a nested object's `objectWillChange` to views that observe the parent, so a view holding only `@EnvironmentObject var aggregator` will not re-render when `graph.state` changes. `OnboardingView` works around it with child views that `@ObservedObject` the `GraphSource` directly (`MicrosoftStep`, `GraphCalendarsList`). When the parent itself needs the fact, mirror it instead: `CalendarAggregator.isGraphSignedIn` is a Combine `assign(to:)` mirror of `graph.$state`, added in 2.0.1 for the popover gate. Prefer mirroring over spreading child-view workarounds.

### Build settings can inject entitlements that aren't in the entitlements file

`slapss/slapss.entitlements` lists three, and the shipped binary must carry exactly
those three. The privacy claim is "the entitlements are the whole story", so a reader
who runs `codesign -d --entitlements :-` and counts more than the documents say has
caught the project overstating. `ENABLE_*` build settings inject entitlements at build
time: `ENABLE_USER_SELECTED_FILES` is set to an explicit `NO` in both configurations
(matching the neighbouring `ENABLE_RESOURCE_ACCESS_* = NO`) because `readonly` added
`com.apple.security.files.user-selected.read-only` to builds up to 2.0.0. After
touching capabilities, check a local Release build with `codesign`. `README.md` and
`SECURITY.md` state the count and what older builds carried.

One report that will keep coming back: a copy someone builds themselves also
carries `com.apple.security.get-task-allow`, which Xcode adds to any
non-distribution build so a debugger can attach. App Store builds don't have it.
Both documents say so, because "I built it myself and I count four" is the obvious
next message.

**Superseded in part:** the entitlements file went to **four** with the
new-browser-window work — `com.apple.security.automation.apple-events` was added
deliberately — and back to **three** when the sandbox was turned off and
`com.apple.security.app-sandbox` was removed (see the next gotcha). `README.md` /
`SECURITY.md` were updated in the same changes —
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
is gone from `slapss.entitlements`. **This diverges from Can's App Store build (upstream), which
is sandboxed**, and `README.md` / `SECURITY.md` say so — an unsandboxed app is not
confined by its entitlements, so that count stops being a boundary and becomes a
statement of intent. Do not quietly re-enable the sandbox to "fix" the entitlement
story: it silently kills the feature, with no error the user can see.

**When running the A/B, launch through LaunchServices (`open -a`), not the binary
directly.** TCC attributes an Apple event to the *responsible process*; a binary
started from a terminal is attributed to the terminal, so the first attempt
recorded the *terminal's* own bundle id against `com.apple.Safari` and proved
nothing about slapss. Launched with `open -a`, slapss got its own grant.

**A sandboxed and an unsandboxed build read different preference domains.** The
sandboxed app reads `~/Library/Containers/com.cancetin.slapss/Data/Library/Preferences/`,
where `defaults write com.cancetin.slapss` is redirected; an unsandboxed build reads
`~/Library/Preferences/com.cancetin.slapss.plist`. Turning the sandbox off therefore
looks like every preference reset to its default. Worth knowing before diagnosing
"my settings vanished."

### An ad-hoc local build silently loses the Accessibility grant — sign with David's own identity

macOS pins a TCC grant to a **code requirement**, and it captures that
requirement from **how the binary was signed at the moment the grant was made**.
That, not which database the row lives in, is the whole rule. This is why "Pause
playing media when I join" stopped working on 2026-09-11 with nothing wrong in
the code (reported as "slapss did not stop my media this morning").

- Grant made against an **ad-hoc** build → the requirement is a **`cdhash`**: one
  exact binary. Any rebuild changes the cdhash, so the grant is dead and macOS
  re-prompts.
- Grant made against a build signed with a **certificate** → the requirement names
  the certificate:

  ```
  identifier "com.cancetin.slapss" and anchor apple generic and
  certificate leaf[subject.CN] = "Apple Development: <your name> (<your team id>)" and
  certificate 1[field.1.2.840.113635.100.6.2.1]
  ```

  Read the real one back rather than retyping it — it is whatever macOS stored
  when the grant was made:

  ```
  sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
    "select writefile('/tmp/r.csreq', csreq) from access
     where client='com.cancetin.slapss' and service='kTCCServicePostEvent';"
  csreq -r /tmp/r.csreq -t
  ```

  That survives every later rebuild signed with the same identity. An ad-hoc
  build can never satisfy it — it has no certificate — and the failure is
  **silent**: System Settings still shows the toggle **on**, because the row is
  still there, and macOS just drops the event.
  `codesign -v -R=<that requirement> /Applications/slapss.app` returns *code
  failed to satisfy specified code requirement(s)* for an ad-hoc build, exit 0
  for a cert-signed one. Run it **before** installing.

Measured on this machine, which is what corrected an earlier wrong version of
this gotcha. `MediaPauser`'s two services live in the **system** db
(`/Library/Application Support/com.apple.TCC/TCC.db`): `kTCCServicePostEvent` and
`kTCCServiceAccessibility`, both granted 2026-09-04 against a cert-signed build,
so both carry the certificate form. `kTCCServiceReminders` and
`kTCCServiceAppleEvents` in the **user** db were granted 2026-09-01 against an
ad-hoc build and still carry `cdhash` requirements. `kTCCServiceCalendar`, also
in the user db, carried a `cdhash` from a 2026-09-09 ad-hoc install until
2026-09-14, when a cert-signed build was installed, macOS re-prompted, and the
re-approval **rewrote its requirement to the certificate form** — byte-identical
to the system-db blob. Same database, both forms, an hour apart. So do not reason
from the database; reason from the signature in force when the user clicked
Allow.

So: build **Release signed with your own Apple Development identity** when
installing locally, never ad-hoc. Find it with
`security find-identity -v -p codesigning` — on this machine there is exactly
one, and its SHA1 is what `CODE_SIGN_IDENTITY` wants.
The project sets `DEVELOPMENT_TEAM = S2RH54MMT3` (Can's) with
`CODE_SIGN_STYLE = Automatic`, which is why an unqualified build falls back to
ad-hoc; override on the command line (`CODE_SIGN_STYLE=Manual`,
`CODE_SIGN_IDENTITY=`, empty `DEVELOPMENT_TEAM` and
`PROVISIONING_PROFILE_SPECIFIER`). **Verify before installing**, not after:
`codesign -v -R=<the stored requirement> <built .app>` must exit 0. Cert-signing
also makes the grant survive future rebuilds, which ad-hoc never could.

**`MediaPauser` cannot detect any of this, and the reason is not the one the code
comments suggest.** `canPostSyntheticEvents` (`CGPreflightPostEventAccess`) does
carry a responsible-process caveat, but it is never consulted on the post path:
`sendPlayPauseToggle` guards only on `shouldPause`, which asks an audio question,
and `postPlayPauseKey` ends in `CGEvent.post`, which returns Void. There is
nothing to check and nothing to report. `canPostSyntheticEvents` is read only by
`SettingsView` to decide whether to show the "needs permission" row — so that row
is the *only* surface that could ever hint at this, and it answers a different
question than "will the key actually land".

If media pause misbehaves when the signature **does** satisfy the requirement,
the next suspect is `shouldPause` — its own docstring says the gate is unsettled.

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
- **Only `MARKETING_VERSION` matters for a release.** Bump both its occurrences together, and always ask David for the number first.
- **`CURRENT_PROJECT_VERSION` is dead weight.** Upstream's Xcode Cloud assigns the build number itself, sequentially per product, and overrides whatever the project says (the committed value read `15` while App Store Connect had already delivered build 17), and a local build only stamps it into `CFBundleVersion` (currently 15), which nothing consumes. Don't bump it, and don't trust it — upstream's real counter lives in Can's App Store Connect → Xcode Cloud → Settings → Build Number.
- Current version: **2.2.1**
- The tree is **not sandboxed** as of the browser-window work; Can's App Store build is. See the App Sandbox gotcha before changing `ENABLE_APP_SANDBOX`.

---

## Engineering log

Per-version engineering record (the *why*, traps hit, what was validated) lives in
`ENGINEERING-LOG.md`. Add to it after every user-visible change, newest first.
