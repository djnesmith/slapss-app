//
//  MeetingLinkDetectorTests.swift
//  slapssTests
//

import XCTest
@testable import slapss

/// Regression cover for `MeetingLinkDetector.firstURL`, and specifically for the
/// 2.1.1 fix: a provider's own domain also serves the images inside an HTML
/// invitation, so "first match of the winning pattern" picked the logo.
///
/// The reproduction is the one from the field report — Zoom's Outlook add-in
/// puts its logo `<img>` above the join link in the invitation body, and both
/// URLs satisfy the Zoom pattern.
@MainActor
final class MeetingLinkDetectorTests: XCTestCase {

    /// A real Zoom add-in body: logo first, join link second. Before the fix the
    /// logo won and Join opened a PNG.
    func testAssetBeforeJoinLinkDoesNotWin() {
        let body = """
        <img src="https://us06st2.zoom.us/static/6.3.11431/image/new/ZoomLogo_110_25.png" alt="Zoom">
        <p>Join Zoom Meeting</p>
        <a href="https://us06web.zoom.us/j/98765432109?pwd=AbCdEf">https://us06web.zoom.us/j/98765432109?pwd=AbCdEf</a>
        """

        XCTAssertEqual(
            MeetingLinkDetector.firstURL(in: body)?.absoluteString,
            "https://us06web.zoom.us/j/98765432109?pwd=AbCdEf"
        )
    }

    /// An invitation carrying only the logo has no meeting to join. Returning the
    /// asset would put a PNG behind the Join button; nil correctly hides it.
    func testAssetOnlyBodyYieldsNil() {
        let body = #"<img src="https://us06st2.zoom.us/static/6.3.11431/image/new/ZoomLogo_110_25.png">"#

        XCTAssertNil(MeetingLinkDetector.firstURL(in: body))
    }

    /// The filter keys off the path extension, not off Zoom, so it has to leave
    /// every other provider's ordinary link alone.
    func testTeamsLinkIsUnaffected() {
        let body = "Join here: https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc123/0"

        XCTAssertEqual(
            MeetingLinkDetector.firstURL(in: body)?.absoluteString,
            "https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc123/0"
        )
    }

    /// Pattern priority is unchanged by the fix: Zoom still beats Teams across
    /// the whole text, whatever order they appear in.
    func testZoomStillBeatsTeamsRegardlessOfOrder() {
        let body = """
        https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc123/0
        https://us06web.zoom.us/j/98765432109
        """

        XCTAssertEqual(
            MeetingLinkDetector.firstURL(in: body)?.absoluteString,
            "https://us06web.zoom.us/j/98765432109"
        )
    }

    /// Trailing punctuation glued on by prose still gets stripped — the asset
    /// filter runs after that cleanup, so it must not have broken it.
    func testTrailingPunctuationIsStripped() {
        let body = "Use https://us06web.zoom.us/j/98765432109, then dial in."

        XCTAssertEqual(
            MeetingLinkDetector.firstURL(in: body)?.absoluteString,
            "https://us06web.zoom.us/j/98765432109"
        )
    }

    /// The `continue` that skips an asset also lets the loop fall through to the
    /// NEXT pattern, not just the next match of the current one. A Zoom logo with
    /// no Zoom join link must therefore yield the Teams link, even though Zoom
    /// outranks Teams.
    func testAssetOnlyMatchFallsThroughToTheNextProvider() {
        let body = """
        <img src="https://us06st2.zoom.us/static/6.3.11431/image/new/ZoomLogo_110_25.png">
        https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc123/0
        """

        XCTAssertEqual(
            MeetingLinkDetector.firstURL(in: body)?.absoluteString,
            "https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc123/0"
        )
    }

    /// The extension is lowercased before the lookup, so a shouting filename is
    /// still an asset.
    func testUppercaseAssetExtensionIsStillSkipped() {
        let body = #"<img src="https://us06st2.zoom.us/static/ZoomLogo_110_25.PNG">"#

        XCTAssertNil(MeetingLinkDetector.firstURL(in: body))
    }

    /// The filter reads `pathExtension`, which ignores the query string — so an
    /// asset with a cache-busting parameter is still recognised as one.
    func testAssetWithQueryStringIsStillSkipped() {
        let body = #"<img src="https://us06st2.zoom.us/static/ZoomLogo_110_25.png?v=6.3.11431">"#

        XCTAssertNil(MeetingLinkDetector.firstURL(in: body))
    }

    /// **The tradeoff, pinned deliberately.** The filter keys off the path
    /// extension alone, so a real join URL whose path happens to end in one of
    /// those extensions is discarded and the row loses its Join button. Judged
    /// acceptable — no provider issues join links shaped like this — but it is a
    /// real edge, and this test is here so that changing it is a decision rather
    /// than a surprise.
    func testJoinURLEndingInAFilteredExtensionIsDiscarded() {
        let body = "https://us06web.zoom.us/j/abc.js"

        XCTAssertNil(MeetingLinkDetector.firstURL(in: body))
    }

    // MARK: - SimplePractice

    /// Fabricated — the real appointment id is private and deliberately not in
    /// this repo. Only the *shape* matters to the pattern.
    private static let simplePracticeRoom =
        "https://video.simplepractice.com/appt-0123456789abcdef0123456789abcdef?origin=client"

    /// Builds the minimum `MeetingEvent` needed to exercise `joinURL`, which is
    /// the property the UI actually gates its Join affordances on.
    private func event(notes: String, location: String?) -> MeetingEvent {
        MeetingEvent(
            id: "ek:test#0",
            title: "Appointment",
            startDate: Date(),
            endDate: Date().addingTimeInterval(3000),
            location: location,
            rawDetails: notes,
            calendarTitle: "Personal",
            calendarColor: nil,
            source: .eventKit,
            attendees: []
        )
    }

    func testSimplePracticeRoomIsDetected() {
        XCTAssertEqual(
            MeetingLinkDetector.firstURL(in: "Your appointment: \(Self.simplePracticeRoom)")?.absoluteString,
            Self.simplePracticeRoom
        )
    }

    /// `joinURL` scans notes first. This is the path a SimplePractice booking
    /// email actually takes, and the one that was returning nil.
    func testJoinURLFindsSimplePracticeInNotes() {
        let ev = event(notes: "Video appointment\n\(Self.simplePracticeRoom)", location: nil)

        XCTAssertEqual(ev.joinURL?.absoluteString, Self.simplePracticeRoom)
    }

    /// …and falls back to `location` when the notes carry nothing. Covered
    /// separately because it is a different branch of `joinURL`, not just a
    /// different input to the same regex.
    func testJoinURLFindsSimplePracticeInLocation() {
        let ev = event(notes: "", location: Self.simplePracticeRoom)

        XCTAssertEqual(ev.joinURL?.absoluteString, Self.simplePracticeRoom)
    }

    /// The `?origin=client` parameter is part of the room link and must survive
    /// detection — the trailing-punctuation trim must not eat it.
    func testSimplePracticeQueryStringSurvives() {
        let url = MeetingLinkDetector.firstURL(in: Self.simplePracticeRoom)

        XCTAssertEqual(url?.query, "origin=client")
    }

    /// The new pattern sits inside the same loop as the others, so it inherits
    /// the 2.1.1 asset filter for free. Pinned so a future refactor that moves
    /// the filter cannot quietly exempt this provider.
    func testSimplePracticeAssetIsSkipped() {
        let body = #"<img src="https://video.simplepractice.com/assets/logo.png">"#

        XCTAssertNil(MeetingLinkDetector.firstURL(in: body))
    }

    /// Why the host is exact rather than the `[a-zA-Z0-9.-]*` wildcard the Zoom
    /// and Webex entries use: a wildcard would turn the marketing site and the
    /// login page into Join buttons that land on a sign-in screen.
    func testSimplePracticeMarketingAndLoginHostsAreNotJoinLinks() {
        XCTAssertNil(MeetingLinkDetector.firstURL(in: "https://www.simplepractice.com/pricing"))
        XCTAssertNil(MeetingLinkDetector.firstURL(in: "https://account.simplepractice.com/login"))
    }

    /// Appending the pattern last must not reorder anything: a body carrying
    /// both still resolves to the higher-priority provider.
    func testExistingProviderStillWinsOverSimplePractice() {
        let body = """
        \(Self.simplePracticeRoom)
        https://us06web.zoom.us/j/98765432109
        """

        XCTAssertEqual(
            MeetingLinkDetector.firstURL(in: body)?.absoluteString,
            "https://us06web.zoom.us/j/98765432109"
        )
    }
}
