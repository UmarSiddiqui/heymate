import SwiftUI

struct SettingsNotchPane: View {
    @ObservedObject var activityCenter: NotchActivityCenter
    @ObservedObject var navigation: SettingsNavigationModel
    @ObservedObject private var usage = NotchUsageStore.shared
    @AppStorage(NotchCompanionController.hoverOpensCardPreferenceKey) private var hoverOpensCard = true

    var body: some View {
        SettingsPage(tab: .notch, navigation: navigation) {
            SettingsSection("Usage display") {
                SettingsToggleRow("Always show idle usage rings", isOn: $usage.showsIdleUsage)
                SettingsToggleRow("Show remaining", subtitle: "Warning colors still reflect usage.", isOn: $usage.showsRemaining)
                SettingsToggleRow("Weekly ring", isOn: $usage.showsWeeklyRing)
                SettingsToggleRow("Reduce usage motion", isOn: $usage.reducesMotion)
                SettingsRow("Provider order") {
                    Picker("Provider order", selection: $usage.ringOrder) {
                        ForEach(NotchRingOrder.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.labelsHidden().frame(width: 180)
                }
            }
            SettingsSection("Coding usage", footer: "Read from accounts signed in on this Mac. Credentials go only to their provider.") {
                ForEach(usage.providers) { provider in
                    SettingsToggleRow(provider.name, subtitle: usage.status[provider] ?? (provider.connectionDetail), isOn: Binding(
                        get: { usage.enabled.contains(provider) }, set: { usage.setEnabled($0, provider: provider) }
                    ))
                    if usage.enabled.contains(provider) {
                        SettingsRow("\(provider.name) display") {
                            Toggle("Idle ring", isOn: Binding(get: { !usage.hiddenIdleProviders.contains(provider.rawValue) }, set: { usage.setIdleVisible($0, provider: provider) })).toggleStyle(.checkbox)
                            Button { usage.moveProvider(provider, offset: -1) } label: { Image(systemName: "chevron.up") }.help("Move \(provider.name) earlier")
                            Button { usage.moveProvider(provider, offset: 1) } label: { Image(systemName: "chevron.down") }.help("Move \(provider.name) later")
                        }
                    }
                    if !provider.isBuiltIn {
                        SettingsRow("Remove \(provider.name)", subtitle: "Deletes its saved token.") {
                            Button("Remove") { usage.removeCustom(id: provider.rawValue) }.dsCapsuleButtonStyle(.quiet)
                        }
                    }
                }
            }.settingsAnchor(.microApps)
            SettingsSection("Add your own source", footer: "Any JSON usage endpoint. Point at the number with a dot path like data.usage.percent, or a used and limit pair. HTTPS only, except localhost.") {
                NotchCustomSourceForm(usage: usage)
            }
            SettingsSection("Behavior") {
                SettingsToggleRow(SettingsItem.hoverOpensCard.title, item: .hoverOpensCard, isOn: $hoverOpensCard)
            }
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
