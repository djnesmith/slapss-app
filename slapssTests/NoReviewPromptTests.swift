//
//  NoReviewPromptTests.swift
//  slapssTests
//

import XCTest

/// This fork drops upstream's App Store rating prompt (added in 2.2.3).
/// Fails if an upstream merge brings it back.
final class NoReviewPromptTests: XCTestCase {

    func testAppSourcesHaveNoReviewPrompt() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("slapss")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "no sources found at \(sources.path)")

        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for banned in ["requestReview", "StoreKit", "ReviewPrompt"] {
                XCTAssertFalse(text.contains(banned), "\(file.lastPathComponent) contains \(banned)")
            }
        }
    }
}
