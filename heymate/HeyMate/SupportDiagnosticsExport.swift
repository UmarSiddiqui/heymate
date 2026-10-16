import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// An allowlist, not a dump of logs/preferences. No prompts, tokens, paths,
/// account identifiers, screenshots, command lines, or result prose.
@MainActor
struct SupportDiagnosticsExport: View {
    @ObservedObject var manager: CompanionManager
    @State private var reviewing = false
    @State private var report = ""
    @State private var error: String?

    var body: some View {
        Button("Export diagnostics…") {
            report = makeReport()
            reviewing = true
        }
        .sheet(isPresented: $reviewing) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Review support diagnostics").font(.title2)
                Text("Only the text below will be saved. Share it yourself if needed.")
                ScrollView { Text(report).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                if let error { Text(error).foregroundStyle(.red) }
                HStack {
                    Button("Cancel") { reviewing = false }
                    Spacer()
                    Button("Save file…") { save() }.buttonStyle(.borderedProminent)
                }
            }.padding(24).frame(width: 600, height: 460)
        }
    }

    private func makeReport() -> String {
        let counts = Dictionary(grouping: manager.agentRuns, by: \.status.rawValue)
            .map { "\($0.key): \($0.value.count)" }.sorted().joined(separator: "\n")
        let quiet = manager.agentRuns.filter { !AgentProgressHealth.summary(for: $0).isEmpty }.count
        return """
        \(SupportLinks.diagnosticsSummary)
        Diagnostic schema: 1
        Generated: \(ISO8601DateFormatter().string(from: Date()))
        Tasks by status:
        \(counts.isEmpty ? "No tasks" : counts)
        Tasks without recent tool progress: \(quiet)
        Enabled integrations: \(manager.connectorStore.records.values.filter(\.isEnabled).count)
        Discovered skills: \(manager.discoveredSkills.count)
        Active skills: \(manager.loadedSkills.count)
        Note: heartbeats indicate runner liveness, not meaningful work.
        """
    }

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "HeyMate-diagnostics.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try report.write(to: url, atomically: true, encoding: .utf8)
            reviewing = false
            error = nil
        } catch { self.error = "Could not save diagnostics. Choose another location." }
    }
}
