// PasteAvailabilityProbe.swift
// OpenClip
//
// This type finds if the frontmost app can paste. The probe reads the Edit ▸ Paste item through Accessibility.
// If Accessibility is not available, or if the probe exceeds its time limit, the result is unknown.
// The probe does not delay later probes. This type is in the App target because it uses AppKit and AX.
import AppKit
import ApplicationServices
import Core

public protocol PasteAvailabilityProbing: Sendable {
    /// Determines whether the given application supports paste under the active app policy.
    func canPaste(in app: NSRunningApplication?, policy: AppPolicyContext) async -> Bool?
}

public struct PasteAvailabilityProbe: PasteAvailabilityProbing {
    /// This lookup reads Edit ▸ Paste for one process with an optional deadline.
    /// It returns true if Paste is enabled, false if Paste is disabled, and nil if the item is not found or times out.
    /// Production reads the live menu bar. Tests can replace this lookup.
    typealias Lookup = @Sendable (_ pid: pid_t, _ deadline: Date?) -> Bool?

    private let lookup: Lookup
    private let timeout: TimeInterval

    /// Creates a probe instance using live Accessibility menu bar inspection and default timeout.
    public init() {
        let timeout = Constants.pasteProbeTimeout
        self.init(
            lookupWithDeadline: { pid, deadline in
                PasteAvailabilityProbe.editPasteEnabled(pid: pid, deadline: deadline)
            },
            timeout: timeout
        )
    }

    /// Testing initializer allowing callers to supply a pid-only lookup closure and custom timeout.
    init(lookup: @escaping @Sendable (pid_t) -> Bool?, timeout: TimeInterval = Constants.pasteProbeTimeout) {
        self.lookup = { pid, _ in lookup(pid) }
        self.timeout = timeout
    }

    /// Testing initializer allowing callers to supply a deadline-aware lookup closure and custom timeout.
    init(lookupWithDeadline lookup: @escaping Lookup, timeout: TimeInterval = Constants.pasteProbeTimeout) {
        self.lookup = lookup
        self.timeout = timeout
    }

    /// Determines whether the target application can paste, consulting policy overrides first.
    @MainActor
    public func canPaste(in app: NSRunningApplication?, policy: AppPolicyContext) async -> Bool? {
        // App rules can allow or deny paste. Then the probe does not walk the menu bar.
        if !PasteAvailability.needsProbe(policy: policy) {
            return PasteAvailability.effective(policy: policy, probe: nil)
        }
        // The probe needs Accessibility to read the menu bar.
        guard PermissionManager.shared.isAccessibilityGranted,
              let app, app.isTerminated == false else { return nil }
        let pid = app.processIdentifier
        return PasteAvailability.effective(policy: policy, probe: await probePaste(pid: pid))
    }

    /// This concurrent queue runs blocking AX work. A blocked walk does not delay later probes.
    /// AX lookups must not run on the cooperative thread pool. A blocked call would pin one of those threads.
    /// Same design as `SelectionRetrievalCoordinator.axInspectQueue`.
    private static let axProbeQueue = DispatchQueue(label: "com.openclip.ax-probe", qos: .userInitiated, attributes: .concurrent)

    /// This gate limits probes in progress to `Constants.pasteProbeMaxConcurrent`.
    /// The permit is released at the time limit, not when a blocked walk returns (issue #37).
    /// Same design as `SelectionRetrievalCoordinator.InspectConcurrencyGate`.
    private actor ProbeConcurrencyGate {
        private var inFlight = 0

        /// Attempts to acquire an execution permit if under the concurrency limit.
        func tryAcquire(limit: Int) -> Bool {
            guard inFlight < limit else { return false }
            inFlight += 1
            return true
        }

        /// Releases an acquired concurrency permit.
        func release() {
            inFlight -= 1
        }
    }
    private static let probeGate = ProbeConcurrencyGate()

    /// This function runs the Edit ▸ Paste lookup on the blocking queue against `timeout`.
    /// The side that ends the wait (worker or watchdog) also releases the permit.
    /// Tests can call this function. It does not need Accessibility.
    nonisolated func probePaste(pid: pid_t) async -> Bool? {
        guard await PasteAvailabilityProbe.probeGate.tryAcquire(limit: Constants.pasteProbeMaxConcurrent) else {
            Log.selection.debug("paste probe: concurrency cap reached for pid \(pid, privacy: .public); reporting unknown")
            return nil
        }
        let lookup = self.lookup
        let timeoutSeconds = self.timeout
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool?, Never>) in
            let resume = OnceResume<Bool?>()
            let watchdog = TaskBox()

            watchdog.set(Task {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                if resume.resume(continuation, with: nil) {
                    Task.detached { await PasteAvailabilityProbe.probeGate.release() }
                    Log.selection.debug("paste probe: Edit ▸ Paste lookup for pid \(pid, privacy: .public) exceeded \(timeoutSeconds, privacy: .public)s deadline; reporting unknown")
                }
            })

            PasteAvailabilityProbe.axProbeQueue.async {
                let enabled = lookup(pid, deadline)
                if resume.resume(continuation, with: enabled) {
                    watchdog.cancel()
                    Task.detached { await PasteAvailabilityProbe.probeGate.release() }
                } else {
                    Log.selection.debug("paste probe: abandoned lookup for pid \(pid, privacy: .public) finished after the deadline")
                }
            }
        }
    }

    /// Performs the live Accessibility menu bar search for Edit ▸ Paste up to `deadline`.
    private nonisolated static func editPasteEnabled(pid: pid_t, deadline: Date? = nil) -> Bool? {
        let appElement = AXUIElementCreateApplication(pid)
        guard let pasteItem = AXMenuNavigator.findMenuItem(.paste, in: appElement, requireEnabled: false, deadline: deadline) else {
            return nil
        }
        return enabledState(of: pasteItem)
    }

    /// This function returns true if the menu item is Paste.
    /// It uses the shared menu navigator so copy and paste use the same match rules.
    nonisolated static func isPaste(title: String?, cmdChar: String?, cmdCharModifiers: UInt?) -> Bool {
        AXMenuNavigator.matches(.paste, title: title, identifier: nil, cmdChar: cmdChar, cmdModifiers: cmdCharModifiers)
    }

    /// Inspects the `kAXEnabledAttribute` of the given menu element.
    private nonisolated static func enabledState(of element: AXUIElement) -> Bool? {
        // Set the AX message time limit on this object. The limit applies to one AXUIElement.
        AXUIElementSetMessagingTimeout(element, Float(Constants.axReadTimeout))
        var enabledRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &enabledRef) == .success,
              let value = enabledRef as? Bool else { return nil }
        return value
    }
}
