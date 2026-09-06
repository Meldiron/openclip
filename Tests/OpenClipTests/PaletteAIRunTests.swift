import XCTest
import AppKit
import SwiftUI
import Core
@testable import OpenClip

/// Running an AI preset from the search palette. The popup's AI flow snapshots the selection and
/// dismisses the popup itself, so the palette must not dismiss first: a palette opened straight
/// from the hotkey is *hidden* by exiting search, which clears the action context, and the preset
/// then never ran ("Cannot run AI preset: currentActionContext is nil"). From the bar the same
/// exit only returned to the bar, which is why AI appeared to work there.
@MainActor
final class PaletteAIRunTests: XCTestCase {
    private final class Recorder {
        var events: [String] = []
    }

    private func aiPreset(_ id: String) -> MockAction {
        MockAction(id: id, shouldBeEnabled: true,
                   chrome: ActionChrome(badge: .none, rowStyle: .standard, popupBehavior: .perform, source: .ai))
    }

    private func context() -> ActionContext {
        let selection = SelectionContext(
            text: "hello world",
            sourceApp: AppIdentity(bundleIdentifier: "com.test", localizedName: "Test"),
            cursorPosition: .zero,
            timestamp: Date(),
            appPolicy: .default
        )
        return ActionContext(selection: selection, modifiers: [])
    }

    /// Drives the production view stack: PopupView in search mode, the row picked with ⌘1.
    private func runFirstPaletteRow(recorder: Recorder) throws {
        let store = PopupModeStore()
        store.mode = .search
        let view = PopupView(
            actions: [],
            allActions: [],
            context: context(),
            modeStore: store,
            onExitSearch: { recorder.events.append("exit-search") },
            onResult: { _ in recorder.events.append("result") },
            onRunAI: { _ in recorder.events.append("run-ai") }
        )
        .environment(\.colorScheme, .dark)

        let host = NSHostingView(rootView: AnyView(view))
        host.layoutSubtreeIfNeeded()
        let panel = PopupPanel()
        panel.allowsKey = true
        panel.contentView = host
        panel.setFrame(NSRect(x: 300, y: 300, width: 360, height: 320), display: true)
        panel.makeKeyAndOrderFront(nil)
        defer { panel.orderOut(nil) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))

        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
            context: nil, characters: "1", charactersIgnoringModifiers: "1", isARepeat: false, keyCode: 18
        ))
        XCTAssertTrue(panel.performKeyEquivalent(with: event), "⌘1 must reach the palette")
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    }

    func testAIPresetRunsAndIsNotPrecededByASearchExit() throws {
        TestIsolation.reset()
        defer { TestIsolation.reset() }
        ActionRegistry.shared.register(action: aiPreset("ai.preset.proofread"))

        let recorder = Recorder()
        try runFirstPaletteRow(recorder: recorder)

        XCTAssertEqual(recorder.events, ["run-ai"],
                       "the AI flow must run, and nothing may dismiss the popup before it snapshots the selection")
    }

    /// The ordinary path is unchanged: a non-AI action still performs and reports its result.
    func testOrdinaryActionStillPerformsFromThePalette() throws {
        TestIsolation.reset()
        defer { TestIsolation.reset() }
        ActionRegistry.shared.register(action: MockAction(id: "mock.plain", shouldBeEnabled: true))

        let recorder = Recorder()
        try runFirstPaletteRow(recorder: recorder)

        XCTAssertEqual(recorder.events, ["result"])
        XCTAssertFalse(recorder.events.contains("run-ai"))
    }
}
