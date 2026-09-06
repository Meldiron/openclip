import XCTest
import AppKit
import SwiftUI
import Core
@testable import OpenClip

/// ⌘1…⌘9 select a palette row outright. The keys are attached to the palette's focused field, so
/// they exist only while the palette is open — pressing ⌘2 anywhere else is none of OpenClip's
/// business.
@MainActor
final class PaletteShortcutTests: XCTestCase {
    private final class Recorder {
        var performed: [String] = []
    }

    private func makeAction(_ id: String) -> MockAction {
        MockAction(id: id, shouldBeEnabled: true)
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

    func testShortcutHintsCoverTheFirstNineRowsOnly() {
        XCTAssertEqual(PopupSearchView.shortcutHint(forRow: 0), "⌘1")
        XCTAssertEqual(PopupSearchView.shortcutHint(forRow: 8), "⌘9")
        XCTAssertNil(PopupSearchView.shortcutHint(forRow: 9), "the tenth row has no shortcut")
        XCTAssertNil(PopupSearchView.shortcutHint(forRow: 40))
        XCTAssertNil(PopupSearchView.shortcutHint(forRow: -1))
        XCTAssertEqual(PopupSearchView.maxShortcutRows, 9)
    }

    /// End-to-end: a real key window hosting the palette, a synthetic ⌘2, and the *second* row's
    /// action runs. This is the part that a pure test cannot cover — whether the keystroke ever
    /// reaches the field's key handler.
    func testCommandDigitRunsThatRow() throws {
        let recorder = Recorder()
        let catalog: [any Action] = ["mock.first", "mock.second", "mock.third"].map { makeAction($0) }
        let palette = PopupSearchView(
            catalog: catalog,
            context: context(),
            resultsAbove: false,
            onResult: { _ in },
            onExit: {},
            onActionPerformed: { recorder.performed.append($0) }
        )
        .environment(\.colorScheme, .dark)

        let host = NSHostingView(rootView: AnyView(palette))
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let panel = PopupPanel()
        panel.allowsKey = true
        panel.contentView = host
        panel.setFrame(NSRect(x: 300, y: 300, width: max(size.width, 320), height: max(size.height, 200)), display: true)
        panel.makeKeyAndOrderFront(nil)
        defer { panel.orderOut(nil) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))

        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panel.windowNumber,
            context: nil,
            characters: "2",
            charactersIgnoringModifiers: "2",
            isARepeat: false,
            keyCode: 19   // kVK_ANSI_2
        ))
        panel.sendEvent(event)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        XCTAssertEqual(recorder.performed, ["mock.second"],
                       "⌘2 must run the second row, not the selected one")
    }

    /// A digit past the end of the list does nothing at all — no run, no crash.
    func testCommandDigitBeyondTheResultsDoesNothing() throws {
        let recorder = Recorder()
        let palette = PopupSearchView(
            catalog: [makeAction("mock.only")],
            context: context(),
            resultsAbove: false,
            onResult: { _ in },
            onExit: {},
            onActionPerformed: { recorder.performed.append($0) }
        )
        .environment(\.colorScheme, .dark)

        let host = NSHostingView(rootView: AnyView(palette))
        host.layoutSubtreeIfNeeded()
        let panel = PopupPanel()
        panel.allowsKey = true
        panel.contentView = host
        panel.setFrame(NSRect(x: 300, y: 300, width: 320, height: 200), display: true)
        panel.makeKeyAndOrderFront(nil)
        defer { panel.orderOut(nil) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))

        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
            context: nil, characters: "5", charactersIgnoringModifiers: "5", isARepeat: false, keyCode: 23
        ))
        panel.sendEvent(event)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        XCTAssertTrue(recorder.performed.isEmpty)
    }
}
