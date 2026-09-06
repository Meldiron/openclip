import XCTest
import AppKit
@testable import OpenClip
@testable import Core

/// Regression coverage for the hotkey trigger path: ⌥⌘C must obey the gating that actually
/// applies to an explicit request — Pause, app exclusion (including OpenClip itself), per-app
/// `disabled` rules, and the text substantiality/length contract — instead of retrieving and
/// injecting a synthetic ⌘C into any frontmost app unconditionally. "Appear Automatically" is
/// **not** one of those gates: it owns the automatic popup only.
@MainActor
final class HotkeyManagerTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run { TestIsolation.reset() }
    }

    /// "Appear Automatically" off means the popup stops following selections — the shortcut is an
    /// explicit request and must still work. It used to be gated on the same setting, so the
    /// hotkey silently did nothing whenever the toggle was off.
    func testAutomaticAppearanceOffStillAllowsTheHotkey() {
        let store = MemorySettingsStore()
        store.set(.isAppEnabled, value: false)
        let app = MockFrontmostApp(bundleID: "com.apple.TextEdit")
        XCTAssertTrue(HotkeyManager.triggerAllowed(frontmost: app, settingsStore: store))
    }

    func testNoIdentifiableTargetNeverTriggers() {
        // Covers both a nil frontmost app and one without a bundle ID: previously this fell back
        // to OpenClip itself.
        XCTAssertFalse(HotkeyManager.triggerAllowed(frontmost: nil))
        XCTAssertFalse(HotkeyManager.triggerAllowed(frontmost: MockFrontmostApp(bundleID: nil)))
    }

    func testExcludedAppsNeverTrigger() {
        // A bundle from AppFilter's exclusion list must be rejected even when enabled.
        let excluded = MockFrontmostApp(bundleID: "com.adobe.photoshop")
        XCTAssertFalse(HotkeyManager.triggerAllowed(frontmost: excluded))
    }

    func testAppWithDisabledRuleNeverTriggers() {
        RuleEngine.shared.addOrUpdateRule(AppRule(bundleIdentifiers: ["com.test.disabled"], disabled: true))
        let app = MockFrontmostApp(bundleID: "com.test.disabled")
        XCTAssertFalse(HotkeyManager.triggerAllowed(frontmost: app))
    }

    func testAppWithHotkeyOnlyRuleTriggers() {
        RuleEngine.shared.addOrUpdateRule(AppRule(bundleIdentifiers: ["com.test.hotkeyonly"], hotkeyOnly: true))
        let app = MockFrontmostApp(bundleID: "com.test.hotkeyonly")
        XCTAssertTrue(HotkeyManager.triggerAllowed(frontmost: app))
    }

    func testOrdinaryForegroundAppTriggers() {
        let ordinary = MockFrontmostApp(bundleID: "com.apple.TextEdit")
        XCTAssertTrue(HotkeyManager.triggerAllowed(frontmost: ordinary))
    }

    func testPauseUntilTimestampBlocksTrigger() {
        let store = MemorySettingsStore()
        let app = MockFrontmostApp(bundleID: "com.apple.TextEdit")

        // Unpaused: allowed
        store.set(.pauseUntilTimestamp, value: 0.0)
        XCTAssertTrue(HotkeyManager.triggerAllowed(frontmost: app, settingsStore: store))

        // Paused in future: blocked
        store.set(.pauseUntilTimestamp, value: Date().timeIntervalSince1970 + 1800)
        XCTAssertFalse(HotkeyManager.triggerAllowed(frontmost: app, settingsStore: store))

        // Expired pause in past: allowed
        store.set(.pauseUntilTimestamp, value: Date().timeIntervalSince1970 - 10)
        XCTAssertTrue(HotkeyManager.triggerAllowed(frontmost: app, settingsStore: store))
    }
}

/// `NSRunningApplication` cannot be constructed with an arbitrary bundle ID; the gate only reads
/// `bundleIdentifier`, so a lightweight stand-in keeps the tests hermetic. `triggerAllowed` takes
/// an `NSRunningApplication?`, so the mock subclasses it.
private final class MockFrontmostApp: NSRunningApplication {
    private let bundleID: String?

    init(bundleID: String?) {
        self.bundleID = bundleID
        super.init()
    }

    override var bundleIdentifier: String? { bundleID }
}
