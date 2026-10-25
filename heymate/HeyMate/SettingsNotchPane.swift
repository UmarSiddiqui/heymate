import SwiftUI

struct SettingsNotchPane: View {
    @ObservedObject var activityCenter: NotchActivityCenter
    @ObservedObject var navigation: SettingsNavigationModel
    @ObservedObject private var usage = NotchUsageStore.shared
    @AppStorage(NotchCompanionController.hoverOpensCardPreferenceKey) private var hoverOpensCard = true

    var body: some View {
        SettingsPage(tab: .notch, navigation: navigation) {
            SettingsSection("Coding usage", footer: "Read usage limits from the accounts already signed in on this Mac. Credentials are read locally and sent only to their provider, never to HeyMate analytics. Refreshes every two minutes; unavailable readings stay clearly marked.") {
                ForEach(usage.providers) { provider in
                    SettingsToggleRow(provider.name, subtitle: usage.status[provider] ?? (provider.isBuiltIn ? "Usage ring and reset times" : provider.spec?.url ?? ""), isOn: Binding(
                        get: { usage.enabled.contains(provider) }, set: { usage.setEnabled($0, provider: provider) }
                    ))
                    if !provider.isBuiltIn {
                        SettingsRow("Remove \(provider.name)", subtitle: "Deletes its saved token from the Keychain.") {
                            Button("Remove") { usage.removeCustom(id: provider.rawValue) }.dsCapsuleButtonStyle(.quiet)
                        }
                    }
                }
            }.settingsAnchor(.microApps)
            SettingsSection("Add your own source", footer: "Connect anything with a JSON usage endpoint, such as a proxy, gateway or another tool. Use a dot path to the number, like data.usage.percent, or a used and limit pair. The token goes to the Keychain and is sent only to that address. HTTPS only, except localhost.") {
                NotchCustomSourceForm(usage: usage)
            }
            SettingsSection("Behavior", footer: "Clicking the notch always opens the card.") {
                SettingsToggleRow(SettingsItem.hoverOpensCard.title, subtitle: "Hover to see usage limits and agent activity.", item: .hoverOpensCard, isOn: $hoverOpensCard)
            }
            SettingsSection("Feed your mate", footer: "The shelf opens only when you drag a file onto the notch. The mate opens its mouth, then keeps the file ready to drag back out. Original files stay where they are; shelf bookmarks expire after one day.") {
                SettingsRow("File shelf", subtitle: "Drag a file to the notch to open your shelf.", systemImage: "arrow.down.doc") { EmptyView() }
            }.settingsAnchor(.notchContent)
        }
    }
}

private struct NotchCustomSourceForm: View {
    @ObservedObject var usage: NotchUsageStore
    @State private var name = ""
    @State private var url = ""
    @State private var token = ""
    @State private var headerName = "Authorization"
    @State private var glyph = "generic"
    @State private var percentPath = ""
    @State private var usedPath = ""
    @State private var limitPath = ""
    @State private var resetPath = ""

    private var spec: NotchCustomProviderSpec {
        NotchCustomProviderSpec(id: "custom.\(UUID().uuidString.prefix(8).lowercased())", name: name, url: url, glyph: glyph,
                                headerName: headerName, percentPath: percentPath, usedPath: usedPath,
                                limitPath: limitPath, resetPath: resetPath)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            field("Name", "My gateway", $name)
            field("Usage URL", "https://example.com/api/usage", $url)
            SecureField("Token (optional)", text: $token).textFieldStyle(.roundedBorder)
            field("Auth header", "Authorization", $headerName)
            field("Percent used path", "data.usage.percent", $percentPath)
            HStack {
                field("Or used path", "data.used", $usedPath)
                field("Limit path", "data.limit", $limitPath)
            }
            field("Reset time path (optional)", "data.resets_at", $resetPath)
            HStack {
                Picker("Logo", selection: $glyph) {
                    ForEach(NotchGlyphOutline.choices, id: \.key) { Text($0.name).tag($0.key) }
                }.frame(maxWidth: 220)
                Spacer()
                Button("Add source") {
                    usage.addCustom(spec, token: token)
                    name = ""; url = ""; token = ""; percentPath = ""; usedPath = ""; limitPath = ""; resetPath = ""; glyph = "generic"
                }
                .dsCapsuleButtonStyle(.secondary).disabled(!spec.isValid)
            }
        }
        .settingsRowInsets()
    }

    private func field(_ title: String, _ prompt: String, _ text: Binding<String>) -> some View {
        TextField(title, text: text, prompt: Text(prompt)).textFieldStyle(.roundedBorder).autocorrectionDisabled()
    }
}
