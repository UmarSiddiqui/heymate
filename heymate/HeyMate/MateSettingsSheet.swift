//
//  MateSettingsSheet.swift
//  HeyMate
//
//  Everything about one mate in one place: picture, details, and soul, plus
//  what it remembers, what it does on a schedule, and the skills it uses.
//  Memory, routines, and skills used to be separate top-level pages; a user
//  thinking "how do I change what this mate does?" now finds them here.
//

import SwiftUI
import UniformTypeIdentifiers

struct MateSettingsSheet: View {
    let mate: Mate
    @ObservedObject var companionManager: CompanionManager
    var isLastNonArchivedMate: Bool
    /// Opens a desktop page (all memories, the skills library, Jobs) after
    /// the sheet closes.
    var onOpenSection: (DesktopSection) -> Void
    var onSave: (String, String, String, String?, String?, String?, String?) -> String?
    var onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var job: String
    @State private var soul: String
    @State private var memoryNote: String
    @State private var selectedFace: String
    @State private var faceTint: String
    @State private var faceHair: String
    @State private var faceOutfit: String
    @State private var howItWorks: [String]
    @State private var asksFirst: [String]
    @State private var isShowingLook = false
    @State private var isDraftingHabits = false
    @State private var isImportingPicture = false
    @State private var isConfirmingDelete = false
    @State private var errorText: String?

    init(
        mate: Mate,
        companionManager: CompanionManager,
        isLastNonArchivedMate: Bool,
        onOpenSection: @escaping (DesktopSection) -> Void,
        onSave: @escaping (String, String, String, String?, String?, String?, String?) -> String?,
        onDelete: @escaping () -> Void
    ) {
        self.mate = mate
        self.companionManager = companionManager
        self.isLastNonArchivedMate = isLastNonArchivedMate
        self.onOpenSection = onOpenSection
        self.onSave = onSave
        self.onDelete = onDelete
        _name = State(initialValue: mate.name)
        _job = State(initialValue: mate.job)
        _soul = State(initialValue: mate.soul)
        _memoryNote = State(initialValue: MateWorkspaceMemory.displayNote(for: mate))
        _selectedFace = State(initialValue: MateFace.selectionToken(for: mate))
        _faceTint = State(initialValue: mate.faceTint ?? "")
        _faceHair = State(initialValue: mate.faceHair ?? MateFaceHair.none.rawValue)
        _faceOutfit = State(initialValue: mate.faceOutfit ?? MateFaceOutfit.none.rawValue)
        let habits = companionManager.agentHabits(for: mate)
        _howItWorks = State(initialValue: habits.howItWorks)
        _asksFirst = State(initialValue: habits.asksFirst)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                profileFields
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Rectangle().fill(DS.Colors.borderSubtle).frame(height: 1)
            HStack {
                Button("Delete", role: .destructive) { isConfirmingDelete = true }
                    .foregroundColor(DS.Colors.destructiveText)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 520)
        .frame(minHeight: 360, idealHeight: 640, maxHeight: 760)
        .confirmationDialog(
            "Delete \(mate.name)?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                onDelete()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(Mate.deletionWarning(replacesWithFreshHeyMate: isLastNonArchivedMate))
        }
        .fileImporter(
            isPresented: $isImportingPicture,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first, let token = MateFaceStore.importImage(from: url) else {
                    errorText = "That picture could not be saved."
                    return
                }
                selectedFace = token
                errorText = nil
            case .failure:
                errorText = "That picture could not be opened."
            }
        }
    }

    private var profileFields: some View {
        VStack(alignment: .leading, spacing: 18) {
            identityHeader

            if isShowingLook {
                lookPanel
            }

            labeled("Personality", hint: "How it talks and behaves") {
                TextField("Clear and brief", text: $soul, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...5)
            }
            if howItWorks.isEmpty && asksFirst.isEmpty {
                draftHabitsRow
            }
            AgentHabitList(
                title: "How it works",
                hint: "Habits it keeps on every task",
                placeholder: "Lead with the result",
                items: $howItWorks,
                limit: AgentDrafter.maxHowItWorks
            )
            AgentHabitList(
                title: "Asks you before",
                hint: "Never done without your yes",
                placeholder: "Sending email",
                items: $asksFirst,
                limit: AgentDrafter.maxAsksFirst
            )

            memorySection
            routinesSection
            skillsSection

            if let errorText {
                Text(errorText)
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.destructiveText)
            }
        }
    }

    /// Face, name and role together, the way the agent appears everywhere
    /// else. The face opens the look controls instead of leading the sheet.
    private var identityHeader: some View {
        HStack(alignment: .center, spacing: 14) {
            Button {
                withAnimation(DS.Animation.controlSpring) { isShowingLook.toggle() }
            } label: {
                MateFaceView(mate: preview(selectedFace), size: 64, expression: .idle)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: isShowingLook ? "chevron.up.circle.fill" : "pencil.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(DS.Colors.textPrimary, DS.Colors.surface3)
                    }
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help(isShowingLook ? "Hide the look" : "Change the look")
            .accessibilityLabel(isShowingLook ? "Hide the look" : "Change the look")
            VStack(alignment: .leading, spacing: 6) {
                TextField("Name", text: $name)
                    .textFieldStyle(.plain)
                    .font(DS.Fonts.hero)
                    .foregroundColor(DS.Colors.textPrimary)
                TextField("What it does for you", text: $job, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(DS.Fonts.bodyLarge)
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1...2)
            }
        }
    }

    private var lookPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            if MateFaceStore.fileURL(for: selectedFace) != nil {
                HStack(spacing: 10) {
                    MateFaceView(mate: preview(selectedFace), size: 40)
                        .overlay { Circle().stroke(DS.Colors.textPrimary, lineWidth: 2) }
                    Text("Your picture")
                        .font(DS.Fonts.headline)
                        .foregroundColor(DS.Colors.textPrimary)
                }
            }
            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(44), spacing: 8), count: 8),
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(MateFace.packs.flatMap(\.faces)) { face in
                    Button {
                        selectedFace = face.assetName
                    } label: {
                        MateFaceView(mate: preview(face.assetName), size: 40)
                            .overlay {
                                Circle().stroke(
                                    selectedFace == face.assetName ? DS.Colors.textPrimary : Color.clear,
                                    lineWidth: 2
                                )
                            }
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .help(face.label)
                    .accessibilityLabel(face.label)
                }
            }
            lookControls
            Button("Use your own picture") { isImportingPicture = true }
                .dsCapsuleButtonStyle(.quiet, height: DS.ControlSize.small)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .fill(DS.Colors.surface1)
        )
    }

    /// Older agents were made before habits existed. One click asks the AI
    /// to suggest them from the role, and nothing saves until Save.
    private var draftHabitsRow: some View {
        HStack(spacing: 10) {
            Text("No habits yet. HeyMate can suggest them from the role.")
                .font(DS.Fonts.body)
                .foregroundColor(DS.Colors.textSecondary)
            Spacer(minLength: 8)
            if isDraftingHabits {
                ProgressView().controlSize(.small)
            }
            Button("Draft habits") { draftHabits() }
                .dsCapsuleButtonStyle(.secondary, height: DS.ControlSize.small)
                .disabled(isDraftingHabits || job.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func draftHabits() {
        isDraftingHabits = true
        let description = [job, soul].filter { !$0.isEmpty }.joined(separator: ". ")
        Task { @MainActor in
            let result = await companionManager.draftAgent(description: description)
            isDraftingHabits = false
            howItWorks = result.draft.howItWorks
            asksFirst = result.draft.asksFirst
            if soul.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                soul = result.draft.personality
            }
        }
    }

    private func labeled<Content: View>(_ title: String, hint: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(DS.Fonts.headline)
                    .foregroundColor(DS.Colors.textPrimary)
                Text(hint)
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textTertiary)
            }
            content()
        }
    }

    // MARK: What this mate knows and does

    /// Notes for this mate live in their folder. This field edits that text
    /// and saves it with Save. Memories shared by every mate open on their own page.
    private var memorySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Memory")
            TextField("A short note only this agent keeps", text: $memoryNote, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...5)
            sheetLink("Everything HeyMate remembers", systemImage: "brain") {
                open(.memory)
            }
        }
    }

    /// Routines save as soon as they're added or edited, like in the chat
    /// side panel; they aren't part of the profile Save.
    private var routinesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Routines")
            RoutineAddField(companionManager: companionManager, mateID: mate.id)
            let routines = companionManager.routines.filter { $0.mateID == mate.id }
            if routines.isEmpty {
                Text("Nothing scheduled. Try “check my inbox every morning”.")
                    .font(DS.Fonts.body)
                    .foregroundColor(DS.Colors.textTertiary)
            }
            ForEach(routines) { routine in
                RoutineRow(
                    routine: routine,
                    showsMateName: false,
                    mateName: mate.name,
                    companionManager: companionManager
                )
            }
        }
    }

    /// Skills shape how every mate answers, so they're shared; this is the
    /// door to them from the place people look for "what can it do".
    private var skillsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Skills")
            Text(skillsSummary)
                .font(DS.Fonts.body)
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                sheetLink("Manage skills", systemImage: "wand.and.stars") {
                    open(.skills)
                }
                sheetLink("See activity", systemImage: DesktopSection.agents.symbolName) {
                    open(.agents)
                }
            }
        }
    }

    private var skillsSummary: String {
        let activeCount = companionManager.discoveredSkills
            .filter { companionManager.isSkillActive($0) }
            .count
        let countText = activeCount == 1 ? "1 skill is on" : "\(activeCount) skills are on"
        return "\(countText). Skills are short instructions every agent can use when they fit the request."
    }

    private func sheetLink(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(DS.Fonts.control)
                .foregroundColor(DS.Colors.textSecondary)
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    /// Closes the sheet first: the page it opens replaces the chat behind it.
    private func open(_ section: DesktopSection) {
        dismiss()
        onOpenSection(section)
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(DS.Fonts.sectionLabel)
            .foregroundColor(DS.Colors.textTertiary)
    }

    private var lookControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                tintButton(hex: "")
                ForEach(MateFace.tintSwatches, id: \.self) { hex in
                    tintButton(hex: hex)
                }
            }
            chipRow(MateFaceHair.allCases.map { ($0.rawValue, $0.label) }, selection: $faceHair)
            chipRow(MateFaceOutfit.allCases.map { ($0.rawValue, $0.label) }, selection: $faceOutfit)
        }
    }

    private func tintButton(hex: String) -> some View {
        let selected = faceTint == hex
        return Button {
            faceTint = hex
        } label: {
            Circle()
                .fill(hex.isEmpty ? DS.Colors.surface3 : (MateFace.color(hex: hex) ?? DS.Colors.surface3))
                .frame(width: 22, height: 22)
                .overlay {
                    Circle().stroke(selected ? DS.Colors.textPrimary : Color.clear, lineWidth: 2)
                }
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .accessibilityLabel(hex.isEmpty ? "No color" : "Color \(hex)")
    }

    private func chipRow(_ items: [(String, String)], selection: Binding<String>) -> some View {
        HStack(spacing: 6) {
            ForEach(items, id: \.0) { item in
                Button {
                    selection.wrappedValue = item.0
                } label: {
                    Text(item.1)
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.textPrimary)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(
                            Capsule().fill(selection.wrappedValue == item.0 ? DS.Colors.surface4 : DS.Colors.surface2)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
    }

    private func preview(_ asset: String) -> Mate {
        var copy = mate
        copy.faceAssetName = asset
        copy.faceTint = faceTint.isEmpty ? nil : faceTint
        copy.faceHair = faceHair
        copy.faceOutfit = faceOutfit
        return copy
    }

    private func save() {
        if let error = onSave(
            name,
            job,
            soul,
            selectedFace,
            faceTint.isEmpty ? nil : faceTint,
            faceHair,
            faceOutfit
        ) {
            errorText = error
            return
        }
        if memoryNote != mate.memoryNote {
            companionManager.updateMateMemory(id: mate.id, note: memoryNote)
        }
        let saved = companionManager.agentHabits(for: mate)
        if saved.howItWorks != howItWorks || saved.asksFirst != asksFirst {
            companionManager.saveAgentHabits(id: mate.id, howItWorks: howItWorks, asksFirst: asksFirst)
        }
        dismiss()
    }
}
