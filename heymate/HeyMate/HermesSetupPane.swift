import AppKit
import SwiftUI

struct HermesSetupPane: View {
    @Binding var executablePath: String
    @Binding var profilePath: String
    @Binding var runtimePath: String
    @Binding var isWorking: Bool
    var onReady: (Bool) -> Void = { _ in }
    @StateObject private var setup = HermesSetupController()
    @StateObject private var subscription = HermesSubscriptionLoginController()
    @State private var provider = "openai-codex"
    @State private var model = ""
    @State private var apiKey = ""
    @State private var profileStatus: String?
    @State private var advanced = false
    @State private var showsSkills = false
    @State private var setupTask: Task<Void, Never>?

    private var configuration: HermesEngineConfiguration {
        .init(executablePath: executablePath, profilePath: profilePath, runtimePath: runtimePath)
    }
    private var setupBusy: Bool { setup.busy || subscription.busy }
    private var availableModels: [String] { setup.providers.first(where: { $0.id == provider })?.models ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Text("One Hermes engine runs every mate. Your voice, characters, and chats stay in HeyMate.")
                .font(DS.Fonts.caption).foregroundColor(DS.Colors.textSecondary)
            HStack {
                Button(setup.busy ? "Checking…" : "Check connection") {
                    setupTask = Task {
                        await setup.check(configuration)
                        if ["openai-codex", "openai", "anthropic"].contains(setup.currentProvider) {
                            provider = setup.currentProvider; model = setup.currentModel
                        }
                    }
                }
                .disabled(setupBusy)
                Button("Create private profile") { createProfile() }.disabled(setupBusy)
            }.dsCapsuleButtonStyle(.secondary)
            if let profileStatus { Text(profileStatus).font(DS.Fonts.caption) }
            if let status = setup.status { Text(status).font(DS.Fonts.caption).textSelection(.enabled) }
            if let warning = setup.confirmationMessage {
                Text(warning).font(DS.Fonts.caption).textSelection(.enabled)
                HStack {
                    Button("Confirm model selection") { setupTask = Task { await setup.confirmModel() } }
                    Button("Cancel model change") { setup.cancelConfirmation() }
                }.disabled(setupBusy)
            }

            Button("Browse and review skills") { showsSkills = true }.disabled(setupBusy)
                .dsCapsuleButtonStyle(.secondary)

            if !setup.currentProvider.isEmpty {
                Text("Current profile: \(setup.providers.first(where: { $0.id == setup.currentProvider })?.name ?? setup.currentProvider) · \(setup.currentModel)")
                    .font(DS.Fonts.caption).foregroundColor(DS.Colors.textSecondary)
            }
            Text("Model access").font(DS.Fonts.caption).fontWeight(.semibold)
            Picker("Provider", selection: $provider) {
                Text("ChatGPT / Codex subscription").tag("openai-codex")
                Text("OpenAI API key").tag("openai")
                Text("Anthropic API key").tag("anthropic")
            }
            .disabled(setupBusy)
            if !availableModels.isEmpty {
                Picker("Available models", selection: $model) {
                    Text("Choose a model").tag("")
                    ForEach(availableModels, id: \.self) { Text($0).tag($0) }
                }
                .disabled(setupBusy)
            }
            TextField("Model name", text: $model).textFieldStyle(.roundedBorder).disabled(setupBusy)
            if provider == "openai-codex" {
                if setup.providers.first(where: { $0.id == "openai-codex" })?.authenticated == true {
                    Text("ChatGPT credentials are saved in this private profile.")
                        .font(DS.Fonts.caption).foregroundColor(DS.Colors.textSecondary)
                }
                Text("Sign in with your ChatGPT account through OpenAI’s device-code page. Subscription access is separate from OpenAI API-key billing.")
                    .font(DS.Fonts.caption).foregroundColor(DS.Colors.textSecondary)
                Button(subscription.busy ? "Waiting for OpenAI…" : "Sign in with ChatGPT") {
                    setupTask = Task { await subscription.start(configuration) }
                }.disabled(setupBusy).dsCapsuleButtonStyle(.secondary)
                if let code = subscription.userCode {
                    HStack {
                        Text(code).font(.system(.title3, design: .monospaced)).textSelection(.enabled)
                        Button("Copy code") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(code, forType: .string) }
                    }
                    if let url = subscription.verificationURL {
                        Button("Open OpenAI sign-in") { NSWorkspace.shared.open(url) }
                            .dsCapsuleButtonStyle(.secondary)
                    }
                }
                if subscription.busy {
                    Button("Cancel sign-in") { Task { await subscription.cancel() } }
                        .dsCapsuleButtonStyle(.secondary)
                }
                if !subscription.status.isEmpty { Text(subscription.status).font(DS.Fonts.caption).textSelection(.enabled) }
                Link("Device-code authorization help", destination: URL(string: "https://learn.chatgpt.com/docs/auth")!)
                    .font(DS.Fonts.caption)
                Text("Device-code sign-in may need enabling in ChatGPT security settings or permission from your workspace. Available models and account limits are determined by OpenAI. Signing in does not change your profile’s selected provider or model.")
                    .font(DS.Fonts.caption).foregroundColor(DS.Colors.textSecondary)
            } else {
                SecureField("API key — leave blank to keep saved key", text: $apiKey).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Hermes provider API key")
                Text("Keys are saved by Hermes in this private profile. API usage is billed by your provider.")
                    .font(DS.Fonts.caption).foregroundColor(DS.Colors.textSecondary)
            }
            Button("Save model access") {
                let key = apiKey
                apiKey = ""
                setupTask = Task { await setup.connect(configuration, provider: provider, model: model, key: key) }
            }
            .dsCapsuleButtonStyle(.secondary)
            .disabled(setupBusy || model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            DisclosureGroup("Runtime and privacy", isExpanded: $advanced) {
                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    HStack {
                        TextField("Hermes executable — blank uses bundled runtime or PATH", text: $executablePath)
                        Button("Choose…") { chooseFile(directory: false) { executablePath = $0.path } }
                    }
                    HStack {
                        TextField("Private Hermes profile folder", text: $profilePath)
                        Button("Choose…") { chooseFile(directory: true) { profilePath = $0.path } }
                    }
                    TextField("Runtime tools folder — optional for external installs", text: $runtimePath)
                    Text("Use a separate profile, outside ~/.hermes. Existing native history is not imported. Mates currently share this profile’s memory and skills; each chat has its own conversation and workspace.")
                    Text("Hermes can use local tools without an OS sandbox. HeyMate shows the approval requests Hermes sends; this is not approval for every shell command. HeyMate must stay open while Hermes works; its owned backend is stopped on quit.")
                }.textFieldStyle(.roundedBorder).font(DS.Fonts.caption)
            }
            .disabled(setupBusy)
        }
        .onChange(of: setupBusy) {
            isWorking = setupBusy
            if subscription.busy { onReady(false) }
        }
        .onChange(of: setup.ready) { onReady(setup.ready) }
        .onChange(of: provider) { apiKey = ""; setup.cancelConfirmation() }
        .onChange(of: model) { setup.cancelConfirmation() }
        .onChange(of: executablePath) { setup.resetStatus(); subscription.resetStatus() }
        .onChange(of: profilePath) { setup.resetStatus(); subscription.resetStatus() }
        .onChange(of: runtimePath) { setup.resetStatus(); subscription.resetStatus() }
        .task {
            if FileManager.default.fileExists(atPath: configuration.profilePath) {
                await setup.check(configuration)
                if ["openai-codex", "openai", "anthropic"].contains(setup.currentProvider) {
                    provider = setup.currentProvider; model = setup.currentModel
                }
            }
        }
        .onChange(of: subscription.state) {
            if subscription.state == .connected {
                setupTask = Task {
                    await setup.check(configuration)
                    provider = "openai-codex"; model = ""
                }
            }
        }
        .onDisappear {
            // Do not abort a start response before its flow ID can be cancelled.
            if !subscription.busy { setupTask?.cancel() }
            Task { await subscription.cancel() }
            apiKey = ""; isWorking = false
        }
        .sheet(isPresented: $showsSkills) { HermesSkillsPane(configuration: configuration) }
    }

    private func createProfile() {
        do {
            try HermesSetupController.createProfile(at: URL(fileURLWithPath: profilePath, isDirectory: true))
            profileStatus = "Private profile created. Add model access, then check the connection."
        } catch HermesSetupController.SetupFailure.existingProfile {
            profileStatus = "This profile already exists. Its files and credentials were preserved."
        } catch {
            profileStatus = "Could not create this profile. Choose a new absolute folder outside ~/.hermes."
        }
    }

    private func chooseFile(directory: Bool, selected: (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = directory
        panel.canChooseFiles = !directory
        panel.allowsMultipleSelection = false
        panel.message = directory ? "Choose an isolated Hermes profile." : "Choose the direct official Hermes launcher."
        if panel.runModal() == .OK, let url = panel.url { selected(url) }
    }
}
