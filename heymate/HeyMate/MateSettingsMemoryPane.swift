//
//  MateSettingsMemoryPane.swift
//  HeyMate
//
//  Agent settings › Memory: the agent's notes and standing preferences as
//  rows that can be edited or removed. With a folder they live in its
//  AGENTS.md (MateWorkspaceMemory); without one, the note lives on the agent.
//

import SwiftUI

struct MateSettingsMemoryPane: View {
    let context: MateSettingsContext
    @ObservedObject private var companionManager: CompanionManager
    @State private var notes: [MateMemoryNote] = []
    @State private var standing: [String] = []
    @State private var plainNote = ""
    @State private var newNote = ""
    @State private var newStanding = ""
    @State private var editing: Edit?
    @State private var noteSaver = MateSettingsDebouncer()

    private enum Edit: Equatable {
        case note(Int, String)
        case standing(Int, String)
    }

    init(context: MateSettingsContext) {
        self.context = context
        self.companionManager = context.companionManager
    }

    private var mate: Mate { context.mate }
    private var folder: URL? {
        guard let path = mate.folderPath, FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.SettingsLayout.sectionSpacing) {
            if folder == nil {
                SettingsSection("Note", footer: "A short note only this agent keeps. Saved as you type.") {
                    MateSettingsFieldRow(title: "Note", placeholder: "Something it should always remember",
                                         text: $plainNote, lines: 2...6)
                }
                .mateSettingsAnchor("memory.note")
            } else {
                notesSection
                standingSection
            }
            SettingsSection {
                MateSettingsLinkRow(title: "Everything HeyMate remembers",
                                    subtitle: "Memories every agent shares, and whether chats are saved.",
                                    systemImage: "brain") {
                    context.openDesktopSection(.memory)
                }
            }
            .mateSettingsAnchor("memory.everything")
        }
        .onAppear(perform: load)
        .onChange(of: plainNote) { _, value in
            noteSaver.schedule {
                guard value != MateWorkspaceMemory.displayNote(for: mate) else { return }
                companionManager.updateMateMemory(id: mate.id, note: value)
            }
        }
        .onDisappear { noteSaver.flush() }
    }

    // MARK: Notes

    private var notesSection: some View {
        SettingsSection("Notes", footer: "Dated notes in AGENTS.md. When two disagree, the agent follows the later date.") {
            if notes.isEmpty {
                SettingsEmptyRow(text: "No notes yet. Add one below, or tell the agent “remember that…”.", systemImage: "note.text")
            }
            ForEach(Array(notes.enumerated()), id: \.offset) { index, note in
                if index > 0 { SettingsDivider() }
                if case .note(index, _) = editing {
                    editRow(text: editBinding, onSave: { commitNote(index) })
                } else {
                    itemRow(note.text, subtitle: note.date ?? "Undated",
                            onEdit: { editing = .note(index, note.text) },
                            onRemove: { saveNotes(notes.enumerated().filter { $0.offset != index }.map(\.element)) })
                }
            }
            SettingsDivider()
            addRow(placeholder: "Add a note, dated today", text: $newNote) {
                saveNotes(MateMemoryNotes.appending(newNote, to: notes, now: Date()))
                newNote = ""
            }
        }
        .mateSettingsAnchor("memory.note")
    }

    private func commitNote(_ index: Int) {
        guard case .note(_, let text) = editing, notes.indices.contains(index) else { return }
        var updated = notes
        updated[index].text = text
        editing = nil
        saveNotes(updated)
    }

    private func saveNotes(_ updated: [MateMemoryNote]) {
        let body = MateMemoryNotes.render(updated)
        companionManager.updateMateMemory(id: mate.id, note: body)
        load()
    }

    // MARK: Standing preferences

    private var standingSection: some View {
        SettingsSection("Standing preferences", footer: "The same list as Profile › Habits. “Ask first:” lines are things it asks you before doing.") {
            if standing.isEmpty {
                SettingsEmptyRow(text: "None yet. Add a habit it should keep on every task.", systemImage: "list.bullet")
            }
            ForEach(Array(standing.enumerated()), id: \.offset) { index, line in
                if index > 0 { SettingsDivider() }
                if case .standing(index, _) = editing {
                    editRow(text: editBinding, onSave: { commitStanding(index) })
                } else {
                    itemRow(line, subtitle: nil,
                            onEdit: { editing = .standing(index, line) },
                            onRemove: { saveStanding(standing.enumerated().filter { $0.offset != index }.map(\.element)) })
                }
            }
            SettingsDivider()
            addRow(placeholder: "Add a standing preference", text: $newStanding) {
                let cleaned = newStanding.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleaned.isEmpty else { return }
                saveStanding(standing + [cleaned])
                newStanding = ""
            }
        }
        .mateSettingsAnchor("memory.standing")
    }

    private func commitStanding(_ index: Int) {
        guard case .standing(_, let text) = editing, standing.indices.contains(index) else { return }
        var updated = standing
        updated[index] = text
        editing = nil
        saveStanding(updated)
    }

    private func saveStanding(_ lines: [String]) {
        guard let folder else { return }
        MateWorkspaceMemory.replaceStanding(lines, for: mate, in: folder)
        load()
    }

    // MARK: Rows

    private var editBinding: Binding<String> {
        Binding(
            get: {
                switch editing {
                case .note(_, let text), .standing(_, let text): text
                case nil: ""
                }
            },
            set: { value in
                switch editing {
                case .note(let index, _): editing = .note(index, value)
                case .standing(let index, _): editing = .standing(index, value)
                case nil: break
                }
            }
        )
    }

    private func itemRow(_ text: String, subtitle: String?, onEdit: @escaping () -> Void, onRemove: @escaping () -> Void) -> some View {
        SettingsRow(text, subtitle: subtitle) {
            HStack(spacing: DS.Spacing.sm) {
                Button("Edit", action: onEdit)
                    .dsCapsuleButtonStyle(.quiet, height: DS.ControlSize.small)
                    .disabled(editing != nil)
                    .accessibilityLabel("Edit: \(text)")
                Button(action: onRemove) {
                    Image(systemName: "trash")
                        .font(DS.Glyph.regular)
                        .foregroundColor(DS.Colors.textTertiary)
                        .dsIconHitArea()
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("Remove")
                .accessibilityLabel("Remove: \(text)")
            }
        }
    }

    private func editRow(text: Binding<String>, onSave: @escaping () -> Void) -> some View {
        HStack(spacing: DS.Spacing.sm) {
            TextField("", text: text, axis: .vertical)
                .lineLimit(1...5)
                .settingsFieldChrome()
                .onSubmit(onSave)
                .accessibilityLabel("Edit text")
            Button("Cancel") { editing = nil }
                .keyboardShortcut(.cancelAction)
                .dsCapsuleButtonStyle(.quiet, height: DS.ControlSize.small)
            Button("Save", action: onSave)
                .dsCapsuleButtonStyle(.primary, height: DS.ControlSize.small)
                .disabled(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .settingsRowInsets()
    }

    private func addRow(placeholder: String, text: Binding<String>, onAdd: @escaping () -> Void) -> some View {
        HStack(spacing: DS.Spacing.sm) {
            TextField(placeholder, text: text)
                .settingsFieldChrome()
                .onSubmit(onAdd)
                .accessibilityLabel(placeholder)
            Button("Add", action: onAdd)
                .dsCapsuleButtonStyle(.secondary, height: DS.ControlSize.small)
                .disabled(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .settingsRowInsets()
    }

    private func load() {
        plainNote = MateWorkspaceMemory.displayNote(for: mate)
        notes = MateMemoryNotes.parse(plainNote)
        standing = MateWorkspaceMemory.standingLines(for: mate)
    }
}
