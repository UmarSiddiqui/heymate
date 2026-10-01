//
//  MateSettingsSheet.swift
//  leanring-buddy
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
    var onSave: (String, String, String, String?) -> String?
    var onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var job: String
    @State private var soul: String
    @State private var memoryNote: String
    @State private var selectedFace: String
    @State private var isImportingPicture = false
    @State private var isConfirmingDelete = false
    @State private var errorText: String?

    init(
        mate: Mate,
        companionManager: CompanionManager,
        isLastNonArchivedMate: Bool,
        onOpenSection: @escaping (DesktopSection) -> Void,
        onSave: @escaping (String, String, String, String?) -> String?,
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
        _memoryNote = State(initialValue: mate.memoryNote)
        _selectedFace = State(initialValue: MateFace.selectionToken(for: mate))
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
        .frame(width: 440)
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
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit \(mate.name)")
                .font(DS.Fonts.hero)
                .foregroundColor(DS.Colors.textPrimary)

            sectionLabel("Picture")
            if MateFaceStore.fileURL(for: selectedFace) != nil {
                HStack(spacing: 10) {
                    MateFaceView(mate: preview(selectedFace), size: 40)
                        .overlay {
                            Circle().stroke(DS.Colors.textPrimary, lineWidth: 2)
                        }
                    Text("Your picture")
                        .font(DS.Fonts.headline)
                        .foregroundColor(DS.Colors.textPrimary)
                }
            }
            // The whole sheet scrolls now, so the face grid lays out flat
            // instead of nesting a second scroll view.
            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(44), spacing: 8), count: 6),
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(MateFace.assetNames, id: \.self) { asset in
                    Button {
                        selectedFace = asset
                    } label: {
                        MateFaceView(mate: preview(asset), size: 40)
                            .overlay {
                                Circle().stroke(
                                    selectedFace == asset ? DS.Colors.textPrimary : Color.clear,
                                    lineWidth: 2
                                )
                            }
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .accessibilityLabel("Choose this picture")
                }
            }
            Button("Use your own picture") { isImportingPicture = true }
                .buttonStyle(.plain)
                .font(DS.Fonts.headline)
                .foregroundColor(DS.Colors.textSecondary)
                .pointerCursor()

            sectionLabel("Details")
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
            TextField("Job, in one sentence", text: $job)
                .textFieldStyle(.roundedBorder)

            sectionLabel("Soul")
            TextField("How this mate sounds and behaves", text: $soul, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...6)

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

    // MARK: What this mate knows and does

    /// The mate's own note is edited here and saved with Save. Long-term
    /// memories are shared by every mate, so they open on their own page.
    private var memorySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Memory")
            TextField("A short note only this mate keeps", text: $memoryNote, axis: .vertical)
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
                sheetLink("See jobs", systemImage: DesktopSection.agents.symbolName) {
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
        return "\(countText). Skills are short instructions every mate can use when they fit the request."
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

    private func preview(_ asset: String) -> Mate {
        var copy = mate
        copy.faceAssetName = asset
        return copy
    }

    private func save() {
        if let error = onSave(name, job, soul, selectedFace) {
            errorText = error
            return
        }
        if memoryNote != mate.memoryNote {
            companionManager.updateMateMemory(id: mate.id, note: memoryNote)
        }
        dismiss()
    }
}
