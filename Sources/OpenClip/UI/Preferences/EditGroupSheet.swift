// EditGroupSheet.swift
// OpenClip
//
// Renders the modal sheet for editing custom action group metadata, managing members, or disbanding the group.
import SwiftUI
import Core

@MainActor
public struct EditGroupSheet: View {
    let groupID: String
    @Environment(\.dismiss) private var dismiss
    /// Set when the editor is shown in the Actions tab's settings popover, which closes itself
    /// only on request; `nil` when it is presented as a sheet.
    @Environment(\.popoverDismiss) private var popoverDismiss
    @ObservedObject private var coordinator = ActionCoordinator.shared

    @State private var title: String = ""
    @State private var iconName: String = "folder"
    @State private var memberIDs: [String] = []
    @State private var showingIconPicker = false

    public init(groupID: String) {
        self.groupID = groupID
    }

    private var groupDef: ActionGroupDef? {
        coordinator.actionGroupDefs.first(where: { $0.id == groupID })
    }

    private var isCustomGroup: Bool {
        groupDef != nil
    }

    private func close() {
        if let popoverDismiss {
            popoverDismiss()
        } else {
            dismiss()
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Edit Group")
                    .font(.headline)
                Spacer()
                Button {
                    close()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 10) {
                TextField("Group Name", text: $title)
                    .textFieldStyle(.roundedBorder)

                Button {
                    showingIconPicker.toggle()
                } label: {
                    HStack(spacing: 4) {
                        AnyIconView(iconId: iconName.isEmpty ? "folder" : iconName)
                            .frame(width: 16, height: 16)
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showingIconPicker, arrowEdge: .bottom) {
                    IconPickerPopover(selectedIcon: $iconName)
                }
            }

            Text("MEMBERS")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)

            VStack(spacing: 6) {
                ForEach(memberIDs, id: \.self) { actionID in
                    let resolvedAction = coordinator.actions.first(where: { $0.id == actionID })
                    let presentation = resolvedAction.map { ActionCustomizationManager.shared.presented($0, surface: .table) }
                    HStack(spacing: 8) {
                        if let presentation {
                            ZStack {
                                ActionIconView(icon: presentation.icon, size: 14)
                            }
                            .frame(width: 18, height: 18, alignment: .center)

                            Text(presentation.title)
                                .font(.system(size: 12))
                        } else {
                            Color.clear
                                .frame(width: 18, height: 18)

                            Text(actionID)
                                .font(.system(size: 12))
                        }
                        Spacer()
                        if isCustomGroup {
                            if let index = memberIDs.firstIndex(of: actionID) {
                                HStack(spacing: 4) {
                                    Button {
                                        guard index > 0 else { return }
                                        withAnimation(.easeInOut(duration: 0.15)) {
                                            memberIDs.swapAt(index, index - 1)
                                        }
                                    } label: {
                                        Image(systemName: "chevron.up")
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundColor(index > 0 ? .secondary : .secondary.opacity(0.25))
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(index == 0)

                                    Button {
                                        guard index < memberIDs.count - 1 else { return }
                                        withAnimation(.easeInOut(duration: 0.15)) {
                                            memberIDs.swapAt(index, index + 1)
                                        }
                                    } label: {
                                        Image(systemName: "chevron.down")
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundColor(index < memberIDs.count - 1 ? .secondary : .secondary.opacity(0.25))
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(index >= memberIDs.count - 1)
                                }
                                .padding(.trailing, 4)
                            }
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    memberIDs.removeAll { $0 == actionID }
                                }
                            } label: {
                                Image(systemName: "minus.circle")
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.03)))
                }
            }

            Divider()

            HStack {
                if isCustomGroup {
                    Button("Ungroup", role: .destructive) {
                        coordinator.ungroup(groupID: groupID)
                        close()
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.red)
                }

                Spacer()

                Button("Cancel") { close() }
                    .keyboardShortcut(.cancelAction)

                Button("Save") {
                    let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
                    let effectiveIcon = iconName.isEmpty ? "folder" : iconName
                    if isCustomGroup {
                        coordinator.updateGroup(
                            groupID: groupID,
                            title: trimmedTitle,
                            iconName: effectiveIcon,
                            memberActionIDs: memberIDs
                        )
                    } else {
                        ActionCustomizationManager.shared.setOverride(
                            for: groupID,
                            title: trimmedTitle.isEmpty ? nil : trimmedTitle,
                            symbol: effectiveIcon,
                            text: nil
                        )
                    }
                    close()
                }
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || (isCustomGroup ? memberIDs.count < 2 : memberIDs.isEmpty))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 360)
        .onAppear {
            if let groupDef {
                title = groupDef.title
                iconName = groupDef.iconName.isEmpty ? "folder" : groupDef.iconName
                memberIDs = groupDef.memberActionIDs
            } else {
                let override = ActionCustomizationManager.shared.override(for: groupID)
                let groupAction = coordinator.actions.first(where: { $0.id == groupID })
                title = override?.customTitle ?? groupAction?.title ?? ""
                if let customSymbol = override?.customIconSymbol {
                    iconName = customSymbol
                } else if let configurable = groupAction as? any ConfigurableAction, !configurable.preferenceIconName.isEmpty {
                    iconName = configurable.preferenceIconName
                } else {
                    iconName = "folder"
                }
                memberIDs = coordinator.memberActionIDs(for: groupID)
            }
        }
    }
}
