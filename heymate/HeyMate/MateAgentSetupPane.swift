import AppKit
import SwiftUI

/// Brain: pick a subscription, then a model, then how hard it thinks.
/// Shared by Settings and onboarding. Model and effort changes apply as
/// soon as they are picked; only a custom API needs an explicit save.
struct MateAgentSetupPane: View {
    @Binding var executablePath: String
    @Binding var profilePath: String
    @Binding var runtimePath: String
    @Binding var isWorking: Bool
    var onReady: (Bool) -> Void = { _ in }
    @StateObject private var setup = MateAgentSetupController()
    @StateObject private var subscription = MateAgentSubscriptionLoginController()
    @State private var provider = "openai-codex"
    @State private var model = ""
    @State private var effort = "medium"
    @State private var apiKey = ""
    @State private var baseURL = ""
    @State private var apiFormat = "openai-completions"
    @State private var authorizationCode = ""
    @State private var profileError: String?

    private struct Choice: Identifiable {
        let id: String
        let name: String
        let caption: String
        let brain: AgentBrain
    }
    private static let choices = [
        Choice(id: "openai-codex", name: "ChatGPT", caption: "Plus or Pro plan", brain: .codex),
        Choice(id: "anthropic", name: "Claude", caption: "Pro or Max plan", brain: .claudeCode),
        Choice(id: "heymate-custom", name: "Custom API", caption: "Your own endpoint and key", brain: .customAPI),
    ]
    private static let allEfforts = ["off", "minimal", "low", "medium", "high", "xhigh", "max"]

    private var configuration: MateAgentEngineConfiguration { .load() }
    private var isCustom: Bool { provider == "heymate-custom" }
    private var busy: Bool { setup.busy || subscription.busy }
    private func info(_ id: String) -> MateAgentSetupController.Provider? { setup.providers.first { $0.id == id } }
    private var selected: MateAgentSetupController.Provider? { info(provider) }
    private var connected: Bool { selected?.authenticated == true }
    private var providerName: String { Self.choices.first { $0.id == provider }?.name ?? "provider" }
    private var isCurrent: Bool { setup.currentProvider == provider && !setup.currentModel.isEmpty }

    /// Newest first, without dated snapshots that duplicate an alias.
    private var models: [String] {
        let all = selected?.models ?? []
        return all.reversed().filter { id in
            guard let range = id.range(of: #"-\d{8}$"#, options: .regularExpression) else { return true }
            return !all.contains(String(id[..<range.lowerBound]))
        }
    }
    /// Custom endpoints are unknown to Pi, so every level is offered and the user owns the choice.
    private var efforts: [String] { isCustom ? Self.allEfforts : selected?.efforts[model] ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.SettingsLayout.sectionSpacing) {
            SettingsSection("Subscription") {
                HStack(spacing: DS.Spacing.sm) {
                    ForEach(Self.choices) { tile($0) }
                }
                .padding(DS.Spacing.md)
                SettingsDivider(leadingInset: 0)
                if isCustom { customFields } else { signInRow }
            }

            SettingsSection("Model") {
                if isCustom {
                    SettingsRow("Model ID", subtitle: "Exactly as your provider names it.") {
                        TextField("model-name", text: $model).settingsFieldChrome(isMonospaced: true)
                            .frame(width: DS.SettingsLayout.pickerWidth)
                    }
                } else if connected, !models.isEmpty {
                    SettingsRow("Model", subtitle: "Newer models are listed first.") {
                        DSMenuPicker(accessibilityTitle: "Model", selection: $model,
                                     options: models.map { DSMenuOption(value: $0, title: selected?.modelNames[$0] ?? $0) },
                                     placeholder: "Choose a model", width: 240)
                    }
                } else {
                    SettingsEmptyRow(text: "Sign in with \(providerName) to choose a model.", systemImage: "lock")
                }
            }

            SettingsSection("Effort") {
                if efforts.isEmpty {
                    SettingsEmptyRow(text: "Choose a model to set how hard it thinks.", systemImage: "gauge.with.dots.needle.33percent")
                } else {
                    VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                        DSSegmentedControl(accessibilityTitle: "Effort", selection: $effort,
                                           segments: efforts.map { DSSegment(value: $0, title: Self.effortName($0)) },
                                           width: nil)
                        HStack {
                            Text("Faster").font(DS.Fonts.micro).foregroundColor(DS.Colors.textTertiary)
                            Spacer()
                            Text("Smarter").font(DS.Fonts.micro).foregroundColor(DS.Colors.textTertiary)
                        }
                        .padding(.horizontal, DS.Spacing.xs)
                        Text(Self.effortHint(effort)).font(DS.Fonts.caption).foregroundColor(DS.Colors.textSecondary)
                    }
                    .settingsRowInsets()
                }
            }

            statusLine
        }
        .disabled(profileError != nil)
        .task {
            do {
                if !FileManager.default.fileExists(atPath: configuration.profilePath) {
                    try MateAgentSetupController.createProfile(at: URL(fileURLWithPath: configuration.profilePath, isDirectory: true))
                }
                executablePath = ""; runtimePath = ""; profilePath = configuration.profilePath
                await setup.check(configuration)
                reflectSavedChoice()
            } catch { profileError = "Could not prepare HeyMate’s private account storage."; onReady(false) }
        }
        .onChange(of: busy) { isWorking = busy }
        .onChange(of: setup.ready) { onReady(setup.ready) }
        .onChange(of: provider) {
            apiKey = ""; authorizationCode = ""; subscription.resetStatus()
            chooseModel(); apply()
        }
        .onChange(of: model) { chooseEffort(); apply() }
        .onChange(of: effort) { apply() }
        .onChange(of: subscription.state) {
            if subscription.state == .connected {
                Task { await setup.check(configuration); chooseModel(); apply() }
            }
        }
        .onDisappear { apiKey = ""; authorizationCode = ""; isWorking = false; Task { await subscription.cancel() } }
    }

    // MARK: Subscription

    private func tile(_ choice: Choice) -> some View {
        let isSelected = choice.id == provider
        let signedIn = info(choice.id)?.authenticated == true
        return Button { provider = choice.id } label: {
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                HStack(alignment: .top) {
                    AgentBrandMark(brain: choice.brain, size: 22)
                        .foregroundColor(DS.Colors.textPrimary)
                    Spacer(minLength: 0)
                    if signedIn {
                        DSStatusDot(color: SettingsStatusTone.positive.dotColor)
                            .help("Connected")
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(choice.name).font(DS.Fonts.headline).foregroundColor(DS.Colors.textPrimary)
                    Text(choice.caption).font(DS.Fonts.caption).foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(1).minimumScaleFactor(0.85)
                }
            }
            .padding(DS.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                    .fill(isSelected ? DS.Colors.surface3 : DS.Colors.surface2.opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                    .stroke(isSelected ? DS.Colors.textPrimary.opacity(0.7) : DS.Colors.borderSubtle,
                            lineWidth: isSelected ? 1.5 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .pointerCursor(isEnabled: !isSelected && !busy)
        .animation(.easeOut(duration: DS.Animation.fast), value: isSelected)
        .accessibilityLabel("\(choice.name), \(choice.caption)")
        .accessibilityValue(signedIn ? "Connected" : "Not connected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder private var signInRow: some View {
        if connected && subscription.userCode == nil && subscription.verificationURL == nil {
            SettingsRow("Signed in to \(providerName)", subtitle: "Your plan answers HeyMate. No API key needed.") {
                Button("Switch account") { startSignIn() }
                    .dsCapsuleButtonStyle(.secondary).disabled(busy)
            }
        } else if subscription.userCode == nil && subscription.verificationURL == nil {
            SettingsRow("Sign in with \(providerName)",
                        subtitle: "Opens \(providerName) in your browser. Uses your plan, no API key.") {
                if subscription.busy {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Sign in") { startSignIn() }.dsCapsuleButtonStyle(.primary).disabled(busy)
                }
            }
        } else {
            signInSteps
        }
        if !subscription.status.isEmpty, subscription.state != .connected {
            SettingsInlineHelp(subscription.status, tone: subscription.state == .awaitingApproval ? .neutral : .attention)
                .settingsRowContentInsets()
        }
    }

    /// The device code or pasted authorization code, while sign-in is open.
    private var signInSteps: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            if let code = subscription.userCode {
                Text("Enter this code on the \(providerName) page")
                    .font(DS.Fonts.caption).foregroundColor(DS.Colors.textSecondary)
                HStack(spacing: DS.Spacing.md) {
                    Text(code)
                        .font(.system(size: 22, weight: .semibold, design: .monospaced))
                        .tracking(2)
                        .foregroundColor(DS.Colors.textPrimary)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                    }.dsCapsuleButtonStyle(.secondary, height: DS.ControlSize.small)
                }
                .padding(DS.Spacing.md)
                .dsSurface(.inset, cornerRadius: DS.CornerRadius.medium)
            }
            if provider == "anthropic", subscription.verificationURL != nil {
                Text("Approve in your browser, then paste the code Claude shows you.")
                    .font(DS.Fonts.caption).foregroundColor(DS.Colors.textSecondary)
                HStack(spacing: DS.Spacing.sm) {
                    SecureField("Authorization code", text: $authorizationCode).settingsFieldChrome(isMonospaced: true)
                    Button("Finish") {
                        let code = authorizationCode; authorizationCode = ""
                        Task { await subscription.submitCode(code) }
                    }
                    .dsCapsuleButtonStyle(.primary)
                    .disabled(authorizationCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            HStack(spacing: DS.Spacing.sm) {
                if let url = subscription.verificationURL {
                    Button("Open \(providerName)") { NSWorkspace.shared.open(url) }.dsCapsuleButtonStyle(.secondary)
                }
                Spacer(minLength: 0)
                if subscription.busy {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { Task { await subscription.cancel() } }.dsCapsuleButtonStyle(.secondary)
                }
            }
        }
        .settingsRowInsets()
    }

    private var customFields: some View {
        VStack(spacing: 0) {
            SettingsRow("Endpoint", subtitle: "HTTPS base URL, for example https://api.example.com/v1") {
                TextField("https://", text: $baseURL).settingsFieldChrome(isMonospaced: true)
                    .frame(width: DS.SettingsLayout.pickerWidth)
            }
            SettingsDivider()
            SettingsRow("Format") {
                DSMenuPicker(accessibilityTitle: "API format", selection: $apiFormat, options: [
                    DSMenuOption(value: "openai-completions", title: "OpenAI Chat Completions"),
                    DSMenuOption(value: "openai-responses", title: "OpenAI Responses"),
                    DSMenuOption(value: "anthropic-messages", title: "Anthropic Messages"),
                    DSMenuOption(value: "google-generative-ai", title: "Google Generative AI"),
                ])
            }
            SettingsDivider()
            SettingsRow("API key", subtitle: connected ? "Leave blank to keep the saved key." : "Stored privately on this Mac. Billed by your provider.") {
                SecureField(connected ? "••••••••" : "Paste key", text: $apiKey).settingsFieldChrome(isMonospaced: true)
                    .frame(width: DS.SettingsLayout.pickerWidth)
            }
            SettingsDivider()
            HStack {
                Spacer()
                Button("Save and use") { save() }
                    .dsCapsuleButtonStyle(.primary)
                    .disabled(busy || model.isEmpty || baseURL.isEmpty || (!connected && apiKey.isEmpty))
            }
            .settingsRowInsets()
        }
    }

    // MARK: Status

    @ViewBuilder private var statusLine: some View {
        if let profileError {
            SettingsNotice(text: profileError, tone: .critical)
        } else if busy {
            SettingsStatusBadge(text: subscription.busy ? "Waiting for sign-in…" : "Saving…", tone: .progress)
        } else if setup.ready, !setup.currentModel.isEmpty {
            HStack(spacing: DS.Spacing.sm) {
                if let current = Self.choices.first(where: { $0.id == setup.currentProvider }) {
                    AgentBrandMark(brain: current.brain, size: 16).foregroundColor(DS.Colors.textSecondary)
                }
                Text("\(info(setup.currentProvider)?.modelNames[setup.currentModel] ?? setup.currentModel) · \(Self.effortName(setup.currentEffort)) effort")
                    .font(DS.Fonts.caption).foregroundColor(DS.Colors.textSecondary)
                SettingsStatusBadge(text: "Ready", tone: .positive)
            }
            .padding(.horizontal, DS.Spacing.xs)
        } else if let status = setup.status {
            SettingsNotice(text: status, tone: .attention)
        }
    }

    // MARK: Actions

    private func startSignIn() { Task { await subscription.start(configuration, provider: provider) } }

    /// Signed-in plans apply right away; a custom API waits for "Save and use".
    private func apply() {
        guard !isCustom, connected, !model.isEmpty,
              setup.currentProvider != provider || setup.currentModel != model || setup.currentEffort != effort else { return }
        save()
    }

    private func save() {
        let key = apiKey
        apiKey = ""
        Task {
            await setup.connect(configuration, provider: provider, model: model, key: key,
                                effort: effort, baseURL: baseURL, apiFormat: apiFormat)
            if setup.ready { await setup.check(configuration) }
        }
    }

    private func chooseModel() {
        model = setup.currentProvider == provider ? setup.currentModel : models.first ?? ""
        if isCustom { baseURL = setup.currentBaseURL; apiFormat = setup.currentAPIFormat }
        chooseEffort()
    }
    /// Keeps the saved effort for the saved model, otherwise the closest level the new model supports.
    private func chooseEffort() {
        let wanted = setup.currentProvider == provider && setup.currentModel == model ? setup.currentEffort : effort
        guard !efforts.isEmpty, !efforts.contains(wanted) else { effort = wanted; return }
        effort = efforts.contains("medium") ? "medium" : efforts[efforts.count / 2]
    }
    private func reflectSavedChoice() {
        if Self.choices.contains(where: { $0.id == setup.currentProvider }) { provider = setup.currentProvider }
        chooseModel()
    }

    static func effortName(_ level: String) -> String {
        switch level {
        case "off": return "Off"
        case "minimal": return "Minimal"
        case "low": return "Low"
        case "medium": return "Medium"
        case "high": return "High"
        case "xhigh": return "Extra"
        case "max": return "Max"
        default: return level
        }
    }
    static func effortHint(_ level: String) -> String {
        switch level {
        case "off": return "Answers straight away without extra thinking."
        case "minimal", "low": return "Quick thinking for everyday asks."
        case "medium": return "Balanced speed and depth. A good default."
        case "high": return "Thinks longer on harder problems."
        default: return "Deepest thinking. Slower, and uses more of your plan."
        }
    }
}
