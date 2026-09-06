import XCTest
import AppKit
import Core
@testable import OpenClip

@MainActor
final class PopupKeyModeTests: XCTestCase {

    private func makeController() -> PopupWindowController {
        let isolatedPasteboard = NSPasteboard(name: NSPasteboard.Name("OpenClipTest-\(UUID().uuidString)"))
        let controller = PopupWindowController(resultHandler: DefaultActionResultHandler(pasteboard: isolatedPasteboard))
        controller.startTestSession(for: SelectionContext(
            text: "hello world",
            sourceApp: AppIdentity(bundleIdentifier: "com.test", localizedName: "Test"),
            cursorPosition: CGPoint(x: 400, y: 400),
            timestamp: Date(),
            appPolicy: .default
        ))
        return controller
    }

    func testShowCapturesFrontmostAppOnce() {
        let controller = makeController()
        defer { controller.hide() }
        // The capture guard in show(for:) skips when OpenClip itself is frontmost (the test host
        // during xcodebuild test) or when no app is frontmost (headless CI), so previousFrontmostApp
        // may be nil here. The non-nil capture claim only holds when a non-OpenClip app is frontmost.
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.bundleIdentifier != Bundle.main.bundleIdentifier {
            XCTAssertEqual(controller.previousFrontmostApp, frontmost,
                           "show must capture the frontmost source app")
        }
        // Capture-once holds in every environment: re-entry must never re-capture.
        let capturedAtShow = controller.previousFrontmostApp
        controller.enterSearch()
        XCTAssertEqual(controller.previousFrontmostApp, capturedAtShow, "re-entry must not re-capture")
        controller.exitSearch()
        controller.enterSearch()
        XCTAssertEqual(controller.previousFrontmostApp, capturedAtShow,
                       "re-entry after exit must not re-capture")
    }

    func testKeyedPanelNeverStoresOpenClip() {
        let controller = makeController()
        defer { controller.hide() }
        XCTAssertNotEqual(controller.previousFrontmostApp?.bundleIdentifier, Bundle.main.bundleIdentifier,
                          "a session must never store OpenClip itself as the source app")
        let capturedAtShow = controller.previousFrontmostApp
        controller.enterSearch()
        controller.exitSearch()
        XCTAssertEqual(controller.previousFrontmostApp, capturedAtShow,
                       "only show(for:) captures the source app; enterSearch never re-captures")
        controller.hide()
        XCTAssertNil(controller.previousFrontmostApp, "hide() clears the session capture")
    }

    func testExitSearchKeepsFrontmostApp() {
        let controller = makeController()
        defer { controller.hide() }
        let captured = controller.previousFrontmostApp
        controller.enterSearch()
        controller.exitSearch()
        XCTAssertEqual(controller.previousFrontmostApp, captured,
                       "exitSearch must not clear the session source app")
        controller.enterSearch()
        XCTAssertEqual(controller.previousFrontmostApp, captured,
                       "re-entering search after exit must reuse the original source app")
    }

    func testHideClearsFrontmostApp() {
        let controller = makeController()
        controller.enterSearch()
        controller.exitSearch()
        controller.hide()
        XCTAssertNil(controller.previousFrontmostApp, "only hide() ends the session")
    }

    func testSearchPanelBecomesKeyAndReturnsToNonKey() {
        let panel = PopupPanel()
        XCTAssertFalse(panel.allowsKey)
        panel.allowsKey = true
        XCTAssertTrue(panel.canBecomeKey)
        panel.allowsKey = false
        XCTAssertFalse(panel.canBecomeKey)
    }

    func testSubBarEscapeInterception() {
        let controller = makeController()
        defer { controller.hide() }

        controller.modeStore.isSubBarActive = true
        guard let escEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false,
            keyCode: 53
        ) else {
            XCTFail("Failed to construct Escape key event")
            return
        }

        // First Escape closes the sub-bar, but does not call hide()
        controller.handleEvent(escEvent)
        XCTAssertFalse(controller.modeStore.isSubBarActive, "Escape should close the sub-bar")
        XCTAssertTrue(controller.isVisible, "First Escape should keep popup visible")

        // Second Escape dismisses the popup (calling hide())
        controller.handleEvent(escEvent)
        XCTAssertFalse(controller.isVisible, "Second Escape should dismiss the popup")
    }

    func testHideResetsSubBarActive() {
        let controller = makeController()
        controller.modeStore.isSubBarActive = true
        XCTAssertTrue(controller.modeStore.isSubBarActive)

        controller.hide()
        XCTAssertFalse(controller.modeStore.isSubBarActive, "hide() must reset isSubBarActive")
    }

    func testDirectSearchSessionDismissesOnExitSearch() {
        let isolatedPasteboard = NSPasteboard(name: NSPasteboard.Name("OpenClipTest-\(UUID().uuidString)"))
        let controller = PopupWindowController(resultHandler: DefaultActionResultHandler(pasteboard: isolatedPasteboard))
        controller.startTestSession(
            for: SelectionContext(
                text: "hello world",
                sourceApp: AppIdentity(bundleIdentifier: "com.test", localizedName: "Test"),
                cursorPosition: CGPoint(x: 400, y: 400),
                timestamp: Date(),
                appPolicy: .default
            ),
            initialMode: .search
        )

        XCTAssertTrue(controller.openedDirectlyInSearch, "Direct search start must set openedDirectlyInSearch")
        XCTAssertEqual(controller.modeStore.mode, .search)
        XCTAssertTrue(controller.isVisible)

        controller.exitSearch()
        XCTAssertFalse(controller.isVisible, "exitSearch on a direct search session must dismiss completely")
        XCTAssertFalse(controller.openedDirectlyInSearch, "hide() must clear openedDirectlyInSearch")
    }

    func testBarSessionCollapsesBackToBarOnExitSearch() {
        let controller = makeController()
        defer { controller.hide() }

        let panel = PopupPanel()
        panel.orderFront(nil)
        controller.panel = panel

        XCTAssertFalse(controller.openedDirectlyInSearch, "Bar start must have openedDirectlyInSearch == false")
        XCTAssertEqual(controller.modeStore.mode, .actions)

        controller.enterSearch()
        XCTAssertEqual(controller.modeStore.mode, .search)

        controller.exitSearch()
        XCTAssertEqual(controller.modeStore.mode, .actions, "exitSearch on a bar session must collapse back to .actions")
        XCTAssertTrue(controller.isVisible, "exitSearch on a bar session must keep the popup visible")
    }

    /// A palette opened straight from the hotkey is placed like the bar the mouse opens: anchored
    /// on the selection, honoring the placement preferences. (It used to be centred on the main
    /// screen — this test asserted that, and the centring is what the user saw as the palette
    /// appearing nowhere near their text.)
    func testDirectSearchSessionIsAnchoredOnTheSelection() {
        let store = MemorySettingsStore()
        store.set(.popupAlignment, value: PopupBarAlignment.left.rawValue)
        store.set(.popupVerticalPosition, value: PopupVerticalPosition.below.rawValue)
        let isolatedPasteboard = NSPasteboard(name: NSPasteboard.Name("OpenClipTest-\(UUID().uuidString)"))
        let controller = PopupWindowController(
            resultHandler: DefaultActionResultHandler(pasteboard: isolatedPasteboard),
            settingsStore: store
        )
        defer { controller.hide() }

        let screenBounds = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        let cursor = CGPoint(x: screenBounds.minX + 240, y: screenBounds.maxY - 200)
        let context = SelectionContext(
            text: "test selection",
            sourceApp: AppIdentity(bundleIdentifier: "com.test", localizedName: "Test"),
            cursorPosition: cursor,
            timestamp: Date(),
            appPolicy: .default
        )

        controller.show(for: context, initialMode: .search)

        guard let panel = controller.panel else {
            XCTFail("Panel must be created on show")
            return
        }

        XCTAssertEqual(panel.frame.origin.x, cursor.x - PopupPositioner.firstActionCenterOffset, accuracy: 1.0,
                       "left alignment must anchor the palette on the selection")
        XCTAssertLessThanOrEqual(panel.frame.maxY, cursor.y,
                                 "the .below vertical preference must be honored")
    }

    func testEnterSearchWithButtonLocalFrameDoesNotExceedBarMaxX() {
        let controller = makeController()
        defer { controller.hide() }

        let panel = PopupPanel()
        panel.orderFront(nil)
        // Initial bar frame: x: 300, y: 300, width: 350, height: 50 -> maxX is 650
        panel.setFrame(NSRect(x: 300, y: 300, width: 350, height: 50), display: false)
        controller.panel = panel

        // Simulate clicking search button at far right: local x = 310, width = 34 -> midX = 327
        let buttonFrame = CGRect(x: 310, y: 8, width: 34, height: 34)
        controller.enterSearch(buttonLocalFrame: buttonFrame)

        let searchPanelWidth = PopupMetrics.searchPanelWidth
        let barMaxX: CGFloat = 650

        XCTAssertLessThanOrEqual(panel.frame.maxX, barMaxX + 0.1, "Search palette frame must not exceed right popup bar edge")
        XCTAssertLessThanOrEqual(panel.frame.midX + searchPanelWidth / 2, barMaxX + 0.1, "Search palette center + halfWidth must stay within barMaxX")
    }
}
