<div align="center">

<img src="slapss/Assets.xcassets/AppIcon.appiconset/icon_128x128.png" width="112" alt="Slapss app icon">

# Slapss

**A full-screen meeting reminder for Mac.**

Slapss lives in your menu bar, watches your calendar, and puts an unmissable
full-screen card on your display the moment a meeting starts.

[**Download on the Mac App Store**](https://apps.apple.com/app/id6767488326) · [slapss-app.com](https://slapss-app.com) · [Changelog](CHANGELOG.md)

*Free forever. No subscription, no in-app purchase, no account, no tracking.*

*If Slapss saves you a meeting or two, you can [sponsor its development](https://github.com/sponsors/theshiver). Entirely optional.*

</div>

---

## Why this repository exists

Slapss makes one claim above all others: **it reads your calendar locally and
sends it nowhere.** In a closed-source binary that is a promise you have to take
on faith. This repository is here so you don't have to — you can read every line
that touches your calendar data.

The app you install is still the one on the Mac App Store. Nothing about how you
use Slapss changes.

## What it does

- **Menu bar status item** with the next meeting's title and a live countdown.
- **Full-screen alert** at meeting start, with Join, Snooze, and Dismiss. Shows on one display or all of them.
- **Calendar sources:** macOS Calendar and Reminders (EventKit) and Microsoft 365 / Exchange (Microsoft Graph).
- **Presenting Now** — a one-click toggle that queues alerts instead of firing them while you're screen sharing.
- **Themes:** Sunset, Ocean, Forest.
- **Seven languages:** English, Turkish, Spanish, German, Italian, French, Japanese.
- **Accessibility:** full VoiceOver labelling, keyboard-operable alert, and Reduce Motion / Reduce Transparency support.

## Privacy

There is no Slapss server. There is nothing to have an outage.

- Calendar and reminder data is read through Apple's EventKit and stays on your Mac.
- Microsoft 365 calendars are fetched directly from Microsoft Graph by the app itself, using a read-only scope (`Calendars.Read`, `User.Read`). Tokens live in your keychain.
- No analytics, no crash reporting SDK, no telemetry, no accounts.
- **This build is not sandboxed, and that is a deliberate divergence from the App Store build.** The App Store version of Slapss is sandboxed. This source tree sets `ENABLE_APP_SANDBOX = NO`, because the App Sandbox makes Apple events to an ordinary running application impossible — a sandboxed Slapss asking Safari to open a meeting in a new window gets `-600 procNotFound`, macOS never even asks the user, and the feature cannot work. Turning the sandbox off is what makes "Joining meetings" work with Safari. Read the consequence plainly: an unsandboxed app is not confined by the entitlements below, so they describe intent rather than an enforced boundary. If you want the sandboxed guarantees, install from the Mac App Store.
- Its entitlements are three, in [`slapss/slapss.entitlements`](slapss/slapss.entitlements): outbound network (for Microsoft Graph), calendar access, and Apple events. Don't take this on faith, read them off the copy you installed:
  `codesign -d --entitlements :- /Applications/slapss.app`
  The Apple events entitlement (`com.apple.security.automation.apple-events`) exists for the two opt-in settings under Settings → General → Joining meetings: opening a join link in a new browser window, and putting that window on your built-in display. Both are off by default, and with both off no Apple event is ever sent. When you do turn one on, whether an event is sent depends on your browser: Chromium-based browsers take a new window as a launch argument and need no permission, while Safari and any request to move an existing window do. In those cases macOS asks you separately, per app, the first time Slapss tries — and the target is only the browser you have set as default. The events sent are `activate`, `make new document` and `set bounds of front window`. Nothing is ever read back.
  Two things you may see that aren't in that file. Builds up to 2.0.0 also carried `com.apple.security.files.user-selected.read-only`, injected by an Xcode build setting (`ENABLE_USER_SELECTED_FILES`); no code path ever used it and 2.0.1 removes it. And a copy you build yourself carries `com.apple.security.get-task-allow`, which Xcode adds to local builds so a debugger can attach — App Store builds don't have it.
- One permission is **not** an entitlement and so will never show up in that
  command: **Accessibility**. It is asked for only by the opt-in "Pause playing
  media when I join" setting (Settings → General), which ships off. With it on,
  Slapss posts one system Play/Pause key just before a meeting opens — the same
  key as on your keyboard. It does not read your keystrokes or watch other apps.
  Revoke it any time in System Settings → Privacy & Security → Accessibility.
  macOS records the grant against however the copy was signed, so a copy you
  build yourself has to be granted it separately from one you installed
  earlier — and if your copy is signed ad-hoc, every rebuild asks again.

## Architecture

~8,900 lines of Swift across 28 files, **no third-party dependencies** — no SPM
packages, no CocoaPods, no Carthage. Even the Microsoft sign-in flow is
hand-rolled on `ASWebAuthenticationSession` + `CryptoKit` (PKCE).

| Object | Responsibility |
|---|---|
| `CalendarAggregator` | Merges EventKit + Microsoft Graph sources, publishes `upcomingMeetings` |
| `AlertScheduler` | Timers, watchdog, App Nap prevention, fires and queues overlays |
| `AppSettings` | All user preferences, persisted to `UserDefaults` |
| `LocalizationManager` | Runtime language switching without a restart |
| `PopoverVisibilityMonitor` | Tracks real popover open/close via `NSWindow` notifications |

[`CLAUDE.md`](CLAUDE.md) documents the architecture in full, along with the
non-obvious macOS and SwiftUI constraints this app runs into — `MenuBarExtra`
never calling `onDisappear`, `Color.clear` flipping the AppKit coordinate system,
App Nap throttling scheduled timers, and more. **Read it before changing
anything.** Those workarounds look like mistakes until you know why they're there.

## Building from source

Requirements: macOS 14.6 or later to **run**, **Xcode 26 or later** to build.

> **Xcode 26 is a hard requirement, not a suggestion.** The project sets
> `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, which makes every declaration
> implicitly `@MainActor`. Older Xcode versions don't know that build setting,
> silently ignore it, and then fail with a wall of *"call to main actor-isolated
> instance method in a synchronous nonisolated context"* errors. If you see
> those, your Xcode is too old — the code is fine.

```
git clone https://github.com/theshiver/slapss-app.git
cd slapss-app
open slapss.xcodeproj
```

Two things to change for your own build:

1. **Signing.** In Xcode, select the `slapss` target → Signing & Capabilities →
   set **Team** to your own Apple developer team. The committed value is the
   upstream team and won't work for you.
2. **Microsoft sign-in** (optional — everything else builds and runs without it).
   The committed Azure app registration is the upstream one. To sign in against
   your own, follow [`AZURE_SETUP.md`](AZURE_SETUP.md).

To check that it compiles without any signing setup at all:

```
xcodebuild build -project slapss.xcodeproj -scheme slapss -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

## Contributing

Bug fixes, translation corrections, and accessibility improvements are welcome.
Please read [`CONTRIBUTING.md`](CONTRIBUTING.md) first — it says what gets merged,
what doesn't, and how long you should expect to wait.

Found a security issue? Don't open an issue. See [`SECURITY.md`](SECURITY.md).

## License

Code is licensed under the [Apache License 2.0](LICENSE).

**The Slapss name, app icon, menu bar mark, and logo are not covered by that
license.** They are trademarks and copyrighted assets, all rights reserved. If
you publish a fork, it must use its own name and its own icon. See
[`TRADEMARK.md`](TRADEMARK.md).

The only official build of Slapss is the one distributed from
[the Mac App Store listing above](https://apps.apple.com/app/id6767488326).
