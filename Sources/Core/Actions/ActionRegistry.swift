// ActionRegistry.swift
// OpenClip
//
// Stores and orders all registered actions, providing a reactive catalog of available text manipulations.
// Interacts with the Settings Door to respect user sorting preferences and enable dynamic action lookup by identifier.
import Foundation
import Combine

@MainActor
public final class ActionRegistry: ObservableObject, Sendable {
    public static let shared = ActionRegistry()
    
    @Published public private(set) var actions: [any Action] = []
    private var registeredActions: [any Action] = []
    private var groupDefs: [ActionGroupDef] = []
    private let settingsStore: SettingsStore
    
    public init(settingsStore: SettingsStore = DefaultSettingsStore.shared) {
        self.settingsStore = settingsStore
    }
    
    public func register(builtIns: [any Action]) {
        // Dedupe against existing registeredActions and against earlier entries within the same batch,
        // so repeated loadInitialState() calls or a duplicate entry in the catalog don't append twice.
        var seenIDs = Set(registeredActions.map(\.id))
        registeredActions.append(contentsOf: builtIns.filter { action in
            guard !seenIDs.contains(action.id) else { return false }
            seenIDs.insert(action.id)
            return true
        })
        sortActions()
    }
    
    public func register(action: any Action) {
        // Replace if ID already exists, otherwise append
        if let idx = registeredActions.firstIndex(where: { $0.id == action.id }) {
            registeredActions[idx] = action
        } else {
            registeredActions.append(action)
        }
        sortActions()
    }
    
    /// Maps each sub-action to the row that provides it (`SubActionProviding`: the AI Tools
    /// launcher, group rows), so `sortActions` can place children with their parent. A child the
    /// user has ordered explicitly is left alone — an `action.order` entry always outranks
    /// inheritance — and the first provider claiming a child wins, so membership stays
    /// single-valued. One level only: a child never re-parents through another child.
    private func subActionParents(explicitlyOrderedIDs: [String: Int]) -> [String: String] {
        let resolver = SubActionResolver()
        var parents: [String: String] = [:]
        for parent in registeredActions where parent is any SubActionProviding {
            for child in resolver.subActions(of: parent, in: registeredActions) {
                guard child.id != parent.id,
                      explicitlyOrderedIDs[child.id] == nil,
                      parents[child.id] == nil else { continue }
                parents[child.id] = parent.id
            }
        }
        return parents
    }

    private func sortActions() {
        let order = settingsStore.get(.actionOrder)
        let orderIndexMap: [String: Int] = Dictionary(
            order.enumerated().map { ($1, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // A row that opens into sub-actions (the AI Tools launcher, group rows) owns where its
        // children sit: flat surfaces — the search palette above all — list the children instead
        // of the parent row, so a child that inherits nothing lands at the very end of the
        // catalog no matter where the user dragged the parent. AI presets are the visible case:
        // they carry chrome source `.ai`, which is neither user-ordered nor builtin, so "AI Tools
        // first" in Preferences still left every AI command last in the palette.
        let parentIDByChildID = subActionParents(explicitlyOrderedIDs: orderIndexMap)
        let actionsByID = Dictionary(registeredActions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // Tier classification:
        // Tier 0: Explicitly ordered by user in `action.order` (sorted by rank in orderIndexMap)
        // Tier 1: Un-ordered built-in actions (sorted stably by insertion order)
        // Tier 2: Un-ordered extensions/other actions (sorted stably by insertion order)
        // A child adopts its parent's whole classification and sorts immediately after it
        // (`subRank` 1), so it follows the parent wherever the parent lands.
        func placement(of action: any Action) -> (tier: Int, rank: Int) {
            if let index = orderIndexMap[action.id] {
                return (0, index)
            } else if ActionIdentity.isBuiltin(action) {
                return (1, 0)
            } else {
                return (2, 0)
            }
        }

        let ranked: [(action: any Action, tier: Int, rank: Int, subRank: Int, stableOffset: Int)] = registeredActions.enumerated().map { offset, action in
            if let parentID = parentIDByChildID[action.id], let parent = actionsByID[parentID] {
                let inherited = placement(of: parent)
                return (action, inherited.tier, inherited.rank, 1, offset)
            }
            let own = placement(of: action)
            return (action, own.tier, own.rank, 0, offset)
        }

        let sortedBase = ranked
            .sorted { lhs, rhs in
                if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
                if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
                if lhs.subRank != rhs.subRank { return lhs.subRank < rhs.subRank }
                return lhs.stableOffset < rhs.stableOffset
            }
            .map(\.action)

        guard !groupDefs.isEmpty else {
            actions = sortedBase
            return
        }

        // Build a set of all grouped action IDs for fast lookup
        let allGroupedIDs = Set(groupDefs.flatMap(\.memberActionIDs))

        // Pre-collect each group's members in their sorted order so we can
        // inject them contiguously after the group header
        var groupMembers: [String: [any Action]] = [:]
        for def in groupDefs {
            let memberSet = Set(def.memberActionIDs)
            groupMembers[def.id] = sortedBase.filter { memberSet.contains($0.id) }
        }

        var result: [any Action] = []
        var injectedGroupIDs = Set<String>()

        for action in sortedBase {
            if allGroupedIDs.contains(action.id) {
                // Inject group header + all members on first member encounter
                for def in groupDefs where !injectedGroupIDs.contains(def.id) {
                    if def.memberActionIDs.contains(action.id) {
                        injectedGroupIDs.insert(def.id)
                        result.append(CustomGroupAction(
                            id: def.id,
                            title: def.title,
                            iconName: def.iconName,
                            memberActionIDs: def.memberActionIDs
                        ))
                        // Add all members contiguously after the header
                        if let members = groupMembers[def.id] {
                            result.append(contentsOf: members)
                        }
                        break
                    }
                }
                // Skip — already emitted during group injection above
                continue
            }
            result.append(action)
        }

        // Catch any remaining groups whose members weren't in sortedBase
        for def in groupDefs where !injectedGroupIDs.contains(def.id) {
            result.append(CustomGroupAction(
                id: def.id,
                title: def.title,
                iconName: def.iconName,
                memberActionIDs: def.memberActionIDs
            ))
        }

        actions = result
    }
    
    public func moveActions(from source: IndexSet, to destination: Int) {
        var newActions = actions
        let movingActions = source.map { newActions[$0] }
        for index in source.reversed() {
            newActions.remove(at: index)
        }
        
        var dest = destination
        for idx in source {
            if idx < destination {
                dest -= 1
            }
        }
        
        newActions.insert(contentsOf: movingActions, at: dest)

        let newOrder = newActions
            .filter { !ActionIdentity.isAIPreset($0) && !($0 is CustomGroupAction) }
            .map { $0.id }
        settingsStore.set(.actionOrder, value: newOrder)

        // Re-derive rather than publishing the hand-moved array: a drag moves only the rows the
        // user grabbed, so anything whose placement is *derived* — a sub-action following its
        // parent row (AI presets under AI Tools), a group's members trailing its header — would
        // keep the position it had before the drag until the next registration re-sorted the
        // catalog. That is why reordering AI Tools appeared to need a restart to take effect.
        sortActions()
    }
    
    public func unregister(actionID: String) {
        registeredActions.removeAll(where: { $0.id == actionID })
        sortActions()
        pruneActionOrder()
    }

    public func pruneActionOrder() {
        let currentOrder = settingsStore.get(.actionOrder)
        guard !currentOrder.isEmpty else { return }
        let activeIDs = Set(registeredActions.map { $0.id })
        let prunedOrder = currentOrder.filter { activeIDs.contains($0) }
        if prunedOrder != currentOrder {
            settingsStore.set(.actionOrder, value: prunedOrder)
        }
    }

    public var registeredActionIDs: Set<String> {
        Set(registeredActions.map(\.id))
    }

    public func setGroupDefs(_ defs: [ActionGroupDef]) {
        self.groupDefs = defs
        sortActions()
    }

    /// Clears all registered actions. Test-isolation hook so the shared singleton does not leak
    /// state across test cases.
    public func reset() {
        actions = []
        registeredActions = []
        groupDefs = []
    }
    
    /// Context gating shared by the bar and the search palette: can this action actually perform
    /// against the current selection/app? Settings-disable state is deliberately out of scope here
    /// (the bar applies it separately; the palette ignores it). Clipboard-fallback actions that
    /// require a live selection and formatting actions under a deny-formatting app policy drop.
    /// AI presets are treated as performable (a palette selection routes to the AI card regardless
    /// of the enable toggle; the bar excludes presets by policy, not by ability).
    private func canPerform(_ action: any Action, in context: ActionContext) -> Bool {
        // AI presets are always performable from the palette: a selection routes to the AI
        // card regardless of the preset's enable toggle, so they stay visible.
        if ActionIdentity.isAIPreset(action) {
            return true
        }
        // Clipboard fallback is not a live selection: Copy/Cut (and any future action that
        // reads or mutates the real selection) must not act on text that was never selected.
        if context.selection.isClipboardFallback && action.chrome.requiresLiveSelection {
            return false
        }
        return action.isEnabled(for: context)
    }

    public func availableActions(for context: ActionContext) -> [any Action] {
        let disabledIDs = settingsStore.get(.disabledActionIDs)
        let disabledPackages = settingsStore.get(.disabledPackages)

        func passes(_ action: any Action) -> Bool {
            // AI preset actions are never bar rows: the reorderable `builtin.aiTools` action
            // (chrome.launchesAI) is the popup's AI entry, so presets must not flood the
            // paginated bar even when enabled.
            if ActionIdentity.isAIPreset(action) {
                return false
            }
            if action is GatedExtensionAction {
                return false
            }
            guard canPerform(action, in: context) else { return false }
            if disabledIDs.contains(action.id) {
                return false
            }
            // Whole-package disable: an action whose chrome source names a disabled package
            // is hidden before per-action visibility runs.
            if let packageID = ActionIdentity.extensionPackageID(of: action), disabledPackages.contains(packageID) {
                return false
            }
            return true
        }

        // Group sub-actions are only reachable through their group's sub-menu. A group whose
        // row is disabled (or otherwise not visible) hides its sub-actions entirely, so a
        // disabled group never leaks its sub-actions into the bar.
        let groupRowIDs = actions
            .filter { $0.chrome.popupBehavior == .showSubActions }
            .map { $0.id }
        let enabledGroupIDs = Set(
            actions
                .filter { $0.chrome.popupBehavior == .showSubActions }
                .filter { passes($0) }
                .map { $0.id }
        )

        // Custom groups: hide members of a disabled custom group.
        // This parallels the prefix-based hiding above but uses the explicit
        // memberActionIDs list since custom group members keep canonical IDs.
        let customGroupMemberToGroupID: [String: String] = {
            var map: [String: String] = [:]
            for def in groupDefs {
                for memberID in def.memberActionIDs {
                    map[memberID] = def.id
                }
            }
            return map
        }()

        return actions.filter { action in
            guard passes(action) else { return false }
            if let groupID = groupRowIDs.first(where: { action.id.hasPrefix($0 + ".") }),
               !enabledGroupIDs.contains(groupID) {
                return false
            }
            if let owningGroupID = customGroupMemberToGroupID[action.id],
               !enabledGroupIDs.contains(owningGroupID) {
                return false
            }
            return true
        }
    }

    /// The registered catalog for the action-search palette, filtered to actions that can
    /// actually perform given the current context. Settings-disabled actions (`.disabledActionIDs`,
    /// `.disabledPackages`) stay visible — the palette is a full-catalog surface and a disabled row
    /// can be re-enabled — but actions that cannot run against this context are dropped:
    /// `isEnabled(for:)` failures (no selection, regex/app/expression gates), clipboard-fallback
    /// actions that require a live selection, and formatting actions under a deny-formatting app
    /// policy. Sub-actions appear individually, flat; group rows remain (their sub-actions are
    /// reachable directly from the palette). `chrome.launchesAI` launchers and the inline
    /// completion pseudo-action are always excluded.
    public func searchCatalog(for context: ActionContext) -> [any Action] {
        actions.filter { action in
            if action.chrome.launchesAI || ActionIdentity.isCompletionPseudoAction(action) || action is GatedExtensionAction {
                return false
            }
            return canPerform(action, in: context)
        }
    }
}

