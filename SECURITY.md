# Security policy

## Reporting a vulnerability

**Please do not open a public GitHub issue for security vulnerabilities.**

Email <info@slapss-app.com> with:

- What the issue is and what an attacker could achieve.
- Steps to reproduce, or a proof of concept.
- The Slapss version and macOS version you tested on.

You'll get an acknowledgement. Slapss is maintained by one person alongside a
full-time job, so please allow reasonable time for a fix before disclosing
publicly. Credit in the release notes if you'd like it.

## Supported versions

Only the current App Store release receives fixes. There are no maintained
older branches.

## Scope notes

Slapss has no server component. Its attack surface is small and worth stating
plainly. Note that this source tree is **not** sandboxed — see the first bullet.

- **Sandboxing.** This source tree is **not** sandboxed (`ENABLE_APP_SANDBOX =
  NO`); the Mac App Store build is. The App Sandbox blocks Apple events to
  ordinary running applications — a sandboxed build gets `-600 procNotFound`
  addressing Safari and macOS never presents the Automation prompt — so the
  "Joining meetings" preferences cannot function under it. The trade is explicit:
  the feature works, and the entitlements below no longer act as an enforced
  confinement. Prefer the App Store build if you want the sandbox.
- **Entitlements** are outbound network client, calendar access, and Apple events
  (`slapss/slapss.entitlements`). Verify against a build with
  `codesign -d --entitlements :- /Applications/slapss.app`. Builds up to 2.0.0
  additionally carried user-selected read-only file access, injected by the
  `ENABLE_USER_SELECTED_FILES` build setting and used by no code path; 2.0.1
  removes it. A locally built copy also carries
  `com.apple.security.get-task-allow` (debugger attach), which App Store builds do
  not.
- **Apple events** (`com.apple.security.automation.apple-events`) are sent only by
  the two opt-in preferences under Settings → General → Joining meetings, and only
  to the browser registered as the default handler for `https`. Both preferences
  ship off; with both off, `BrowserWindowOpener.open` returns immediately and no
  event is sent. Nor is one sent for a Chromium-based default browser opening a
  new window — that goes through launch arguments instead. The events themselves
  are `activate`, `make new document` and `set bounds of front window`: they open
  and position a window and read nothing back. macOS gates this behind a separate
  per-target Automation grant that the user is asked for on first use, and
  refusing it degrades to a plain `NSWorkspace.open`.
- **Accessibility** is a TCC grant, not an entitlement, so it does not appear in
  `slapss.entitlements` and `codesign` will never show it. It is requested only by
  the opt-in "Pause playing media when I join" preference (Settings → General),
  which ships off. When on, `MediaPauser.sendPlayPauseToggle` posts one system
  Play/Pause key through `CGEvent.post` just before a join URL opens. Slapss does
  not read the keyboard, observe other applications, or post anything else. The
  grant is visible and revocable in System Settings → Privacy & Security →
  Accessibility. Two consequences worth knowing: macOS pins this grant to a code
  requirement derived from however the binary was signed when the grant was made —
  a certificate if it was signed with one, otherwise that exact build's `cdhash` —
  so a differently signed or rebuilt ad-hoc copy does not inherit it; and
  `CGEvent.post` reports nothing, so a grant that no longer applies is silently
  ignored rather than surfaced.
- **Network egress** goes to Microsoft Graph and Microsoft identity endpoints
  only, and only when the user has signed in to a Microsoft 365 account.
- **Credentials.** Microsoft OAuth tokens are stored in the system keychain. The
  flow is authorization code + PKCE via `ASWebAuthenticationSession`; there is no
  client secret in the app, by design.
- **Calendar data** never leaves the device. There is no backend to send it to.
- The Azure application (client) ID in `slapss/Auth/MSALConfig.swift` is a public
  client identifier. It is not a secret — it is designed to be embedded in a
  distributed binary and is extractable from any shipped copy of the app.

Things that are **not** vulnerabilities: reporting the client ID as a "leaked
secret"; reporting the Apple development team ID in the Xcode project; reporting
that a locally-modified build can read your own calendar.
