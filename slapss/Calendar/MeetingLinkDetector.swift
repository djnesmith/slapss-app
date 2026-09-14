//
//  MeetingLinkDetector.swift
//  slapss
//
//  Finds the join URL inside an event's body/location text. Prioritized so a
//  Zoom link wins over a generic URL also embedded in the event description.
//

import Foundation

enum MeetingLinkDetector {
    /// Ordered patterns. First match wins. Each pattern matches the full URL
    /// including its host so we extract the original link rather than reconstructing.
    private static let patterns: [(name: String, regex: NSRegularExpression)] = {
        let raws: [(String, String)] = [
            ("Zoom",  #"https?://[a-zA-Z0-9.-]*zoom\.us/[^\s<>"]+"#),
            ("Teams", #"https?://teams\.microsoft\.com/[^\s<>"]+"#),
            ("Teams Live", #"https?://teams\.live\.com/[^\s<>"]+"#),
            ("Meet",  #"https?://meet\.google\.com/[^\s<>"]+"#),
            ("Webex", #"https?://[a-zA-Z0-9.-]*webex\.com/[^\s<>"]+"#),
            ("Whereby", #"https?://[a-zA-Z0-9.-]*whereby\.com/[^\s<>"]+"#),
            ("Around", #"https?://meet\.around\.co/[^\s<>"]+"#),
            // Exact host, not the `[a-zA-Z0-9.-]*` wildcard used for Zoom,
            // Webex and Whereby: those issue a subdomain per customer
            // (`us06web.zoom.us`, `acme.webex.com`), whereas every
            // SimplePractice video room is served from this one host. A
            // wildcard would also swallow `www.` and `account.`
            // simplepractice.com, which are marketing and login pages — a
            // Join button landing on a sign-in screen is worse than none.
            // Appended last so the seven existing providers keep their
            // resolution order exactly; this entry can only add a match
            // where there was none.
            ("SimplePractice", #"https?://video\.simplepractice\.com/[^\s<>"]+"#),
        ]
        return raws.compactMap { name, raw in
            guard let regex = try? NSRegularExpression(pattern: raw, options: [.caseInsensitive]) else {
                return nil
            }
            return (name, regex)
        }
    }()

    /// Static assets a provider's own domain serves inside HTML invitations.
    /// Zoom's Outlook add-in embeds `https://<sub>.zoom.us/static/.../ZoomLogo_110_25.png`
    /// *above* the join link, so a first-match scan opened the logo instead of
    /// the meeting (user report, September 2026).
    private static let assetExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "svg", "webp", "ico", "css", "js"]

    /// Returns the first recognized meeting URL in the input, or nil.
    /// `@MainActor` because NSRegularExpression methods are MainActor-isolated
    /// in the Xcode 26 SDK; all callers are already on the main actor.
    @MainActor
    static func firstURL(in text: String) -> URL? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for (_, regex) in patterns {
            for match in regex.matches(in: text, options: [], range: range) {
                guard let swiftRange = Range(match.range, in: text) else { continue }
                let raw = String(text[swiftRange])
                // Strip trailing punctuation that often gets glued to URLs
                // when parsing email-style descriptions.
                let cleaned = raw.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:)]"))
                guard let url = URL(string: cleaned),
                      !assetExtensions.contains(url.pathExtension.lowercased()) else { continue }
                return url
            }
        }
        return nil
    }
}
