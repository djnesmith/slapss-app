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
}
