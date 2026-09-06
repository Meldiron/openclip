import XCTest
import Core

final class TextDiffTests: XCTestCase {

    private func rendered(_ segments: [TextDiffSegment], kind: TextDiffSegment.Kind) -> String {
        segments.filter { $0.kind == kind }.map(\.text).joined()
    }

    /// The old text must be reconstructible from equal+delete and the new one from equal+insert —
    /// the property that makes the card's rendering honest.
    private func assertRoundTrip(_ old: String, _ new: String, file: StaticString = #filePath, line: UInt = #line) {
        let segments = TextDiff.segments(from: old, to: new)
        let reconstructedOld = segments.filter { $0.kind != .insert }.map(\.text).joined()
        let reconstructedNew = segments.filter { $0.kind != .delete }.map(\.text).joined()
        XCTAssertEqual(reconstructedOld, old, "delete+equal must rebuild the original", file: file, line: line)
        XCTAssertEqual(reconstructedNew, new, "insert+equal must rebuild the result", file: file, line: line)
    }

    func testIdenticalTextIsOneEqualSegment() {
        let segments = TextDiff.segments(from: "hey how are you", to: "hey how are you")
        XCTAssertEqual(segments, [TextDiffSegment(kind: .equal, text: "hey how are you")])
        XCTAssertEqual(TextDiff.equalRatio(of: segments), 1.0)
    }

    func testEmptyInputs() {
        XCTAssertEqual(TextDiff.segments(from: "", to: ""), [])
        XCTAssertEqual(TextDiff.segments(from: "", to: "added"), [TextDiffSegment(kind: .insert, text: "added")])
        XCTAssertEqual(TextDiff.segments(from: "gone", to: ""), [TextDiffSegment(kind: .delete, text: "gone")])
    }

    /// The proofread case from the card: capitalization + punctuation edits show as small
    /// insert/delete runs inside a mostly-equal body.
    func testProofreadEditProducesCharacterLevelRuns() {
        let old = "hey how are you doing"
        let new = "Hey, how are you doing?"
        let segments = TextDiff.segments(from: old, to: new)
        assertRoundTrip(old, new)
        XCTAssertEqual(rendered(segments, kind: .delete), "h")
        XCTAssertEqual(rendered(segments, kind: .insert), "H,?")
        XCTAssertGreaterThan(TextDiff.equalRatio(of: segments), 0.8,
                             "a light edit must read as mostly-equal so the card opens on the diff")
    }

    func testPureInsertionAndDeletionKeepSurroundingTextEqual() {
        let inserted = TextDiff.segments(from: "the cat sat", to: "the black cat sat")
        assertRoundTrip("the cat sat", "the black cat sat")
        XCTAssertEqual(rendered(inserted, kind: .insert), "black ")
        XCTAssertTrue(inserted.allSatisfy { $0.kind != .delete })

        let deleted = TextDiff.segments(from: "the black cat sat", to: "the cat sat")
        assertRoundTrip("the black cat sat", "the cat sat")
        XCTAssertEqual(rendered(deleted, kind: .delete), "black ")
        XCTAssertTrue(deleted.allSatisfy { $0.kind != .insert })
    }

    func testSegmentsAreCoalescedNotPerCharacter() {
        let segments = TextDiff.segments(from: "abcdef", to: "abXYZdef")
        XCTAssertEqual(segments, [
            TextDiffSegment(kind: .equal, text: "ab"),
            TextDiffSegment(kind: .delete, text: "c"),
            TextDiffSegment(kind: .insert, text: "XYZ"),
            TextDiffSegment(kind: .equal, text: "def")
        ])
    }

    func testGraphemeClustersAreNeverSplit() {
        let old = "ship it 🙂"
        let new = "ship it 👍🏽"
        let segments = TextDiff.segments(from: old, to: new)
        assertRoundTrip(old, new)
        XCTAssertEqual(rendered(segments, kind: .delete), "🙂")
        XCTAssertEqual(rendered(segments, kind: .insert), "👍🏽")
    }

    func testUnrelatedRewriteFallsBackToWholesaleReplacement() {
        // Far beyond `maxEditDistance`: the honest answer is "this was replaced", not a shredded
        // character salad — and it must still round-trip.
        let old = String(repeating: "a", count: 1_200)
        let new = String(repeating: "b", count: 1_200)
        let segments = TextDiff.segments(from: old, to: new)
        assertRoundTrip(old, new)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments.first?.kind, .delete)
        XCTAssertEqual(segments.last?.kind, .insert)
        XCTAssertEqual(TextDiff.equalRatio(of: segments), 0.0)
    }

    func testLongTextWithSmallEditStillDiffsThroughPrefixSuffixTrim() {
        let filler = String(repeating: "lorem ipsum dolor sit amet. ", count: 400) // ~11k chars
        let old = filler + "teh end"
        let new = filler + "the end"
        let segments = TextDiff.segments(from: old, to: new)
        assertRoundTrip(old, new)
        XCTAssertGreaterThan(TextDiff.equalRatio(of: segments), 0.99,
                             "prefix/suffix trimming must keep a long text diffable")
        XCTAssertLessThanOrEqual(rendered(segments, kind: .delete).count, 3)
    }

    func testOversizedComparisonStaysBounded() {
        let old = String(repeating: "x", count: 20_000)
        let new = String(repeating: "y", count: 20_000)
        let started = Date()
        let segments = TextDiff.segments(from: old, to: new)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0, "the length budget must short-circuit")
        assertRoundTrip(old, new)
        XCTAssertEqual(segments.count, 2)
    }

    func testEqualRatioSeparatesEditsFromRewrites() {
        let edit = TextDiff.segments(from: "hey how are you doing", to: "Hey, how are you doing?")
        let rewrite = TextDiff.segments(from: "hey how are you doing", to: "Bonjour, comment allez-vous ?")
        XCTAssertGreaterThanOrEqual(TextDiff.equalRatio(of: edit), 0.5)
        XCTAssertLessThan(TextDiff.equalRatio(of: rewrite), 0.5)
    }
}
