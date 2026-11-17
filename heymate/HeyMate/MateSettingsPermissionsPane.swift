//
//  MateSettingsPermissionsPane.swift
//  HeyMate
//
//  Agent settings › Permissions: the approval mode in force for this agent
//  (HeyMate's Ask me / Full access, or a stricter "Always ask"), its allow /
//  ask / deny rules with add, edit and delete, the floor that always asks,
//  and a read-only list of what it can reach.
//

import SwiftUI

struct MateSettingsPermissionsPane: View {
    let context: MateSettingsContext
    @ObservedObject private var companionManager: CompanionManager
    @ObservedObject private var rules = MateApprovalRuleStore.shared
    @ObservedObject private var settings = MateAgentSettingsStore.shared
    @AppStorage(ApprovalMode.preferenceKey) private var globalModeRaw = ApprovalMode.askMe.rawValue
    @State private var editor: RuleDraft?

    init(context: MateSettingsContext) {
        self.context = context
        self.companionManager = context.companionManager
    }

    private var mate: Mate { context.mate }
    private var globalMode: ApprovalMode { ApprovalMode(rawValue: globalModeRaw) ?? .askMe }
    private var override: MateApprovalOverride { settings.settings(for: mate.id).approval }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.SettingsLayout.sectionSpacing) {
            SettingsSection("Approvals", footer: modeFooter) {
                SettingsRow("Approval mode", subtitle: "HeyMate is set to \(globalMode.title). This agent can only be stricter.") {
                    DSSegmentedControl(
                        accessibilityTitle: "Approval mode for \(mate.name)",
                        selection: Binding(
                            get: { override },
                            set: { value in settings.update(mate.id) { $0.approval = value } }
                        ),
                        segments: [
                            DSSegment(value: .inherit, title: "Same as HeyMate", help: "Follow HeyMate's \(globalMode.title)"),
                            DSSegment(value: .alwaysAsk, title: "Always ask", help: "Ask before every command and file change"),
                        ]
                    )
                }
                .mateSettingsAnchor("permissions.mode")
            }

            SettingsSection("Rules", headerAccessory: AnyView(
                Button("Add rule…") { editor = RuleDraft() }
                    .dsCapsuleButtonStyle(.secondary, height: DS.ControlSize.small)
                    .disabled(editor != nil)
            )) {
                if let editor {
                    RuleEditor(draft: editor, onCancel: { self.editor = nil }, onSave: save)
                        .id(editor.editingID?.uuidString ?? "new")
                    if !currentRules.isEmpty { SettingsDivider() }
                }
                if currentRules.isEmpty && editor == nil {
                    SettingsEmptyRow(
                        text: "No rules yet. Choose “Always allow this” on an approval card, or add one here.",
                        systemImage: "hand.raised"
                    )
                }
                ForEach(Array(currentRules.enumerated()), id: \.element.id) { index, rule in
                    if index > 0 { SettingsDivider() }
                    ruleRow(rule)
                }
            }
            .mateSettingsAnchor("permissions.rules")

            SettingsSection("Always asks") {
                SettingsRow(
                    "Some things always ask",
                    subtitle: "Sending, deleting, money or passwords, publishing, and network or system programs ask every time, whatever the mode or rules say. A chained command never matches an allow rule.",
                    systemImage: "lock"
                )
            }
            .mateSettingsAnchor("permissions.floor")

            SettingsSection("What it can reach", footer: "Change these in Files & Browser and Apps & Skills.") {
                reachRow("Folder", value: mate.folderPath.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "No folder yet",
                         systemImage: "folder")
                SettingsDivider()
                reachRow("Connected apps", value: appsSummary, systemImage: "puzzlepiece.extension")
                SettingsDivider()
                reachRow("Browser", value: browserSummary, systemImage: "globe")
                SettingsDivider()
                reachRow("Skills", value: skillsSummary, systemImage: "wand.and.stars")
            }
            .mateSettingsAnchor("permissions.reach")
        }
    }

    private var modeFooter: String {
        switch (globalMode, override) {
        case (_, .alwaysAsk): "Asks before every command and file change. Allow rules are set aside; ask and deny rules still apply."
        case (.fullAccess, .inherit): "Full access: reversible work runs without a card. The things below still ask."
        case (.askMe, .inherit): "Ask me: a card asks before each command and file change, unless a rule below allows it."
        }
    }

    private var currentRules: [MateApprovalRule] { rules.rules(for: mate.id) }

    private func ruleRow(_ rule: MateApprovalRule) -> some View {
        SettingsRow(rule.summary, subtitle: "\(RuleDraft.toolTitle(rule.tool)) · added \(rule.createdAt.formatted(date: .abbreviated, time: .omitted))") {
            HStack(spacing: DS.Spacing.sm) {
                Button("Edit") { editor = RuleDraft(rule) }
                    .dsCapsuleButtonStyle(.quiet, height: DS.ControlSize.small)
                    .accessibilityLabel("Edit rule: \(rule.summary)")
                Button {
                    rules.remove(id: rule.id, mateID: mate.id)
                } label: {
                    Image(systemName: "trash")
                        .font(DS.Glyph.regular)
                        .foregroundColor(DS.Colors.textTertiary)
                        .dsIconHitArea()
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("Delete this rule")
                .accessibilityLabel("Delete rule: \(rule.summary)")
            }
        }
    }

    private func save(_ draft: RuleDraft) {
        let rule = MateApprovalRule(tool: draft.tool, pattern: draft.trimmedPattern, decision: draft.decision)
        if let id = draft.editingID {
            rules.replace(id: id, with: rule, mateID: mate.id)
        } else {
            rules.add(rule, mateID: mate.id)
        }
        editor = nil
    }

    private func reachRow(_ title: String, value: String, systemImage: String) -> some View {
        SettingsRow(title, subtitle: value, systemImage: systemImage)
    }

    private var appsSummary: String {
        let items = ConnectedIntegrations.items(store: companionManager.connectorStore, composio: companionManager.composioConnections)
        let on = items.filter { companionManager.isConnectorSelectionEnabled($0.id, for: mate) }
        guard !items.isEmpty else { return "Nothing connected." }
        return on.isEmpty ? "None turned on." : on.map(\.name).joined(separator: ", ")
    }

    private var browserSummary: String {
        mate.archived ? "Off while archived." : "Its own browser profile, apart from your Chrome. See Files & Browser."
    }

    private var skillsSummary: String {
        if let names = mate.enabledSkillNames {
            return names.isEmpty ? "No skills." : names.joined(separator: ", ")
        }
        let active = companionManager.discoveredSkills.filter { companionManager.isSkillActive($0) }.count
        return active == 1 ? "HeyMate's 1 skill." : "HeyMate's \(active) skills."
    }
}

/// The add / edit form for one rule.
struct RuleDraft: Equatable {
    var editingID: UUID?
    var tool = "bash"
    var pattern = ""
    var decision: MateApprovalRule.Decision = .allow

    init() {}

    init(_ rule: MateApprovalRule) {
        editingID = rule.id
        tool = rule.tool
        pattern = rule.pattern
        decision = rule.decision
    }

    static let maximumPatternLength = 300

    var trimmedPattern: String { pattern.trimmingCharacters(in: .whitespacesAndNewlines) }

    var problem: String? {
        if trimmedPattern.isEmpty { return "Type what it matches." }
        if trimmedPattern.count > Self.maximumPatternLength { return "Keep it under \(Self.maximumPatternLength) characters." }
        if trimmedPattern.contains("\n") { return "One line only." }
        return nil
    }

    static func toolTitle(_ tool: String) -> String {
        switch tool {
        case "write": "Writing files"
        case "edit": "Editing files"
        default: "Commands"
        }
    }

    var placeholder: String { tool == "bash" ? "git status*" : "notes/**" }
}

private struct RuleEditor: View {
    @State var draft: RuleDraft
    let onCancel: () -> Void
    let onSave: (RuleDraft) -> Void
    @FocusState private var isPatternFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            HStack(spacing: DS.Spacing.md) {
                DSMenuPicker(
                    accessibilityTitle: "What the rule covers",
                    selection: $draft.tool,
                    options: ["bash", "write", "edit"].map { DSMenuOption(value: $0, title: RuleDraft.toolTitle($0)) },
                    width: 150
                )
                DSSegmentedControl(
                    accessibilityTitle: "Decision",
                    selection: $draft.decision,
                    segments: [
                        DSSegment(value: .allow, title: "Allow"),
                        DSSegment(value: .ask, title: "Ask"),
                        DSSegment(value: .deny, title: "Deny"),
                    ],
                    width: 200
                )
            }
            TextField(draft.placeholder, text: $draft.pattern)
                .settingsFieldChrome(isMonospaced: true)
                .focused($isPatternFocused)
                .onSubmit { if draft.problem == nil { onSave(draft) } }
                .accessibilityLabel("Pattern")
                .accessibilityHint("* matches anything. For files, a path inside the agent's folder.")
            HStack {
                SettingsInlineHelp(draft.problem.map { $0 } ?? "* matches anything. File paths are inside the agent's folder.",
                                   tone: draft.problem == nil || draft.pattern.isEmpty ? .neutral : .attention)
                Spacer(minLength: DS.Spacing.sm)
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .dsCapsuleButtonStyle(.quiet, height: DS.ControlSize.small)
                Button(draft.editingID == nil ? "Add rule" : "Save rule") { onSave(draft) }
                    .dsCapsuleButtonStyle(.primary, height: DS.ControlSize.small)
                    .disabled(draft.problem != nil)
            }
        }
        .settingsRowInsets()
        .onAppear { isPatternFocused = true }
    }
}
