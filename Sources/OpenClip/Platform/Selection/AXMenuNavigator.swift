// AXMenuNavigator.swift
// OpenClip
//
// Robust, localization-agnostic navigation of the frontmost application's menu bar through the raw
// Accessibility API. Menu items are matched by action identifier (`copy:`/`paste:`), by their
// Command-key equivalent (⌘C/⌘V), or by localized titles.
import ApplicationServices
import Foundation
import Core

public struct AXMenuNavigator {
    /// The system menu commands OpenClip needs to locate and, for copy, press.
    public enum MenuCommand: CaseIterable, Sendable {
        case copy
        case paste

        /// The AX action-selector identifier for this command (e.g. `copy:`).
        var identifier: String {
            switch self {
            case .copy: return "copy:"
            case .paste: return "paste:"
            }
        }

        /// The expected Command-key equivalent character for this command.
        var cmdChar: String {
            switch self {
            case .copy: return "C"
            case .paste: return "V"
            }
        }

        /// Localized menu titles for this command, lowercased for case-insensitive matching.
        var titles: Set<String> {
            switch self {
            case .copy: return AXMenuNavigator.copyTitles
            case .paste: return AXMenuNavigator.pasteTitles
            }
        }
    }

    /// Finds the requested menu item in `app`'s menu bar, optionally requiring it to be enabled.
    /// Sets a messaging timeout on `app` before the menu-bar read, and bounds traversal against `deadline`.
    ///
    /// - Parameters:
    ///   - command: The menu command to locate.
    ///   - app: The application AXUIElement (never the system-wide element; menu items are children
    ///     of the application element).
    ///   - requireEnabled: When true, only an enabled item matches.
    ///   - deadline: Optional absolute deadline after which menu traversal aborts and returns nil.
    /// - Returns: The matching menu item, or nil.
    public static func findMenuItem(
        _ command: MenuCommand,
        in app: AXUIElement?,
        requireEnabled: Bool = false,
        deadline: Date? = nil
    ) -> AXUIElement? {
        if let deadline, Date() >= deadline { return nil }
        guard let app else { return nil }
        AXUIElementSetMessagingTimeout(app, Float(Constants.axReadTimeout))
        guard let menuBar = attribute(app, kAXMenuBarAttribute, deadline: deadline).flatMap(axElement),
              let topLevelMenus = children(menuBar, deadline: deadline) else { return nil }

        // The Edit menu is standardly the 4th top-level menu (index 3). Search it first, then search remaining menus.
        let editIndex = 3
        if topLevelMenus.indices.contains(editIndex),
           let match = findMenuItem(command, in: topLevelMenus[editIndex], requireEnabled: requireEnabled, deadline: deadline) {
            return match
        }

        for (index, menu) in topLevelMenus.enumerated() where index != editIndex {
            if let deadline, Date() >= deadline { return nil }
            if let match = findMenuItem(command, in: menu, requireEnabled: requireEnabled, deadline: deadline) {
                return match
            }
        }

        return nil
    }

    /// Presses the requested menu item if it can be found and is enabled.
    /// Sets a messaging timeout on the menu item before AXPress, and bounds search against `deadline`.
    @discardableResult
    public static func press(_ command: MenuCommand, in app: AXUIElement?, deadline: Date? = nil) -> Bool {
        guard let item = findMenuItem(command, in: app, requireEnabled: true, deadline: deadline) else { return false }
        AXUIElementSetMessagingTimeout(item, Float(Constants.axReadTimeout))
        AXUIElementPerformAction(item, kAXPressAction as CFString)
        return true
    }

    /// Whether the supplied title/cmd-char/modifiers describe the requested menu command.
    public static func matches(
        _ command: MenuCommand,
        title: String?,
        identifier: String?,
        cmdChar: String?,
        cmdModifiers: UInt?
    ) -> Bool {
        if let identifier, identifier == command.identifier { return true }

        if let cmdChar, cmdChar.caseInsensitiveCompare(command.cmdChar) == .orderedSame,
           let modifiers = cmdModifiers {
            return modifiers == 0
        }

        guard let title else { return false }
        return command.titles.contains(title.localizedLowercase)
    }

    // MARK: - Tree walking

    private static let maxDepth = 8

    /// Recursively searches for the requested menu command starting at `element`.
    /// Traversal is bounded by `maxDepth` and stops early if `deadline` is exceeded.
    private static func findMenuItem(
        _ command: MenuCommand,
        in element: AXUIElement,
        requireEnabled: Bool,
        depth: Int = 0,
        deadline: Date? = nil
    ) -> AXUIElement? {
        if let deadline, Date() >= deadline { return nil }
        guard depth <= maxDepth else { return nil }

        if isMatch(command, element: element, requireEnabled: requireEnabled, deadline: deadline) {
            return element
        }

        for child in children(element, deadline: deadline) ?? [] {
            if let deadline, Date() >= deadline { return nil }
            if let match = findMenuItem(
                command,
                in: child,
                requireEnabled: requireEnabled,
                depth: depth + 1,
                deadline: deadline
            ) {
                return match
            }
        }

        return nil
    }

    /// Evaluates whether the AX element matches the requested menu command and enablement criteria.
    private static func isMatch(
        _ command: MenuCommand,
        element: AXUIElement,
        requireEnabled: Bool,
        deadline: Date? = nil
    ) -> Bool {
        guard matches(
            command,
            title: title(element, deadline: deadline),
            identifier: identifier(element, deadline: deadline),
            cmdChar: cmdChar(element, deadline: deadline),
            cmdModifiers: cmdModifiers(element, deadline: deadline)
        ) else { return false }

        if requireEnabled {
            guard enabled(element, deadline: deadline) == true else { return false }
        }
        return true
    }

    // MARK: - AX attribute helpers

    /// Retrieves the child AX elements of the given element up to `deadline`.
    private static func children(_ element: AXUIElement, deadline: Date? = nil) -> [AXUIElement]? {
        guard let value = attribute(element, kAXChildrenAttribute, deadline: deadline) else { return nil }
        return value as? [AXUIElement]
    }

    /// Retrieves the `kAXTitleAttribute` string of the given element up to `deadline`.
    private static func title(_ element: AXUIElement, deadline: Date? = nil) -> String? {
        attribute(element, kAXTitleAttribute, deadline: deadline) as? String
    }

    /// Retrieves the `kAXIdentifierAttribute` string of the given element up to `deadline`.
    private static func identifier(_ element: AXUIElement, deadline: Date? = nil) -> String? {
        attribute(element, kAXIdentifierAttribute, deadline: deadline) as? String
    }

    /// Retrieves the `kAXMenuItemCmdCharAttribute` string of the given element up to `deadline`.
    private static func cmdChar(_ element: AXUIElement, deadline: Date? = nil) -> String? {
        attribute(element, kAXMenuItemCmdCharAttribute, deadline: deadline) as? String
    }

    /// Retrieves the `kAXMenuItemCmdModifiersAttribute` mask of the given element up to `deadline`.
    private static func cmdModifiers(_ element: AXUIElement, deadline: Date? = nil) -> UInt? {
        guard let value = attribute(element, kAXMenuItemCmdModifiersAttribute, deadline: deadline) else { return nil }
        return (value as? NSNumber)?.uintValue
    }

    /// Retrieves the `kAXEnabledAttribute` boolean of the given element up to `deadline`.
    private static func enabled(_ element: AXUIElement, deadline: Date? = nil) -> Bool? {
        attribute(element, kAXEnabledAttribute, deadline: deadline) as? Bool
    }

    /// Reads an AX attribute value with per-call messaging timeout and aggregate deadline enforcement.
    private static func attribute(_ element: AXUIElement, _ attribute: String, deadline: Date? = nil) -> CFTypeRef? {
        if let deadline, Date() >= deadline { return nil }
        AXUIElementSetMessagingTimeout(element, Float(Constants.axReadTimeout))
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    /// Casts an untyped CoreFoundation attribute value to `AXUIElement` if applicable.
    private static func axElement(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element: AXUIElement = value as! AXUIElement
        return element
    }

    // MARK: - Localized titles

    private static let copyTitles: Set<String> = [
        "copy",  // English
        "拷贝", "复制",  // Simplified Chinese
        "拷貝", "複製",  // Traditional Chinese
        "コピー",  // Japanese
        "복사",  // Korean
        "copier",  // French
        "copiar",  // Spanish, Portuguese
        "copia",  // Italian
        "kopieren",  // German
        "копировать",  // Russian
        "kopiëren",  // Dutch
        "kopiér",  // Danish
        "kopiera",  // Swedish
        "kopioi",  // Finnish
        "αντιγραφή",  // Greek
        "kopyala",  // Turkish
        "salin",  // Indonesian
        "sao chép",  // Vietnamese
        "คัดลอก",  // Thai
        "копіювати",  // Ukrainian
        "kopiuj",  // Polish
        "másolás",  // Hungarian
        "kopírovat",  // Czech
        "kopírovať",  // Slovak
        "kopiraj",  // Croatian, Serbian (Latin)
        "копирај",  // Serbian (Cyrillic)
        "копиране",  // Bulgarian
        "kopēt",  // Latvian
        "kopijuoti",  // Lithuanian
        "copiază",  // Romanian
        "העתק",  // Hebrew
        "نسخ",  // Arabic
        "کپی",  // Persian
    ]

    private static let pasteTitles: Set<String> = [
        "paste", "paste and match style",  // English
        "粘贴", "贴上",  // Simplified Chinese
        "貼上", "粘貼",  // Traditional Chinese
        "ペースト",  // Japanese
        "붙여넣기",  // Korean
        "coller", "coller et assortir le style",  // French
        "pegar", "pegar y combinar estilo",  // Spanish, Portuguese
        "incolla",  // Italian
        "einfügen", "einfügen und stil anpassen",  // German
        "вставить",  // Russian
        "plakken", "plakken en stijl aanpassen",  // Dutch
        "indsæt",  // Danish
        "klistra", "klistra in",  // Swedish
        "liitä",  // Finnish
        "επικόλληση",  // Greek
        "yapıştır",  // Turkish
        "tempel",  // Indonesian
        "dán",  // Vietnamese
        "วาง",  // Thai
        "вставити",  // Ukrainian
        "wklej",  // Polish
        "beillesztés",  // Hungarian
        "vložit",  // Czech
        "vložiť",  // Slovak
        "umetni",  // Croatian, Serbian (Latin)
        "уметни",  // Serbian (Cyrillic)
        "поставяне",  // Bulgarian
        "ielīmēt",  // Latvian
        "įklijuoti",  // Lithuanian
        "lipește",  // Romanian
        "colar", "colar e combinar estilo",  // Portuguese (BR)
        "lim inn",  // Norwegian
        "הדבק",  // Hebrew
        "لصق",  // Arabic
        "چسباندن",  // Persian
        "貼り付け",  // Japanese (alt)
    ]
}
