//
//  DesktopSupportingViews.swift
//  HeyMate
//
//  The Memory page. The notch micro-apps and privacy pages that used to live
//  here are Settings sections now (SettingsNotchPane, SettingsPrivacyPane).
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Memory

struct DesktopMemoryView: View {
    @ObservedObject var companionManager: CompanionManager
    @State private var editingMemoryID: UUID?
    @State private var editingDraft = ""
    @State private var memoryIDPendingForget: UUID?
    @State private var isConfirmingForgetOne = false
    @State private var isConfirmingForgetEverything = false
    @State private var isConfirmingDeleteSavedChats = false

    var body: some View {
        DesktopPage(
            title: "Memory",
            subtitle: "Text only, stored on this Mac. Screenshots are never retained — the store has no field to put them in."
        ) {
            DesktopCard(title: "Behavior") {
                VStack(alignment: .leading, spacing: 10) {
                    // Same switch as Settings › Privacy & Data, bound to the
                    // same property.
                    Toggle(isOn: $companionManager.rememberConversationsEnabled) {
                        SettingsRowLabel(
                            title: SettingsItem.saveChats.title,
                            subtitle: "Turning this off stops new saves but does not delete chats already stored."
                        )
                    }
                    .toggleStyle(DSSwitchToggleStyle())

                    Button("Delete saved chats") {
                        isConfirmingDeleteSavedChats = true
                    }
                    .buttonStyle(DSDestructiveButtonStyle())
                }
            }

            if companionManager.memoryItems.isEmpty {
                DesktopEmptyState(
                    symbolName: "brain",
                    title: "Nothing remembered yet",
                    message: "HeyMate writes a memory when something is worth carrying between conversations."
                )
            } else {
                DesktopCard(title: "Stored memories") {
                    VStack(spacing: 0) {
                        ForEach(companionManager.memoryItems) { item in
                            memoryRow(item)
                            Divider().opacity(0.2)
                        }
                        HStack {
                            Button("Export") { exportMemories() }
                                .buttonStyle(DSSecondaryButtonStyle(isFullWidth: false))
                            Spacer()
                            Button("Forget everything") { isConfirmingForgetEverything = true }
                                .buttonStyle(DSDestructiveButtonStyle())
                        }
                        .padding(.top, 8)
                    }
                }
            }
        }
        .confirmationDialog(
            "Delete saved chats?",
            isPresented: $isConfirmingDeleteSavedChats,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                companionManager.clearAllChats()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Chats already stored on this Mac are removed. Memories stay.")
        }
        .confirmationDialog(
            "Delete everything HeyMate remembers?",
            isPresented: $isConfirmingForgetEverything,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                editingMemoryID = nil
                editingDraft = ""
                companionManager.clearAllMemory()
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Forget this memory?",
            isPresented: $isConfirmingForgetOne,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let id = memoryIDPendingForget {
                    if editingMemoryID == id {
                        editingMemoryID = nil
                        editingDraft = ""
                    }
                    companionManager.deleteMemory(id: id)
                }
                memoryIDPendingForget = nil
            }
            Button("Cancel", role: .cancel) { memoryIDPendingForget = nil }
        }
    }

    @ViewBuilder
    private func memoryRow(_ item: MemoryItem) -> some View {
        if editingMemoryID == item.id {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Memory", text: $editingDraft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(DS.Fonts.body)
                HStack(spacing: 8) {
                    Button("Save") { saveEditingMemory(id: item.id) }
                        .buttonStyle(DSSecondaryButtonStyle(isFullWidth: false))
                        .disabled(editingDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Cancel") {
                        editingMemoryID = nil
                        editingDraft = ""
                    }
                    .buttonStyle(.plain)
                    .font(DS.Fonts.body)
                    .foregroundColor(DS.Colors.textSecondary)
                    .pointerCursor()
                    Spacer(minLength: 0)
                }
            }
            .padding(.vertical, 6)
        } else {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.text)
                        .font(DS.Fonts.body)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(DS.Fonts.micro)
                        .foregroundColor(DS.Colors.textTertiary)
                }
                Spacer(minLength: 0)
                Button("Edit") {
                    editingMemoryID = item.id
                    editingDraft = item.text
                }
                .buttonStyle(.plain)
                .font(DS.Fonts.caption)
                .foregroundColor(DS.Colors.textSecondary)
                .pointerCursor()
                Button {
                    memoryIDPendingForget = item.id
                    isConfirmingForgetOne = true
                } label: {
                    Image(systemName: "trash")
                        .foregroundColor(DS.Colors.destructiveText)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("Forget this")
            }
            .padding(.vertical, 6)
        }
    }

    private func saveEditingMemory(id: UUID) {
        let trimmed = editingDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        companionManager.updateMemory(id: id, text: trimmed)
        editingMemoryID = nil
        editingDraft = ""
    }

    private func exportMemories() {
        let exported = memoryExportText(companionManager.memoryItems)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(exported, forType: .string)
        presentMemoryExportSavePanel(exported)
    }

    private func memoryExportText(_ items: [MemoryItem]) -> String {
        items.map { item in
            let stamp = item.createdAt.formatted(date: .abbreviated, time: .shortened)
            return "\(stamp)\n\(item.text)"
        }
        .joined(separator: "\n\n")
    }

    private func presentMemoryExportSavePanel(_ exported: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "HeyMate-memories.txt"
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            try? exported.write(to: destination, atomically: true, encoding: .utf8)
        }
    }
}
