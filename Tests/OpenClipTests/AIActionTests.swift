// AIActionTests.swift
// OpenClipTests

import XCTest
@testable import OpenClip
@testable import Core

@MainActor
final class AIActionTests: XCTestCase {
    private func makeContext(text: String) -> ActionContext {
        let selection = SelectionContext(
            text: text,
            sourceApp: AppIdentity(bundleIdentifier: "com.test", localizedName: "Test"),
            cursorPosition: .zero,
            timestamp: Date(),
            appPolicy: .default
        )
        return ActionContext(selection: selection)
    }

    func testPerformReturnsSuccessWhenSelectionIsEmpty() async throws {
        let action = AIAction(presetID: "proofread", title: "Proofread")
        let context = makeContext(text: "")
        
        let result = try await action.perform(context)
        guard case .success = result else {
            XCTFail("Expected .success, got \(result)")
            return
        }
    }

    func testAIActionIconDefaultMatchesPresetIcon() {
        let action = AIAction(presetID: "proofread", title: "Proofread")
        XCTAssertEqual(action.icon, .text("Proofread"))
    }

    // MARK: - Preset ordering (drag to reorder in Preferences → AI → Actions)

    private var sample: [AIActionPreset] {
        ["proofread", "rewrite", "summarize", "explain"].map {
            AIActionPreset(id: $0, title: $0, prompt: "p", isEnabled: true)
        }
    }

    /// Dropping a row onto an earlier one takes that slot; everything below shifts down.
    func testMovingAPresetUpTakesTheTargetSlot() {
        let reordered = AIServiceManager.reordering(sample, moving: "explain", to: 0)
        XCTAssertEqual(reordered.map(\.id), ["explain", "proofread", "rewrite", "summarize"])
    }

    /// Moving down lands in the target's slot too (the rows above close the gap first).
    func testMovingAPresetDownTakesTheTargetSlot() {
        let reordered = AIServiceManager.reordering(sample, moving: "proofread", to: 2)
        XCTAssertEqual(reordered.map(\.id), ["rewrite", "summarize", "proofread", "explain"])
    }

    func testMovingToItsOwnIndexIsANoOp() {
        XCTAssertEqual(AIServiceManager.reordering(sample, moving: "rewrite", to: 1).map(\.id),
                       sample.map(\.id))
    }

    /// Nothing traps: an unknown id or an out-of-range destination is handled, not crashed on.
    func testUnknownIDAndOutOfRangeDestinationAreSafe() {
        XCTAssertEqual(AIServiceManager.reordering(sample, moving: "nope", to: 0).map(\.id), sample.map(\.id))
        XCTAssertEqual(AIServiceManager.reordering(sample, moving: "proofread", to: 99).map(\.id),
                       ["rewrite", "summarize", "explain", "proofread"])
        XCTAssertEqual(AIServiceManager.reordering(sample, moving: "explain", to: -3).map(\.id),
                       ["explain", "proofread", "rewrite", "summarize"])
        XCTAssertEqual(AIServiceManager.reordering([], moving: "proofread", to: 0).count, 0)
    }

    /// A preset keeps its content across a move — reordering must not rewrite prompts or state.
    func testReorderPreservesPresetContent() {
        var presets = sample
        presets[3].prompt = "explain it simply"
        presets[3].isEnabled = false
        let moved = AIServiceManager.reordering(presets, moving: "explain", to: 0)
        XCTAssertEqual(moved.first?.prompt, "explain it simply")
        XCTAssertEqual(moved.first?.isEnabled, false)
    }

    func testAIActionIconForPreset() {
        XCTAssertEqual(AIAction.iconForPreset(presetID: "proofread"), .text("Proofread"))
        XCTAssertEqual(AIAction.iconForPreset(presetID: "rewrite"), .text("Rewrite"))
        XCTAssertEqual(AIAction.iconForPreset(presetID: "summarize"), .text("Summarize"))
        XCTAssertEqual(AIAction.iconForPreset(presetID: "explain"), .text("Explain"))
        XCTAssertEqual(AIAction.iconForPreset(presetID: "translate"), .text("Translate"))
        XCTAssertEqual(AIAction.iconForPreset(presetID: "fix_code"), .text("Fix Code"))
        XCTAssertEqual(AIAction.iconForPreset(presetID: "make_shorter"), .text("Make Shorter"))
        XCTAssertEqual(AIAction.iconForPreset(presetID: "formal_tone"), .text("Formal Tone"))
        XCTAssertEqual(AIAction.iconForPreset(presetID: "custom_other"), .text("custom_other"))
    }
}
