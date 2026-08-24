//
//  GoogleAuthUserCalendarIDsTests.swift
//  slapssTests
//

import XCTest
@testable import slapss

/// Regression cover for `SettingsView.googleAuthUserCalendarIDs` — see its doc
/// comment for why eligibility ignores the account name.
final class GoogleAuthUserCalendarIDsTests: XCTestCase {

    /// The account name must not decide eligibility. "IN" contains none of the
    /// substrings the old predicate looked for.
    func testCalendarWithNonGoogleSourceTitleIsEligible() {
        let ids = SettingsView.googleAuthUserCalendarIDs(
            in: [(id: "cal-incremental", sourceTitle: "IN")]
        )

        XCTAssertEqual(ids, ["cal-incremental"])
    }

    /// The reported configuration: a Workspace account renamed "IN" alongside a
    /// personal account still named "Gmail". Under the old rule the "Gmail"
    /// match suppressed the fallback and "IN" was dropped from the set.
    func testGoogleishAccountDoesNotSuppressAnother() {
        let ids = SettingsView.googleAuthUserCalendarIDs(in: [
            (id: "cal-incremental", sourceTitle: "IN"),
            (id: "cal-personal", sourceTitle: "Gmail"),
        ])

        XCTAssertEqual(ids, ["cal-incremental", "cal-personal"])
    }

    /// Non-Google accounts are offered the picker too. A value set there is
    /// inert: `MeetingURLOpener.applyAuthUserIfNeeded` rewrites only
    /// `meet.google.com` URLs.
    func testEveryCalendarIsEligibleWhateverTheSource() {
        let ids = SettingsView.googleAuthUserCalendarIDs(in: [
            (id: "a", sourceTitle: "iCloud"),
            (id: "b", sourceTitle: "Exchange"),
            (id: "c", sourceTitle: "On My Mac"),
        ])

        XCTAssertEqual(ids, ["a", "b", "c"])
    }

    func testNoCalendarsYieldsNoEligibleIDs() {
        XCTAssertTrue(SettingsView.googleAuthUserCalendarIDs(in: []).isEmpty)
    }
}
