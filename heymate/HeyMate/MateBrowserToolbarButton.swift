import SwiftUI

struct MateBrowserToolbarButton: View {
    let mateID: UUID
    @ObservedObject private var browsers = IsolatedBrowserWorkers.shared
    @State private var error: String?

    var body: some View {
        if browsers.isPersistent(mateID) {
            Button {
                if browsers.control(for: mateID) == .person {
                    browsers.handBack(for: mateID)
                } else {
                    Task { error = await browsers.takeOver(for: mateID) }
                }
            } label: {
                if browsers.control(for: mateID) == .takingOver {
                    ProgressView().controlSize(.mini)
                } else {
                    Label(
                        browsers.control(for: mateID) == .person ? "Hand back" : "Take over",
                        systemImage: browsers.control(for: mateID) == .person ? "arrow.uturn.backward" : "globe"
                    )
                }
            }
            .dsCapsuleButtonStyle(.secondary, height: DS.ControlSize.small)
            .disabled(browsers.control(for: mateID) == .takingOver)
            .help(label)
            .accessibilityLabel(label)
            .alert("Mate browser", isPresented: Binding(
                get: { error != nil },
                set: { if !$0 { error = nil } }
            )) {
                Button("OK") { error = nil }
            } message: {
                Text(error ?? "")
            }
        }
    }

    private var label: String {
        switch browsers.control(for: mateID) {
        case .mate: "Take over Mate browser"
        case .takingOver: "Waiting for Mate browser"
        case .person: "Hand back Mate browser"
        }
    }
}
