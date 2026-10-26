import SwiftUI

struct MateAgentSkillsPane: View {
    let configuration: MateAgentEngineConfiguration
    @Environment(\.dismiss) private var dismiss
    @State private var skills: [Skill] = []
    @State private var pending: [PendingSkill] = []
    @State private var selectedPending: String?
    @State private var content = ""
    @State private var status = ""
    @State private var busy = false
    @State private var showsApplyConfirmation = false

    private struct Skill: Identifiable {
        var id: String { name }
        let name: String
        let description: String
        let enabled: Bool
    }
    private struct PendingSkill: Identifiable {
        let id: String
        let summary: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("HeyMate Agent skills").font(.title2.bold())
                Spacer()
                Button("Refresh") { Task { await load() } }.disabled(busy)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Skills provide instructions and workflows. They may need installed tools or account access. Profile memory and skills are shared by this user’s mates.")
                .font(.caption).foregroundStyle(.secondary)
            HSplitView {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(skills) { skill in
                            VStack(alignment: .leading) {
                                Toggle(skill.name, isOn: Binding(get: { skill.enabled }, set: { enabled in
                                    Task { await toggle(skill.name, enabled: enabled) }
                                })).disabled(busy)
                                Text(skill.description).font(.caption).foregroundStyle(.secondary)
                                Button("Read instructions") { Task { await read(skill.name) } }.disabled(busy)
                            }
                        }
                        Divider()
                        Text("Learned changes awaiting review").font(.headline)
                        if pending.isEmpty { Text("No pending skill changes.").font(.caption) }
                        ForEach(pending) { change in
                            Button(change.summary.isEmpty ? change.id : change.summary) {
                                selectedPending = change.id
                                Task { await review(change.id) }
                            }.buttonStyle(.link).disabled(busy)
                        }
                    }.padding(8)
                }.frame(minWidth: 230)
                VStack(alignment: .leading) {
                    ScrollView { Text(content.isEmpty ? "Choose a skill or pending change." : content)
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8) }
                    if let selectedPending {
                        HStack {
                            Button("Approve reviewed change") { showsApplyConfirmation = true }.disabled(busy || content.isEmpty)
                            Button("Reject change") { Task { await apply(selectedPending, approve: false) } }.disabled(busy)
                        }
                    }
                }.frame(minWidth: 330)
            }
            Text(status).font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(width: 820, height: 570)
        .task { await load() }
        .confirmationDialog("Apply this reviewed skill change?", isPresented: $showsApplyConfirmation, titleVisibility: .visible) {
            Button("Apply change") { if let selectedPending { Task { await apply(selectedPending, approve: true) } } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The displayed change may create, edit, or delete skill files in your HeyMate agent profile.") }
    }

    private func prepare() async throws -> MateAgentServeBackend {
        let backend = MateAgentServeBackend.shared
        _ = try await backend.start(configuration: configuration.resolveLaunchConfiguration())
        return backend
    }
    private func command(_ arg: String, backend: MateAgentServeBackend) async throws -> String {
        let socket = try backend.openWebSocket()
        defer { socket.close() }
        let value = try await socket.request(method: "command.dispatch", params: .object(["name": .string("skills"), "arg": .string(arg)]))
        guard case .object(let fields) = value, case .string(let output) = fields["output"], output.utf8.count <= 1_024 * 1_024 else {
            throw MateAgentSetupController.SetupFailure.invalidResponse
        }
        return output
    }
    private func load() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            let backend = try await prepare()
            let value = try await backend.requestHTTP(path: "/api/skills")
            guard case .array(let rows) = value, rows.count <= 2_000 else { throw MateAgentSetupController.SetupFailure.invalidResponse }
            skills = rows.compactMap { row in
                guard case .object(let fields) = row, case .string(let name) = fields["name"] else { return nil }
                let description: String
                if case .string(let text) = fields["description"] { description = String(text.prefix(2_000)) } else { description = "" }
                return Skill(name: name, description: description, enabled: fields["enabled"] != .bool(false))
            }.sorted { $0.name < $1.name }
            let output = try await command("pending", backend: backend)
            pending = output.split(separator: "\n").compactMap { line in
                let words = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
                guard let id = words.first, id.range(of: "^[a-f0-9]{8}$", options: .regularExpression) != nil else { return nil }
                return PendingSkill(id: String(id), summary: words.count > 1 ? String(words[1]) : "")
            }
            status = "\(skills.count) skills. Only enabled skills enter the harness. File changes require approval."
        } catch { status = "Could not load skills from this HeyMate agent profile. Check the connection first." }
    }
    private func toggle(_ name: String, enabled: Bool) async {
        guard !busy else { return }
        busy = true
        do {
            let backend = try await prepare()
            _ = try await backend.requestHTTP(path: "/api/skills/toggle", method: "PUT", body: .object([
                "name": .string(name), "enabled": .bool(enabled)
            ]))
        } catch { status = "Could not change this skill. Existing state was preserved." }
        busy = false
        await load()
    }
    private func read(_ name: String) async {
        guard !busy else { return }
        busy = true; selectedPending = nil; content = ""
        defer { busy = false }
        do {
            let backend = try await prepare()
            let value = try await backend.requestHTTP(path: "/api/skills/content", queryItems: [URLQueryItem(name: "name", value: name)])
            if case .object(let fields) = value, case .string(let text) = fields["content"] { content = text }
            else { throw MateAgentSetupController.SetupFailure.invalidResponse }
        } catch { status = "Could not read this skill." }
    }
    private func review(_ id: String) async {
        guard !busy else { return }
        busy = true; content = ""; defer { busy = false }
        do { content = try await command("diff " + id, backend: prepare()) }
        catch { status = "Could not load this pending change." }
    }
    private func apply(_ id: String, approve: Bool) async {
        guard !busy, id.range(of: "^[a-f0-9]{8}$", options: .regularExpression) != nil else { return }
        busy = true
        do {
            status = try await command((approve ? "approve " : "reject ") + id, backend: prepare())
            selectedPending = nil; content = ""
        } catch { status = "Could not apply this review decision." }
        busy = false
        await load()
    }
}
