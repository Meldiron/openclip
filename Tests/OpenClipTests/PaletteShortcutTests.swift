import XCTest
import AppKit
import SwiftUI
import Core
@testable import OpenClip

/// ⌘1…⌘9 select a palette row outright.
///
/// These tests drive `performKeyEquivalent` — the path `NSApplication` actually uses for a
/// command-modified key. An earlier version of this suite called `panel.sendEvent`, which skips
/// the key-equivalent dispatch and delivers straight to `keyDown:`; it passed while the shipped
/// app only beeped, because SwiftUI's `onKeyPress` never sees a ⌘-digit.
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

    /// Only plain ⌘ + 1...9 counts: a bare digit types into the field, and ⌘⌥/⌘⇧/⌃ combinations
    /// belong to somebody else.
    func testCommandDigitParsing() throws {
        func event(_ characters: String, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: 0
            ))
        }
        XCTAssertEqual(PopupSearchView.commandDigitRow(for: try event("1", [.command])), 1)
        XCTAssertEqual(PopupSearchView.commandDigitRow(for: try event("9", [.command])), 9)
        XCTAssertEqual(PopupSearchView.commandDigitRow(for: try event("3", [.command, .capsLock])), 3,
                       "caps lock rides along in every event and must not disarm the shortcut")
        XCTAssertNil(PopupSearchView.commandDigitRow(for: try event("0", [.command])), "⌘0 is not a row")
        XCTAssertNil(PopupSearchView.commandDigitRow(for: try event("2", [])), "a bare digit types")
        XCTAssertNil(PopupSearchView.commandDigitRow(for: try event("2", [.command, .option])))
        XCTAssertNil(PopupSearchView.commandDigitRow(for: try event("2", [.command, .shift])))
        XCTAssertNil(PopupSearchView.commandDigitRow(for: try event("a", [.command])))
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
        XCTAssertTrue(panel.performKeyEquivalent(with: event),
                      "the palette must consume ⌘2 — an unhandled key equivalent is what beeps")
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        XCTAssertEqual(recorder.performed, ["mock.second"],
                       "⌘2 must run the second row, not the selected one")
    }

    /// The production stack, not a hand-built palette: the controller's real panel, PopupView and
    /// palette, asked through the same `performKeyEquivalent` entry point `NSApplication` uses.
    /// This is what proves the catcher is reachable inside the app's actual view tree.
    func testCommandDigitIsConsumedByTheRealPalettePanel() throws {
        TestIsolation.reset()
        defer { TestIsolation.reset() }
        ActionRegistry.shared.register(action: makeAction("mock.palette.row"))

        let store = MemorySettingsStore()
        let isolatedPasteboard = NSPasteboard(name: NSPasteboard.Name("OpenClipTest-\(UUID().uuidString)"))
        let controller = PopupWindowController(
            resultHandler: DefaultActionResultHandler(pasteboard: isolatedPasteboard),
            settingsStore: store
        )
        let screenBounds = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        let selection = SelectionContext(
            text: "hello world",
            sourceApp: AppIdentity(bundleIdentifier: "com.test", localizedName: "Test"),
            cursorPosition: CGPoint(x: screenBounds.midX, y: screenBounds.midY),
            timestamp: Date(),
            appPolicy: .default
        )
        controller.show(for: selection, pasteAvailable: true, initialMode: .search)
        defer { controller.hide() }
        let panel = try XCTUnwrap(controller.panel)
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))

        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
            context: nil, characters: "1", charactersIgnoringModifiers: "1", isARepeat: false, keyCode: 18
        ))

        XCTAssertTrue(panel.performKeyEquivalent(with: event),
                      "⌘1 must be consumed inside the real palette panel — an unhandled key equivalent beeps")
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
        XCTAssertFalse(panel.performKeyEquivalent(with: event),
                       "a digit past the results must fall through, not be swallowed")
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        XCTAssertTrue(recorder.performed.isEmpty)
    }
}
