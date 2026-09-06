// ActionSettingsPopover.swift
// OpenClip
//
// Presents the per-row settings editors of the Actions preferences tab (AI Tools, custom group,
// action) in an AppKit `NSPopover` with `.applicationDefined` behavior, so the editor stays open
// while the user keeps working in the list behind it.
//
// SwiftUI's `.popover` is always *transient*: the first click outside it — flipping an action's
// enable toggle, selecting another row — dismisses it. The outline is also an `NSOutlineView`
// that reloads its rows on every model change, which tears down the row-hosted view a SwiftUI
// popover would be anchored to. Anchoring to the window's content view instead keeps the editor
// alive across both, and it is closed explicitly: the gear again, the editor's own close/save
// buttons, Escape, or leaving the tab.

import AppKit
import SwiftUI

// MARK: - Popover Dismissal Environment

/// Closes the settings popover an editor is presented in. `nil` when the same editor is presented
/// as a sheet instead, in which case the editors fall back to SwiftUI's own `dismiss`.
private struct PopoverDismissKey: EnvironmentKey {
    // Computed rather than stored: a `@MainActor` closure is not `Sendable`, so a static stored
    // property of this type is rejected under strict concurrency.
    static var defaultValue: (@MainActor () -> Void)? { nil }
}

extension EnvironmentValues {
    var popoverDismiss: (@MainActor () -> Void)? {
        get { self[PopoverDismissKey.self] }
        set { self[PopoverDismissKey.self] = newValue }
    }
}

// MARK: - Anchor

/// Holds the real `NSView` behind a SwiftUI control so the popover can be positioned against it.
@MainActor
final class PopoverAnchorBox {
    weak var view: NSView?
}

/// Invisible AppKit view planted behind the gear button, purely to supply the anchor rect.
struct PopoverAnchorView: NSViewRepresentable {
    let box: PopoverAnchorBox

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        box.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        box.view = nsView
    }
}

// MARK: - Presenter

@MainActor
final class ActionSettingsPopover: NSObject, ObservableObject, NSPopoverDelegate {
    static let shared = ActionSettingsPopover()

    /// Id of the row whose editor is open, so its gear can render in the accent tint.
    @Published private(set) var openRowID: String?

    private var popover: NSPopover?

    private override init() {
        super.init()
    }

    /// Opens `content` for `rowID`, or closes it again when that row's editor is already showing.
    func toggle(
        rowID: String,
        anchor: PopoverAnchorBox,
        @ViewBuilder content: () -> some View
    ) {
        let wasOpen = openRowID == rowID
        close()
        guard !wasOpen else { return }

        guard let anchorView = anchor.view, let host = anchorView.window?.contentView else { return }
        let rect = host.convert(anchorView.bounds, from: anchorView)

        let controller = ActionSettingsHostingController(
            rootView: AnyView(
                content().environment(\.popoverDismiss, { [weak self] in self?.close() })
            )
        )
        controller.sizingOptions = [.preferredContentSize]
        controller.onCancel = { [weak self] in self?.close() }

        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.delegate = self
        popover.contentViewController = controller
        // Size to the SwiftUI content up front; `sizingOptions` keeps it in step afterwards
        // (the editors grow and shrink as options are revealed).
        let fitting = controller.view.fittingSize
        if fitting.width > 0, fitting.height > 0 {
            popover.contentSize = fitting
        }
        popover.show(relativeTo: rect, of: host, preferredEdge: .minX)

        self.popover = popover
        openRowID = rowID
    }

    func close() {
        let presented = popover
        popover = nil
        openRowID = nil
        presented?.performClose(nil)
    }

    // MARK: NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        popover = nil
        openRowID = nil
    }
}

/// Hosting controller that routes Escape to closing the popover — `.applicationDefined` popovers
/// never close on their own.
private final class ActionSettingsHostingController: NSHostingController<AnyView> {
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
