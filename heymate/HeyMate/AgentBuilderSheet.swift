//
//  AgentBuilderSheet.swift
//  HeyMate
//
//  Make an agent in two steps: say what it should do, then review the draft
//  HeyMate wrote. Every field stays editable; nothing is created or sent
//  until the person presses Create.
//

import SwiftUI

struct AgentBuilderSheet: View {
    @ObservedObject var companionManager: CompanionManager
    var initialDescription: String = ""
    /// Opens straight on the review step. Used by previews and snapshots.
    var initialDraft: AgentDraft? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var description = ""
    @State private var draft: AgentDraft?
    @State private var draftUsedModel = true
    @State private var isDrafting = false
    @State private var faceAssetName = MateFace.packs[0].faces[0].assetName
    @State private var isPickingFace = false
    @State private var errorText: String?
    @FocusState private var isDescriptionFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let draft {
                review(Binding(get: { draft }, set: { self.draft = $0 }))
            } else {
                describe
            }
        }
        .frame(width: 540)
        .background(DS.Colors.background)
        .onAppear {
            if description.isEmpty { description = initialDescription }
            if draft == nil, let initialDraft { draft = initialDraft }
            isDescriptionFocused = true
        }
    }

    // MARK: Step 1

    private var describe: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("New agent")
                    .font(DS.Fonts.hero)
                    .foregroundColor(DS.Colors.textPrimary)
                Text("Say what it should do for you. HeyMate drafts how it works, and you can change anything before it is made.")
                    .font(DS.Fonts.body)
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextField(
                "Every morning, read my inbox and draft replies to customers",
                text: $description,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(DS.Fonts.bodyLarge)
            .lineLimit(3...6)
            .focused($isDescriptionFocused)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                    .fill(DS.Colors.surface2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.8)
            )
            .disabled(isDrafting)
            .onSubmit(startDraft)

            VStack(alignment: .leading, spacing: 6) {
                Text("Or start from")
                    .font(DS.Fonts.sectionLabel)
                    .foregroundColor(DS.Colors.textTertiary)
                ForEach(AgentSuggestionCatalog.all) { suggestion in
                    Button {
                        description = suggestion.job
                        faceAssetName = suggestion.faceAssetName
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.turn.down.right")
                                .font(DS.Glyph.small)
                                .foregroundColor(DS.Colors.textTertiary)
                            Text(suggestion.job)
                                .font(DS.Fonts.body)
                                .foregroundColor(DS.Colors.textSecondary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .disabled(isDrafting)
                }
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .dsCapsuleButtonStyle(.quiet)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if isDrafting {
                    ProgressView().controlSize(.small)
                    Text("Drafting…")
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.textTertiary)
                }
                Button("Draft agent", action: startDraft)
                    .dsCapsuleButtonStyle(.primary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isDrafting || trimmedDescription.isEmpty)
            }
        }
        .padding(22)
    }

    private var trimmedDescription: String {
        description.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func startDraft() {
        guard !trimmedDescription.isEmpty, !isDrafting else { return }
        isDrafting = true
        let text = trimmedDescription
        Task { @MainActor in
            let result = await companionManager.draftAgent(description: text)
            isDrafting = false
            draftUsedModel = result.usedModel
            draft = result.draft
        }
    }

    // MARK: Step 2

    private func review(_ draft: Binding<AgentDraft>) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    identityHeader(draft)
                    if !draftUsedModel {
                        Text("Drafted on this Mac without your AI. Edit the habits so they fit.")
                            .font(DS.Fonts.caption)
                            .foregroundColor(DS.Colors.warningText)
                    }
                    field("Personality", hint: "How it talks and behaves") {
                        TextField("Clear and brief", text: draft.personality, axis: .vertical)
                            .lineLimit(2...4)
                    }
                    AgentHabitList(
                        title: "How it works",
                        hint: "Habits it keeps on every task",
                        placeholder: "Lead with the result",
                        items: draft.howItWorks,
                        limit: AgentDrafter.maxHowItWorks
                    )
                    AgentHabitList(
                        title: "Asks you before",
                        hint: "Never done without your yes",
                        placeholder: "Sending email",
                        items: draft.asksFirst,
                        limit: AgentDrafter.maxAsksFirst
                    )
                    field("First task", hint: "Offered in its chat. Nothing runs until you send it") {
                        TextField("What to do first", text: draft.firstTask, axis: .vertical)
                            .lineLimit(1...3)
                    }
                    if !draft.wrappedValue.integrations.isEmpty {
                        integrationsRow(draft.wrappedValue.integrations)
                    }
                }
                .padding(22)
            }
            .frame(maxHeight: 560)

            Divider().overlay(DS.Colors.borderSubtle)

            HStack {
                Button("Back") { self.draft = nil }
                    .dsCapsuleButtonStyle(.quiet)
                if let errorText {
                    Text(errorText)
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.destructiveText)
                }
                Spacer()
                Button("Create agent") { create(draft.wrappedValue) }
                    .dsCapsuleButtonStyle(.primary)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
        }
    }

    private func identityHeader(_ draft: Binding<AgentDraft>) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Button { isPickingFace.toggle() } label: {
                MateFaceView(mate: previewMate(draft.wrappedValue), size: 64, expression: .idle)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "pencil.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(DS.Colors.textPrimary, DS.Colors.surface3)
                    }
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Choose a face")
            .accessibilityLabel("Choose a face")
            .disclosureSound(isPickingFace, .popover)
            .popover(isPresented: $isPickingFace, arrowEdge: .bottom) {
                facePicker(draft.wrappedValue)
            }
            VStack(alignment: .leading, spacing: 6) {
                TextField("Name", text: draft.name)
                    .textFieldStyle(.plain)
                    .font(DS.Fonts.hero)
                    .foregroundColor(DS.Colors.textPrimary)
                TextField("What it does for you", text: draft.role, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(DS.Fonts.bodyLarge)
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1...2)
            }
        }
    }

    private func facePicker(_ draft: AgentDraft) -> some View {
        let faces = MateFace.packs.flatMap(\.faces)
        return LazyVGrid(columns: Array(repeating: GridItem(.fixed(48), spacing: 10), count: 5), spacing: 10) {
            ForEach(faces) { face in
                Button {
                    faceAssetName = face.assetName
                    isPickingFace = false
                } label: {
                    MateFaceView(mate: previewMate(draft, asset: face.assetName), size: 44)
                        .overlay(
                            Circle().stroke(
                                face.assetName == faceAssetName ? DS.Colors.accent : Color.clear,
                                lineWidth: 2
                            )
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help(face.label)
                .accessibilityLabel(face.label)
            }
        }
        .padding(14)
    }

    private func integrationsRow(_ names: [String]) -> some View {
        let connected = Set(companionManager.connectedIntegrationNames.map { $0.lowercased() })
        let missing = names.filter { !connected.contains($0.lowercased()) }
        return VStack(alignment: .leading, spacing: 6) {
            fieldLabel("Uses", hint: missing.isEmpty ? "All connected" : "Connect the rest any time")
            HStack(spacing: 6) {
                ForEach(names, id: \.self) { name in
                    let isConnected = connected.contains(name.lowercased())
                    HStack(spacing: 5) {
                        Circle()
                            .fill(isConnected ? DS.Colors.success : DS.Colors.textTertiary)
                            .frame(width: 6, height: 6)
                        Text(name)
                            .font(DS.Fonts.caption)
                            .foregroundColor(DS.Colors.textSecondary)
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(Capsule().fill(DS.Colors.surface2))
                    .accessibilityLabel("\(name), \(isConnected ? "connected" : "not connected")")
                }
                if !missing.isEmpty {
                    Button("Open Integrations") {
                        companionManager.openDesktopWindow(section: .connectors)
                    }
                    .dsCapsuleButtonStyle(.quiet, height: DS.ControlSize.small)
                }
            }
        }
    }

    private func field<Content: View>(_ title: String, hint: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel(title, hint: hint)
            content()
                .textFieldStyle(.plain)
                .font(DS.Fonts.bodyLarge)
                .foregroundColor(DS.Colors.textPrimary)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .fill(DS.Colors.surface2)
                )
        }
    }

    private func fieldLabel(_ title: String, hint: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .font(DS.Fonts.headline)
                .foregroundColor(DS.Colors.textPrimary)
            Text(hint)
                .font(DS.Fonts.caption)
                .foregroundColor(DS.Colors.textTertiary)
        }
    }

    private func previewMate(_ draft: AgentDraft, asset: String? = nil) -> Mate {
        var mate = Mate(
            id: UUID(), name: draft.name.isEmpty ? "Agent" : draft.name, job: draft.role,
            pinned: false, archived: false, unreadCount: 0,
            createdAt: Date(), updatedAt: Date(), memoryNote: ""
        )
        mate.faceAssetName = asset ?? faceAssetName
        return mate
    }

    private func create(_ draft: AgentDraft) {
        guard !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !draft.role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorText = "It needs a name and what it does."
            return
        }
        if companionManager.createAgent(from: draft, faceAssetName: faceAssetName) != nil {
            dismiss()
        } else {
            errorText = "That name is already taken."
        }
    }
}

/// An editable list of short lines: edit in place, remove, or add one.
struct AgentHabitList: View {
    let title: String
    let hint: String
    let placeholder: String
    @Binding var items: [String]
    let limit: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(DS.Fonts.headline)
                    .foregroundColor(DS.Colors.textPrimary)
                Text(hint)
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textTertiary)
            }
            VStack(spacing: 0) {
                ForEach(items.indices, id: \.self) { index in
                    HStack(spacing: 8) {
                        Text("•")
                            .foregroundColor(DS.Colors.textTertiary)
                        TextField(placeholder, text: Binding(
                            get: { items.indices.contains(index) ? items[index] : "" },
                            set: { if items.indices.contains(index) { items[index] = $0 } }
                        ), axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(DS.Fonts.bodyLarge)
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1...3)
                        Button {
                            items.remove(at: index)
                        } label: {
                            Image(systemName: "xmark")
                                .font(DS.Glyph.small)
                                .foregroundColor(DS.Colors.textTertiary)
                        }
                        .buttonStyle(.plain)
                        .pointerCursor()
                        .help("Remove")
                        .accessibilityLabel("Remove \(items.indices.contains(index) ? items[index] : "")")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    if index < items.count - 1 {
                        Divider().overlay(DS.Colors.borderSubtle).padding(.leading, 24)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(DS.Colors.surface2)
            )
            if items.count < limit {
                Button {
                    items.append("")
                } label: {
                    Label("Add", systemImage: "plus")
                        .font(DS.Fonts.caption)
                }
                .dsCapsuleButtonStyle(.quiet, height: DS.ControlSize.small)
            }
        }
    }
}
