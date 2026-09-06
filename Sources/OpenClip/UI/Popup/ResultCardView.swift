// ResultCardView.swift
// OpenClip
//
// The native result card rendered in content mode in place of the bar: a header (back chevron,
// producing action's icon or sparkles + title, diff toggle), a scrollable response body
// (error-styled when the action failed), and a footer carrying Close (⎋) plus Copy/Paste (both
// absent on an error card, which offers only Close; Paste also hidden when the target app can't
// paste). Any action whose resolved outcome is text renders here, not just AI presets.
// Paste/Copy are explicit user requests routed through performCardEffect, so an explicit Paste
// always pastes, and both dismiss the popup (Copy like Paste). The panel is key while the card
// shows (Task 14) and the card owns the keys (SwiftUI .onKeyPress): Esc dismisses the card,
// Return pastes, Shift+Return copies, ⌘D toggles the diff — the controller-level key monitor
// stays observation-only in content mode.
// The card is modal-ish by design: it stays up until Copy, Paste or Esc (see
// PopupWindowController.handleEvent), and its header doubles as a drag handle (a SwiftUI
// DragGesture reported to PopupWindowController.handleCardDrag) so it can be moved out of the way
// of the text underneath.
import SwiftUI
import AppKit
import Core

// MARK: - Effective Theme Injection

/// Carries the popup's resolved theme token ("light"/"dark"/"glass") down to the card so its
/// chrome matches the bar (PopupView sets both this and the forced `.colorScheme`).
private struct PopupEffectiveThemeKey: EnvironmentKey {
    static let defaultValue = "dark"
}

extension EnvironmentValues {
    var popupEffectiveTheme: String {
        get { self[PopupEffectiveThemeKey.self] }
        set { self[PopupEffectiveThemeKey.self] = newValue }
    }
}

// MARK: - Card Drag

/// Phases of a drag on the card's header handle. The card only reports them; the controller owns
/// the panel and does the moving.
///
/// AppKit dragging is not an option here: the panel is borderless (no title bar),
/// `isMovableByWindowBackground` never fires because the SwiftUI hosting view consumes the press,
/// and an `NSViewRepresentable` handle never receives `mouseDown` either — `NSHostingView` answers
/// `hitTest` with itself for the whole card and dispatches through SwiftUI's own gesture system.
/// So the handle is a SwiftUI `DragGesture`, and the move is computed from the absolute cursor
/// position (never the gesture's translation, which would fight the window moving under it).
public enum ResultCardDragPhase: Sendable {
    case began
    case changed
    case ended
}

// MARK: - Result Card

public struct ResultCardView: View {
    public let payload: ResultCardPayload
    /// Paste availability of the target app (from the AX probe); `false` hides the Paste button.
    public let canPaste: Bool?
    public let onExit: @MainActor () -> Void
    /// Esc: closes the card outright (the popup goes away) rather than falling back to the bar.
    public let onDismiss: @MainActor () -> Void
    public let onPaste: @MainActor () -> Void
    public let onCopy: @MainActor () -> Void
    /// Reports a drag of the header handle so the owner can move the panel.
    public let onDrag: @MainActor (ResultCardDragPhase) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.popupEffectiveTheme) private var effectiveTheme
    @FocusState private var isCardFocused: Bool
    @State private var isChevronHovered = false
    @State private var isDiffHovered = false
    /// The diff of `payload.original` → `payload.text`, recomputed only when the payload settles
    /// (never per body evaluation, and never mid-stream on a half-written response).
    @State private var diffSegments: [TextDiffSegment] = []
    @State private var showsDiff = false
    /// Set once the user works the toggle, so a later payload update can't override their choice.
    @State private var didChooseDiffMode = false
    /// True between the drag gesture crossing its threshold and its end, so `.began` is reported
    /// exactly once per drag.
    @State private var isDraggingCard = false

    public init(
        payload: ResultCardPayload,
        canPaste: Bool? = nil,
        onExit: @escaping @MainActor () -> Void,
        onDismiss: (@MainActor () -> Void)? = nil,
        onPaste: @escaping @MainActor () -> Void,
        onCopy: @escaping @MainActor () -> Void,
        onDrag: @escaping @MainActor (ResultCardDragPhase) -> Void = { _ in }
    ) {
        self.payload = payload
        self.canPaste = canPaste
        self.onExit = onExit
        self.onDismiss = onDismiss ?? onExit
        self.onPaste = onPaste
        self.onCopy = onCopy
        self.onDrag = onDrag
    }

    public var body: some View {
        cardChrome {
            VStack(spacing: 0) {
                header
                bodyScroll
                footer
            }
        }
        .frame(width: dynamicCardWidth)
        .focusable()
        .focusEffectDisabled()
        .focused($isCardFocused)
        .onAppear {
            isCardFocused = true
            refreshDiff()
        }
        .onChange(of: payload) { _, _ in
            refreshDiff()
        }
        .onKeyPress(.escape) {
            onDismiss()
            return .handled
        }
        .onKeyPress(keys: ["d"], phases: .down) { press in
            guard press.modifiers.contains(.command), hasDiff else { return .ignored }
            toggleDiff()
            return .handled
        }
        .onKeyPress(.return, phases: .down) { press in
            // Return pastes (an explicit request, so it always pastes); Shift+Return copies.
            // When the target can't paste the button is hidden, so Return falls back to copy.
            if press.modifiers.contains(.shift) || canPaste == false {
                onCopy()
            } else {
                onPaste()
            }
            return .handled
        }
    }

    // MARK: Diff

    private var hasDiff: Bool { !diffSegments.isEmpty }

    /// Recomputes the diff for the current payload and picks the default view for it: a light edit
    /// (proofread, tone change) opens on the diff, a wholesale rewrite (translate, summarize)
    /// opens on the plain result — the toggle is always there either way. A response still
    /// streaming is never diffed: the comparison would be against a half-written text.
    private func refreshDiff() {
        guard !payload.isError, !payload.isStreaming,
              let original = payload.original else {
            diffSegments = []
            showsDiff = false
            return
        }
        let source = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = payload.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !result.isEmpty, source != result else {
            diffSegments = []
            showsDiff = false
            return
        }
        let segments = TextDiff.segments(from: source, to: result)
        guard segments.contains(where: { $0.kind != .equal }) else {
            diffSegments = []
            showsDiff = false
            return
        }
        diffSegments = segments
        if !didChooseDiffMode {
            showsDiff = TextDiff.equalRatio(of: segments) >= 0.5
        }
    }

    private func toggleDiff() {
        didChooseDiffMode = true
        showsDiff.toggle()
    }

    private var insertionColor: Color {
        colorScheme == .dark ? Color(red: 0.35, green: 0.82, blue: 0.50) : Color(red: 0.11, green: 0.53, blue: 0.24)
    }

    private var deletionColor: Color {
        colorScheme == .dark ? Color(red: 0.98, green: 0.47, blue: 0.47) : Color(red: 0.74, green: 0.15, blue: 0.15)
    }

    /// The diff as one attributed run stream: removed characters in red with a strikethrough,
    /// added characters in green, everything else in the body's normal colour. Both get a tinted
    /// background so a changed space or newline is still visible.
    private var diffAttributedText: AttributedString {
        var output = AttributedString()
        for segment in diffSegments {
            var run = AttributedString(segment.text)
            switch segment.kind {
            case .equal:
                run.foregroundColor = Color.primary.opacity(0.85)
            case .insert:
                run.foregroundColor = insertionColor
                run.backgroundColor = insertionColor.opacity(colorScheme == .dark ? 0.20 : 0.14)
            case .delete:
                run.foregroundColor = deletionColor
                run.backgroundColor = deletionColor.opacity(colorScheme == .dark ? 0.20 : 0.12)
                run.strikethroughStyle = Text.LineStyle.single
            }
            output.append(run)
        }
        return output
    }

    // MARK: Chrome

    private func cardChrome<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: PopupMetrics.popupCornerRadius, style: .continuous)
        let classicBorderColor: Color = colorScheme == .dark ? Color.white.opacity(0.22) : Color.black.opacity(0.20)
        return content()
            .background(
                Group {
                    if effectiveTheme == "glass" {
                        LayeredGlassBackground(cornerRadius: PopupMetrics.popupCornerRadius, colorScheme: colorScheme)
                    } else {
                        shape.fill(
                            Color(red: colorScheme == .dark ? 0.20 : 0.91,
                                  green: colorScheme == .dark ? 0.20 : 0.91,
                                  blue: colorScheme == .dark ? 0.22 : 0.93)
                        )
                    }
                }
            )
            .clipShape(shape)
            .overlay(
                Group {
                    if effectiveTheme == "glass" {
                        LayeredGlassBorder(cornerRadius: PopupMetrics.popupCornerRadius, colorScheme: colorScheme)
                    } else {
                        shape.stroke(classicBorderColor, lineWidth: 1.0)
                    }
                }
            )
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.32 : 0.16), radius: 6, x: 0, y: 3)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                onExit()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(isChevronHovered ? .accentColor : PopupThemeModel.restForeground(for: effectiveTheme).opacity(0.75))
                    .frame(width: 24, height: 24)
                    .background(
                        isChevronHovered ? Color.accentColor.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Back to actions")
            .accessibilityLabel("Back to actions")
            .onHover { isChevronHovered = $0 }

            // Everything between the buttons is the drag handle, so the card can be pulled off the
            // text it covers. The handle sits *behind* this row, clear of the two buttons.
            HStack(spacing: 8) {
                if let icon = payload.icon {
                    // The producing action's own icon (bar-resolution: honors user overrides),
                    // so extension results keep their identity in the card.
                    ActionIconView(icon: icon, size: 13)
                        .foregroundColor(.accentColor)
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.accentColor)
                }
                Text(payload.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(PopupThemeModel.restForeground(for: effectiveTheme))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(headerDragGesture)
            .help("Drag to move")

            if hasDiff {
                diffToggle
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            Rectangle().fill(PopupThemeModel.dividerColor(for: effectiveTheme))
                .frame(height: 0.6),
            alignment: .bottom
        )
    }

    /// A small threshold keeps a plain click on the header (which makes the panel key again after
    /// the user worked in another app) from being read as a drag.
    private var headerDragGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { _ in
                if !isDraggingCard {
                    isDraggingCard = true
                    onDrag(.began)
                }
                onDrag(.changed)
            }
            .onEnded { _ in
                guard isDraggingCard else { return }
                isDraggingCard = false
                onDrag(.ended)
            }
    }

    private var diffToggle: some View {
        Button {
            toggleDiff()
        } label: {
            Image(systemName: "plus.forwardslash.minus")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(showsDiff ? .accentColor : PopupThemeModel.restForeground(for: effectiveTheme).opacity(isDiffHovered ? 0.9 : 0.6))
                .frame(width: 24, height: 20)
                .background(
                    showsDiff ? Color.accentColor.opacity(0.14) : (isDiffHovered ? Color.primary.opacity(0.08) : Color.clear),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(showsDiff ? "Show the plain result (⌘D)" : "Show what changed (⌘D)")
        .accessibilityLabel("Toggle change highlighting")
        .onHover { isDiffHovered = $0 }
    }

    // MARK: Dynamic Dimensions

    /// What the body actually renders — the diff is longer than the result (it keeps the removed
    /// characters), so the card must be measured against it, not against `payload.text`.
    private var measuredText: String {
        if showsDiff, hasDiff {
            return diffSegments.map(\.text).joined()
        }
        return payload.text
    }

    /// Width the footer's buttons need before they start squeezing each other. The card's width is
    /// forced (a `ScrollView` of text has no useful ideal width), so the text-driven buckets below
    /// are floored by this instead of letting the row compress.
    private var minimumFooterWidth: CGFloat {
        if payload.isError { return 190 }            // Close alone
        return canPaste == false ? 250 : 320         // Close + Copy (+ Paste)
    }

    private var dynamicCardWidth: CGFloat {
        let trimmed = measuredText.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = trimmed.components(separatedBy: .newlines)
        let maxLineLength = lines.map(\.count).max() ?? trimmed.count
        let charCount = trimmed.count

        let textWidth: CGFloat
        if maxLineLength <= 18 && charCount <= 30 {
            textWidth = PopupMetrics.aiCardMinWidth // 220
        } else if maxLineLength <= 35 && charCount <= 80 {
            textWidth = 260
        } else {
            textWidth = PopupMetrics.aiCardIdealWidth // 300
        }
        return max(textWidth, minimumFooterWidth)
    }

    private var dynamicBodyHeight: CGFloat {
        let trimmed = measuredText.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = trimmed.components(separatedBy: .newlines)
        let lineCount = lines.count
        let charCount = trimmed.count

        if lineCount <= 1 && charCount <= 30 {
            return 72
        } else if lineCount <= 1 && charCount <= 60 {
            return 88
        } else if lineCount <= 2 && charCount <= 90 {
            return 104
        } else if lineCount <= 3 && charCount <= 140 {
            return 124
        } else if lineCount <= 4 && charCount <= 180 {
            return 144
        } else {
            return PopupMetrics.aiCardBodyHeight // 160 max height for scrolling
        }
    }

    // MARK: Body

    private var textTypography: (fontSize: CGFloat, fontWeight: Font.Weight, lineSpacing: CGFloat) {
        let trimmed = measuredText.trimmingCharacters(in: .whitespacesAndNewlines)
        let lineCount = trimmed.components(separatedBy: .newlines).count
        let charCount = trimmed.count

        if charCount <= 30 && lineCount <= 1 {
            return (fontSize: 18, fontWeight: .medium, lineSpacing: 2)
        } else if charCount <= 80 && lineCount <= 2 {
            return (fontSize: 15.5, fontWeight: .medium, lineSpacing: 3)
        } else if charCount <= 160 && lineCount <= 4 {
            return (fontSize: 14, fontWeight: .regular, lineSpacing: 3)
        } else {
            return (fontSize: 13, fontWeight: .regular, lineSpacing: 3.5)
        }
    }

    private var bodyScroll: some View {
        let typography = textTypography
        let bodyHeight = dynamicBodyHeight
        return ScrollView {
            bodyText
                .font(.system(size: typography.fontSize, weight: typography.fontWeight))
                .lineSpacing(typography.lineSpacing)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        .frame(height: bodyHeight)
    }

    @ViewBuilder
    private var bodyText: some View {
        if showsDiff, hasDiff {
            Text(diffAttributedText)
        } else {
            Text(payload.text)
                .foregroundColor(payload.isError ? Color.red : Color.primary)
        }
    }

    // MARK: Footer

    private var isCopyPrimary: Bool {
        canPaste == false
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                onDismiss()
            } label: {
                HStack(spacing: 5) {
                    Text("Close")
                    Image(systemName: "escape")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .opacity(0.8)
                }
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .fixedSize()
                .foregroundColor(PopupThemeModel.restForeground(for: effectiveTheme).opacity(0.85))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Color.primary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close the card (⎋)")
            .accessibilityLabel("Close the result card")

            Spacer(minLength: 0)

            if !payload.isError {
                resultButtons
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            Rectangle().fill(PopupThemeModel.dividerColor(for: effectiveTheme))
                .frame(height: 0.6),
            alignment: .top
        )
    }

    /// Copy / Paste — the answers that consume the result. Absent on an error card, which only
    /// offers Close.
    @ViewBuilder
    private var resultButtons: some View {
        Group {
            Button {
                onCopy()
            } label: {
                HStack(spacing: 5) {
                    Text("Copy")
                    if isCopyPrimary {
                        Image(systemName: "return")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .opacity(0.8)
                    } else {
                        HStack(spacing: 2) {
                            Image(systemName: "shift")
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                            Image(systemName: "return")
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                        }
                        .opacity(0.6)
                    }
                }
                .font(.system(size: 12, weight: isCopyPrimary ? .semibold : .medium))
                .lineLimit(1)
                .fixedSize()
                .foregroundColor(isCopyPrimary ? .white : PopupThemeModel.restForeground(for: effectiveTheme))
                .padding(.horizontal, isCopyPrimary ? 12 : 10)
                .padding(.vertical, 5)
                .background(
                    isCopyPrimary ? Color.accentColor : Color.primary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
            }
            .buttonStyle(.plain)
            .help(isCopyPrimary ? String(localized: "Copy the response to the clipboard and close (⏎)") : String(localized: "Copy the response to the clipboard and close (⇧⏎)"))
            .accessibilityLabel("Copy response and close")

            if canPaste != false {
                Button {
                    onPaste()
                } label: {
                    HStack(spacing: 5) {
                        Text("Paste")
                        Image(systemName: "return")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .opacity(0.8)
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("Paste the response over the selection (⏎)")
                .accessibilityLabel("Paste response over selection")
            }
        }
    }
}
