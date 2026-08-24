//
//  SettingsView.swift
//  slapss
//
//  Preferences window. Reachable via Cmd-, or the "Preferences…" entry in
//  the menu bar popover.
//

import AppKit
import EventKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var aggregator: CalendarAggregator
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var lm: LocalizationManager

    @Environment(\.openWindow) private var openWindow

    @State private var launchAtLogin: Bool = LaunchAtLoginManager.isEnabled

    /// The join preference the user just switched on that still needs the
    /// Automation grant. Non-nil while the explanation alert is up; the
    /// preference is only written if the user chooses Continue.
    @State private var joiningNeedingPermission: JoiningPreference?
    /// Read with `AEDeterminePermissionToAutomateTarget(…, askUserIfNeeded:
    /// false)`, so opening Settings never asks the user for anything. The real
    /// prompt comes from macOS on the first join after they opt in.
    @State private var automationStatus: BrowserWindowOpener.AutomationStatus = .undetermined
    /// The default browser, resolved once per appearance rather than per body
    /// pass — identifying it costs a LaunchServices lookup plus reading another
    /// app's bundle off disk.
    @State private var browserFamily: BrowserFamily = .unknown
    @State private var browserName: String = ""

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label(lm["settings.tab.general"], systemImage: "gearshape") }

            calendarsTab
                .tabItem { Label(lm["settings.tab.calendars"], systemImage: "calendar") }

            aboutTab
                .tabItem { Label(lm["settings.section.about"], systemImage: "info.circle") }
        }
        .frame(width: 480, height: 380)
        .task {
            aggregator.refreshSourcesIfNecessary()
            refreshBrowserState()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            aggregator.refreshSourcesIfNecessary()
            // Picks up a grant (or a revocation) the user just made in System
            // Settings, or a change of default browser, without needing the
            // window reopened.
            refreshBrowserState()
        }
    }

    // MARK: - Helpers

    /// Discrete steps for the overlay lead-time slider: at meeting start,
    /// 30 seconds, then 1–15 whole minutes (15 is Can's cap for the
    /// full-screen alert). 17 detents total.
    private static let overlayLeadSteps: [Int] = [0, 30] + (1...15).map { $0 * 60 }

    /// Index of the step closest to the stored seconds value. Legacy
    /// free-typed values that don't fall on a detent (e.g. 45 s from the
    /// v1.8.1 text field) snap to the nearest step on read — no migration.
    private var overlayLeadStepIndex: Int {
        let s = settings.overlayLeadTimeSeconds
        return Self.overlayLeadSteps.indices.min {
            abs(Self.overlayLeadSteps[$0] - s) < abs(Self.overlayLeadSteps[$1] - s)
        } ?? 0
    }

    /// Slider position ↔ stored seconds. The slider moves over step
    /// *indices* (0...16), not seconds, so detents are evenly spaced even
    /// though the underlying values aren't linear (0, 30 s, 1–15 min).
    private var overlayLeadSliderValue: Binding<Double> {
        Binding(
            get: { Double(overlayLeadStepIndex) },
            set: { settings.overlayLeadTimeSeconds = Self.overlayLeadSteps[Int($0.rounded())] }
        )
    }

    /// Full sentence for the current selection ("30 seconds before",
    /// "5 minutes before", "At meeting start") — shown live next to the
    /// slider and used as the accessibility value, so neither sighted users
    /// nor VoiceOver ever get a bare, unit-less number.
    private var overlayLeadLabel: String {
        let s = Self.overlayLeadSteps[overlayLeadStepIndex]
        if s == 0 { return lm["settings.alert.early.0"] }
        if s < 60 { return lm.t("settings.alert.early.secondsFormat", s) }
        return lm.t("settings.alert.early.minutesFormat", s / 60)
    }

    /// Marketing version from the bundle (e.g. "1.6").
    private var appVersionString: String {
        let info = Bundle.main.infoDictionary
        return info?["CFBundleShortVersionString"] as? String ?? "—"
    }

    // MARK: - Tabs

    /// Inline copy that explains the current reminder authorization state
    /// when the toggle is on but EventKit hasn't been granted access.
    private var reminderPermissionMessage: String {
        switch aggregator.reminderPermissionState {
        case .notDetermined:
            return lm["settings.reminders.notDetermined"]
        case .denied, .restricted:
            return lm["settings.reminders.denied"]
        case .granted:
            return ""
        }
    }

    private var generalTab: some View {
        Form {
            Section(lm["settings.section.language"]) {
                Picker(lm["settings.language.label"], selection: Binding(
                    get: { lm.language },
                    set: { lm.setLanguage($0) }
                )) {
                    ForEach(Language.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .pickerStyle(.menu)
            }

            Section(lm["settings.section.theme"]) {
                ThemeSwatchPicker()
            }

            Section(lm["settings.section.alert"]) {
                Picker(lm["settings.leadTime.label"], selection: $settings.leadTimeMinutes) {
                    Text(lm["general.off"]).tag(0)
                    Text(lm["settings.leadTime.1before"]).tag(1)
                    Text(lm["settings.leadTime.5before"]).tag(5)
                    Text(lm["settings.leadTime.10before"]).tag(10)
                    Text(lm["settings.leadTime.15before"]).tag(15)
                    Text(lm["settings.leadTime.30before"]).tag(30)
                }
                .pickerStyle(.menu)
                // Caption disambiguating the two adjacent "lead time"
                // controls: this one is a standard notification…
                Text(lm["settings.leadTime.caption"])
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                LabeledContent(lm["settings.alert.showEarly"]) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(overlayLeadLabel)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Slider(
                            value: overlayLeadSliderValue,
                            in: 0...Double(Self.overlayLeadSteps.count - 1),
                            step: 1
                        )
                        .frame(width: 200)
                        .accessibilityValue(overlayLeadLabel)
                    }
                }
                .accessibilityValue(overlayLeadLabel)
                // …and this one is the full-screen takeover alert.
                Text(lm["settings.alert.showEarly.caption"])
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle(lm["settings.alert.playSound"], isOn: $settings.alertSoundEnabled)
                Toggle(lm["settings.alert.allDisplays"], isOn: $settings.showAlertOnAllScreens)
                Toggle(lm["settings.alert.reminderOverlay"], isOn: $settings.showReminderOverlay)
                Toggle(lm["settings.alert.onlyAccepted"], isOn: $settings.onlyAcceptedMeetings)
                // The filter fails open (unknown RSVP still fires) and is
                // scheduler-only — without this line users think it's broken
                // when a tentative meeting still shows up in the agenda.
                Text(lm["settings.alert.onlyAccepted.caption"])
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(lm["settings.section.menuBar"]) {
                Toggle(lm["settings.menuBar.showMeeting"], isOn: $settings.showNextMeetingInMenuBar)
            }

            Section(lm["settings.section.popover"]) {
                Toggle(lm["settings.popover.showEarlier"], isOn: $settings.showPastMeetingsToday)
                Toggle(lm["settings.popover.showReminders"], isOn: $settings.showReminders)
                if settings.showReminders && aggregator.reminderPermissionState != .granted {
                    HStack(spacing: 8) {
                        Text(reminderPermissionMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if aggregator.reminderPermissionState == .notDetermined {
                            Button(lm["general.continue"]) {
                                Task { await aggregator.requestReminderAccess() }
                            }
                            .controlSize(.small)
                        } else {
                            Button(lm["general.openSystemSettings"]) {
                                SystemSettingsOpener.openRemindersPrivacy()
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }

            Section(lm["settings.section.joining"]) {
                Toggle(lm["settings.joining.newWindow"], isOn: joiningBinding(.newWindow))
                Toggle(lm["settings.joining.builtInDisplay"], isOn: joiningBinding(.builtInDisplay))
                Text(lm["settings.joining.caption"])
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // Only shown once a preference that needs the grant is on and
                // the grant is missing — otherwise the row is noise. Meetings
                // still open in this state, so the wording says so.
                if joiningNeedsAutomation, automationStatus == .denied {
                    HStack(spacing: 8) {
                        Text(lm.t("settings.joining.permissionDenied", browserDisplayName))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button(lm["general.openSystemSettings"]) {
                            SystemSettingsOpener.openAutomationPrivacy()
                        }
                        .controlSize(.small)
                    }
                }
                if joiningUnsupported {
                    Text(lm.t("settings.joining.unsupportedBrowser", browserDisplayName))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section(lm["settings.section.googleMeet"]) {
                Toggle(lm["settings.googleMeet.perCalendar"], isOn: $settings.enableGoogleAuthUser)
                Text(lm["settings.googleMeet.description"])
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(lm["settings.section.startup"]) {
                Toggle(lm["settings.startup.launchAtLogin"], isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        LaunchAtLoginManager.setEnabled(newValue)
                    }
            }

        }
        .formStyle(.grouped)
        .padding()
        .alert(
            lm.t("settings.joining.permissionTitle", browserDisplayName),
            isPresented: Binding(
                get: { joiningNeedingPermission != nil },
                set: { if !$0 { joiningNeedingPermission = nil } }
            )
        ) {
            Button(lm["general.continue"]) {
                if let preference = joiningNeedingPermission { setJoining(preference, true) }
                joiningNeedingPermission = nil
            }
            Button(lm["general.cancel"], role: .cancel) {
                joiningNeedingPermission = nil
            }
        } message: {
            Text(lm.t("settings.joining.permissionBody", browserDisplayName))
        }
    }

    // MARK: - Joining meetings

    /// The two join-in-browser preferences. Named rather than passed as a
    /// key path so the explanation alert can hold "which toggle is pending"
    /// in a single piece of `@State`.
    private enum JoiningPreference {
        case newWindow
        case builtInDisplay
    }

    private func refreshBrowserState() {
        automationStatus = BrowserWindowOpener.automationStatus()
        browserFamily = BrowserWindowOpener.defaultBrowserFamily()
        browserName = BrowserWindowOpener.defaultBrowserDisplayName() ?? ""
    }

    private var browserDisplayName: String {
        browserName.isEmpty ? lm["settings.joining.browserFallback"] : browserName
    }

    /// Whether the preferences as they stand need the Automation grant. Drives
    /// the denied-state row only — the toggles themselves ask about the
    /// placement they would produce, not the current one.
    private var joiningNeedsAutomation: Bool {
        settings.browserPlacement.requiresAutomation(in: browserFamily)
    }

    /// True when a preference is on that this browser cannot honour — today
    /// only Firefox, which has no scriptable window `bounds`. Saying so beats
    /// leaving a toggle that looks active and never does anything.
    private var joiningUnsupported: Bool {
        !settings.browserPlacement.isFullySupported(in: browserFamily)
    }

    private func joiningValue(_ preference: JoiningPreference) -> Bool {
        switch preference {
        case .newWindow: return settings.openMeetingsInNewWindow
        case .builtInDisplay: return settings.openMeetingsOnBuiltInDisplay
        }
    }

    private func setJoining(_ preference: JoiningPreference, _ value: Bool) {
        switch preference {
        case .newWindow: settings.openMeetingsInNewWindow = value
        case .builtInDisplay: settings.openMeetingsOnBuiltInDisplay = value
        }
    }

    /// The placement that would result from switching `preference` on, used to
    /// decide whether the grant is needed *before* writing the preference.
    /// The two interact: with Chromium, "new window" plus "built-in display"
    /// needs no permission, while "built-in display" alone does.
    private func placement(enabling preference: JoiningPreference) -> BrowserPlacement {
        var placement = settings.browserPlacement
        switch preference {
        case .newWindow: placement.opensNewWindow = true
        case .builtInDisplay: placement.forcesBuiltInDisplay = true
        }
        return placement
    }

    /// Switching a preference off is immediate. Switching one on that needs
    /// Apple events raises the in-app explanation first, so the system's own
    /// Automation prompt (which arrives later, on the first join) isn't the
    /// first the user hears of it.
    private func joiningBinding(_ preference: JoiningPreference) -> Binding<Bool> {
        Binding(
            get: { joiningValue(preference) },
            set: { newValue in
                guard newValue else {
                    setJoining(preference, false)
                    return
                }
                let needsGrant = placement(enabling: preference)
                    .requiresAutomation(in: browserFamily)
                if needsGrant, automationStatus != .granted {
                    joiningNeedingPermission = preference
                } else {
                    setJoining(preference, true)
                }
            }
        )
    }

    /// Split out from `generalTab` in v1.8 — the General tab had grown to 8
    /// sections crammed into a fixed-height window and scrolled awkwardly.
    /// About/version/support content doesn't relate to day-to-day settings
    /// anyway, so it gets its own tab rather than a taller window.
    private var aboutTab: some View {
        Form {
            Section(lm["settings.section.about"]) {
                LabeledContent(lm["settings.about.version"]) {
                    Text(appVersionString)
                        .foregroundStyle(.secondary)
                }

                LabeledContent(lm["settings.about.website"]) {
                    Button("slapss-app.com") {
                        if let url = URL(string: "https://www.slapss-app.com/") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.link)
                }

                LabeledContent(lm["settings.about.support"]) {
                    Button("info@slapss-app.com") {
                        if let url = URL(string: "mailto:info@slapss-app.com") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.link)
                }

                // Slapss claims your calendar never leaves the Mac. About is
                // where someone checks that kind of claim, so the source link
                // belongs here rather than buried in onboarding.
                LabeledContent(lm["settings.about.sourceCode"]) {
                    Button("github.com/theshiver/slapss-app") {
                        if let url = URL(string: "https://github.com/theshiver/slapss-app") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.link)
                }

                Button(lm["settings.about.tourAgain"]) {
                    settings.onboardingCompleted = false
                    // Capture Settings window BEFORE openWindow() — that call
                    // makes the new onboarding window key, so keyWindow would
                    // point to onboarding (and close it) if we wait until after.
                    let settingsWindow = NSApp.keyWindow
                    openWindow(id: WindowID.onboarding)
                    NSApp.activate(ignoringOtherApps: true)
                    settingsWindow?.close()
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var calendarsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                eventKitSection
                Divider()
                microsoftSection
            }
            .padding()
        }
    }

    private var eventKitSection: some View {
        let calendars = aggregator.availableEventKitCalendars
        let pickerCalendarIDs = Self.googleAuthUserCalendarIDs(
            in: calendars.map { ($0.calendarIdentifier, $0.source.title) }
        )

        return VStack(alignment: .leading, spacing: 8) {
            Text(lm["settings.calendars.macos.title"])
                .font(.headline)
            Text(lm["settings.calendars.macos.description"])
                .font(.caption)
                .foregroundStyle(.secondary)

            // Without calendar permission the ForEach below is empty and the
            // tab dead-ends (title + description, no calendars, no way
            // forward). Mirror the popover's permission states so the user
            // can grant or fix access from right here.
            switch aggregator.permissionState {
            case .notDetermined:
                Button(lm["general.continue"]) {
                    Task { await aggregator.requestAccess() }
                }
                .controlSize(.small)
            case .denied, .restricted:
                Text(lm["popover.permissionDenied"])
                    .font(.caption)
                    .foregroundStyle(.red)
                Text(lm["popover.permissionDeniedHelp"])
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(lm["general.openSystemSettings"]) {
                    SystemSettingsOpener.openCalendarPrivacy()
                }
                .controlSize(.small)
            case .granted:
                EmptyView()
            }

            ForEach(calendars, id: \.calendarIdentifier) { calendar in
                VStack(alignment: .leading, spacing: 2) {
                    Toggle(isOn: bindingForEventKit(id: calendar.calendarIdentifier)) {
                        HStack {
                            Circle()
                                .fill(Color(cgColor: calendar.cgColor))
                                .frame(width: 10, height: 10)
                            Text(calendar.title)
                            Spacer()
                            Text(calendar.source.title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)

                    if settings.enableGoogleAuthUser,
                       pickerCalendarIDs.contains(calendar.calendarIdentifier) {
                        Picker(
                            lm["settings.calendars.openMeetAs"],
                            selection: authUserBinding(id: calendar.calendarIdentifier)
                        ) {
                            Text(lm["settings.calendars.defaultAccount"]).tag(-1)
                            ForEach(0..<5) { index in
                                Text(lm.t("settings.calendars.account", index, index)).tag(index)
                            }
                        }
                        .pickerStyle(.menu)
                        .controlSize(.small)
                        .padding(.leading, 18)
                    }
                }
            }

            if settings.enableGoogleAuthUser {
                Text(lm["settings.calendars.authUserHint"])
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
    }

    /// Which calendars show the Google `authuser` picker: all of them.
    ///
    /// Eligibility deliberately ignores `sourceTitle`. Public EventKit exposes
    /// no provider for a CalDAV source, so identifying Google calendars meant
    /// substring-matching the source title — which is the account's nickname in
    /// System Settings, and freely editable. A Google Workspace account renamed
    /// to something like "IN" failed the match, and the all-calendars fallback
    /// was global rather than per-account, so a second account that did match
    /// ("Gmail") suppressed the fallback everywhere. The picker then hid on
    /// exactly the calendars carrying Meet links.
    ///
    /// Offering it everywhere is safe: the setting is opt-in and off by
    /// default, and a value set on a non-Google calendar is inert because
    /// `MeetingURLOpener.applyAuthUserIfNeeded` rewrites `meet.google.com`
    /// URLs only. `sourceTitle` stays in the signature so the rule can be
    /// asserted against the account names that used to break it.
    static func googleAuthUserCalendarIDs(
        in calendars: [(id: String, sourceTitle: String)]
    ) -> Set<String> {
        Set(calendars.map(\.id))
    }

    /// Per-calendar Google `authuser` index. `-1` is the sentinel for
    /// "Default account" (no `authuser` applied) — distinct from index 0,
    /// which is a real, valid first account.
    private func authUserBinding(id: String) -> Binding<Int> {
        Binding(
            get: { settings.authUserByCalendar[id] ?? -1 },
            set: { newValue in
                if newValue < 0 {
                    settings.authUserByCalendar.removeValue(forKey: id)
                } else {
                    settings.authUserByCalendar[id] = newValue
                }
            }
        )
    }

    private var microsoftSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(lm["settings.microsoft.title"])
                    .font(.headline)
                Spacer()
                graphActionButton
            }

            switch aggregator.graph.state {
            case .signedOut:
                Text(lm["settings.microsoft.description"])
                    .font(.caption)
                    .foregroundStyle(.secondary)
                adminHelpDisclosure

            case .signingIn:
                ProgressView(lm["settings.microsoft.signingIn"])
                    .controlSize(.small)

            case .signedIn(let displayName):
                if let displayName {
                    Text(lm.t("settings.microsoft.signedInAs", displayName))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(aggregator.graph.availableCalendars) { calendar in
                    Toggle(isOn: bindingForGraph(id: calendar.id)) {
                        HStack {
                            Circle()
                                .fill(graphCalendarColor(calendar))
                                .frame(width: 10, height: 10)
                            Text(calendar.name)
                            if calendar.isDefaultCalendar == true {
                                Text(lm["settings.microsoft.default"])
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                }

            case .error(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                adminHelpDisclosure
            }
        }
    }

    // MARK: - IT admin approval helper

    /// Some tenants block users from consenting to third-party apps and require
    /// the IT admin to pre-approve the app. Surface this case directly so users
    /// don't get stuck — they can fire off a templated email to their admin or
    /// copy a one-click admin-consent URL.
    private var adminHelpDisclosure: some View {
        DisclosureGroup(lm["settings.microsoft.adminHelp"]) {
            VStack(alignment: .leading, spacing: 8) {
                Text(lm["settings.microsoft.adminDescription"])
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button(lm["settings.microsoft.emailAdmin"]) { openAdminEmailDraft() }
                    Button(lm["settings.microsoft.copyLink"]) { copyAdminConsentURL() }
                }
                .controlSize(.small)
            }
            .padding(.top, 4)
        }
        .font(.callout)
    }

    private func adminConsentURL() -> URL? {
        URL(string: "https://login.microsoftonline.com/organizations/adminconsent?client_id=\(MSALConfig.clientID)")
    }

    private func openAdminEmailDraft() {
        let consent = adminConsentURL()?.absoluteString ?? ""
        let subject = "Approval request: Slapss for macOS"
        let body = """
        Hi,

        I'd like to use Slapss, a macOS app that reminds me about upcoming meetings on my Mac. It needs to be approved on our tenant before I can sign in with my work account.

        What it requests:
        • Calendars.Read — read my calendar to schedule reminders
        • User.Read — display my name in the app

        It does NOT write to my calendar, send anything anywhere, or share data with any third party. All event data stays on my Mac.

        To approve it tenant-wide as an admin, sign in here in one click:
        \(consent)

        Thanks!
        """

        var components = URLComponents()
        components.scheme = "mailto"
        components.path = ""
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body),
        ]
        if let url = components.url {
            NSWorkspace.shared.open(url)
        }
    }

    private func copyAdminConsentURL() {
        guard let url = adminConsentURL() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    @ViewBuilder
    private var graphActionButton: some View {
        switch aggregator.graph.state {
        case .signedOut, .error:
            Button(lm["settings.microsoft.connect"]) {
                Task { await aggregator.graph.signIn() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!aggregator.graph.isConfigured)

        case .signingIn:
            EmptyView()

        case .signedIn:
            Button(lm["settings.microsoft.signOut"]) {
                Task { await aggregator.graph.signOut() }
            }
            .controlSize(.small)
        }
    }

    private func graphCalendarColor(_ calendar: GraphTypes.Calendar) -> Color {
        guard var hex = calendar.hexColor else { return .secondary }
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return .secondary }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    private func bindingForEventKit(id: String) -> Binding<Bool> {
        Binding(
            get: {
                settings.enabledEventKitCalendarIDs.isEmpty ||
                settings.enabledEventKitCalendarIDs.contains(id)
            },
            set: { newValue in
                if settings.enabledEventKitCalendarIDs.isEmpty {
                    let all = aggregator.availableEventKitCalendars.map(\.calendarIdentifier)
                    settings.enabledEventKitCalendarIDs = Set(all)
                }
                if newValue {
                    settings.enabledEventKitCalendarIDs.insert(id)
                } else {
                    settings.enabledEventKitCalendarIDs.remove(id)
                }
                aggregator.setEnabledEventKitCalendars(settings.enabledEventKitCalendarIDs)
            }
        )
    }

    private func bindingForGraph(id: String) -> Binding<Bool> {
        Binding(
            get: {
                settings.enabledGraphCalendarIDs.isEmpty ||
                settings.enabledGraphCalendarIDs.contains(id)
            },
            set: { newValue in
                if settings.enabledGraphCalendarIDs.isEmpty {
                    let all = aggregator.graph.availableCalendars.map(\.id)
                    settings.enabledGraphCalendarIDs = Set(all)
                }
                if newValue {
                    settings.enabledGraphCalendarIDs.insert(id)
                } else {
                    settings.enabledGraphCalendarIDs.remove(id)
                }
                aggregator.setEnabledGraphCalendars(settings.enabledGraphCalendarIDs)
            }
        )
    }
}
