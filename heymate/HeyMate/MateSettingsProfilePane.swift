//
//  MateSettingsProfilePane.swift
//  HeyMate
//
//  Agent settings › Profile: picture, name, job, personality, habits, and
//  duplicate / archive / delete. Text saves once typing settles; a refused
//  name (taken, empty) shows why and keeps what was typed.
//

import SwiftUI

struct MateSettingsProfilePane: View {
    let context: MateSettingsContext
    @ObservedObject private var companionManager: CompanionManager

    @State private var name: String
    @State private var job: String
    @State private var soul: String
    @State private var howItWorks: [String]
    @State private var asksFirst: [String]
    @State private var selectedFace: String
    @State private var errorText: String?
    @State private var notice: String?
    @State private var isShowingCharacterEditor = false
    @State private var isDraftingHabits = false
    @State private var isConfirmingArchive = false
    @State private var profileSaver = MateSettingsDebouncer()
    @State private var habitSaver = MateSettingsDebouncer()

    init(context: MateSettingsContext) {
        self.context = context
        self.companionManager = context.companionManager
        let mate = context.mate
        _name = State(initialValue: mate.name)
        _job = State(initialValue: mate.job)
        _soul = State(initialValue: mate.soul)
        let habits = context.companionManager.agentHabits(for: mate)
        _howItWorks = State(initialValue: habits.howItWorks)
        _asksFirst = State(initialValue: habits.asksFirst)
        _selectedFace = State(initialValue: MateFace.selectionToken(for: mate))
    }

    private var mate: Mate { context.mate }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.SettingsLayout.sectionSpacing) {
            SettingsSection("Identity", footer: errorText == nil ? "Saved as you type." : nil) {
                identityRow
                    .mateSettingsAnchor("profile.picture")
                SettingsDivider()
                MateSettingsFieldRow(title: "Personality", subtitle: "How it talks and behaves",
                                     placeholder: "Clear and brief", text: $soul, lines: 2...5)
                    .mateSettingsAnchor("profile.soul")
                if let errorText {
                    SettingsNotice(text: errorText, tone: .critical)
                        .settingsRowContentInsets()
                }
            }

            SettingsSection("Habits", footer: "Kept in the agent's AGENTS.md, so its memory and these stay the same list.") {
                if howItWorks.isEmpty && asksFirst.isEmpty {
                    draftHabitsRow
                    SettingsDivider()
                }
                AgentHabitList(title: "How it works", hint: "Habits it keeps on every task",
                               placeholder: "Lead with the result", items: $howItWorks,
                               limit: AgentDrafter.maxHowItWorks)
                    .settingsRowInsets()
                    .mateSettingsAnchor("profile.howItWorks")
                SettingsDivider()
                AgentHabitList(title: "Asks you before", hint: "Never done without your yes",
                               placeholder: "Sending email", items: $asksFirst,
                               limit: AgentDrafter.maxAsksFirst)
                    .settingsRowInsets()
                    .mateSettingsAnchor("profile.asksFirst")
            }

            if !mate.conductsOthers {
                agentSection
            }
        }
        .onChange(of: name) { _, _ in scheduleProfileSave() }
        .onChange(of: job) { _, _ in scheduleProfileSave() }
        .onChange(of: soul) { _, _ in scheduleProfileSave() }
        .onChange(of: howItWorks) { _, _ in scheduleHabitSave() }
        .onChange(of: asksFirst) { _, _ in scheduleHabitSave() }
        .onDisappear {
            profileSaver.flush()
            habitSaver.flush()
        }
        .sheet(isPresented: $isShowingCharacterEditor) {
            MiloCharacterEditor(mate: mate, initialToken: selectedFace) { token in
                let current = mate
                let error = companionManager.updateMateProfile(
                    id: current.id, name: current.name, job: current.job,
                    soul: current.soul, faceAssetName: token
                )
                if error == nil { selectedFace = token }
                return error
            }
        }
    }

    private var identityRow: some View {
        HStack(alignment: .center, spacing: DS.Spacing.lg) {
            Button {
                isShowingCharacterEditor = true
            } label: {
                MateFaceView(mate: preview(selectedFace), size: 64, expression: .idle)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "paintbrush.pointed.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(DS.Colors.textPrimary, DS.Colors.surface3)
                    }
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Edit character")
            .accessibilityLabel("Edit character for \(mate.name)")

            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                TextField("Name", text: $name)
                    .settingsFieldChrome()
                    .accessibilityLabel("Name")
                TextField("What it does for you", text: $job)
                    .settingsFieldChrome()
                    .accessibilityLabel("Job")
            }
            .mateSettingsAnchor("profile.name")
        }
        .settingsRowInsets()
    }

    /// Older agents were made before habits existed. One click asks the AI
    /// to suggest them from the role; the draft saves like any other edit.
    private var draftHabitsRow: some View {
        SettingsRow("No habits yet", subtitle: "HeyMate can suggest them from the job. This uses one short turn on your plan.") {
            HStack(spacing: DS.Spacing.sm) {
                if isDraftingHabits { ProgressView().controlSize(.small) }
                Button("Draft habits") { draftHabits() }
                    .dsCapsuleButtonStyle(.secondary, height: DS.ControlSize.small)
                    .disabled(isDraftingHabits || job.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var agentSection: some View {
        SettingsSection("This agent") {
            SettingsRow("Duplicate", subtitle: "A copy with the same character, brain, habits and memory. Its routines come over paused.") {
                Button("Duplicate") {
                    profileSaver.flush()
                    habitSaver.flush()
                    notice = companionManager.duplicateMate(id: mate.id).map { "Made \($0.name)." }
                        ?? "Couldn't make a copy."
                }
                .dsCapsuleButtonStyle(.secondary, height: DS.ControlSize.small)
            }
            .mateSettingsAnchor("profile.duplicate")
            if let notice {
                SettingsInlineHelp(notice, tone: .positive).settingsRowContentInsets()
            }
            SettingsDivider()
            SettingsRow(mate.archived ? "Archived" : "Archive",
                        subtitle: mate.archived
                            ? "Hidden from the rail. Its routines and check-ins don't run."
                            : "Hides it from the rail and stops its routines and check-ins. Nothing is deleted.") {
                if mate.archived {
                    Button("Unarchive") { companionManager.unarchiveMate(id: mate.id) }
                        .dsCapsuleButtonStyle(.secondary, height: DS.ControlSize.small)
                } else {
                    Button("Archive…") { isConfirmingArchive = true }
                        .dsCapsuleButtonStyle(.secondary, height: DS.ControlSize.small)
                }
            }
            .mateSettingsAnchor("profile.archive")
            .confirmationDialog("Archive \(mate.name)?", isPresented: $isConfirmingArchive, titleVisibility: .visible) {
                Button("Archive") {
                    companionManager.archiveMate(id: mate.id)
                    context.close()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You can unarchive it from its settings later. Chats, routines and files stay.")
            }
            SettingsDivider()
            SettingsDestructiveRow(
                title: "Delete",
                subtitle: Mate.deletionWarning,
                buttonTitle: "Delete…",
                confirmationTitle: "Delete \(mate.name)?",
                confirmationMessage: Mate.deletionWarning,
                confirmButtonTitle: "Delete"
            ) {
                context.onDelete()
                context.close()
            }
            .mateSettingsAnchor("profile.delete")
        }
    }

    // MARK: Saving

    private func scheduleProfileSave() {
        profileSaver.schedule { saveProfile() }
    }

    private func saveProfile() {
        let current = mate
        guard name != current.name || job != current.job || soul != current.soul else {
            errorText = nil
            return
        }
        errorText = context.onSave(name, job, soul, selectedFace)
    }

    private func scheduleHabitSave() {
        habitSaver.schedule { saveHabits() }
    }

    private func saveHabits() {
        let saved = companionManager.agentHabits(for: mate)
        guard saved.howItWorks != howItWorks || saved.asksFirst != asksFirst else { return }
        companionManager.saveAgentHabits(id: mate.id, howItWorks: howItWorks, asksFirst: asksFirst)
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

    private func preview(_ asset: String) -> Mate {
        var copy = mate
        copy.faceAssetName = asset
        return copy
    }
}
