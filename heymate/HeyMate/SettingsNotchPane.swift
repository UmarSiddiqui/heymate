import SwiftUI

struct SettingsNotchPane: View {
    @ObservedObject var activityCenter: NotchActivityCenter
    @ObservedObject var navigation: SettingsNavigationModel
    @ObservedObject private var usage = NotchUsageStore.shared
    @AppStorage(NotchCompanionController.hoverOpensCardPreferenceKey) private var hoverOpensCard = true

    var body: some View {
        SettingsPage(tab: .notch, navigation: navigation) {
            SettingsSection("Coding usage", footer: "Read usage limits from the accounts already signed in on this Mac. Credentials are read locally and sent only to their provider, never to HeyMate analytics. Refreshes every two minutes; unavailable readings stay clearly marked.") {
                ForEach(NotchUsageProvider.allCases) { provider in
                    SettingsToggleRow(provider.name, subtitle: usage.status[provider] ?? "Usage ring and reset times", isOn: Binding(
                        get: { usage.enabled.contains(provider) }, set: { usage.setEnabled($0, provider: provider) }
                    ))
                }
            }.settingsAnchor(.microApps)
            SettingsSection("Behavior", footer: "Clicking the notch always opens the card.") {
                SettingsToggleRow(SettingsItem.hoverOpensCard.title, subtitle: "Hover to see usage limits and agent activity.", item: .hoverOpensCard, isOn: $hoverOpensCard)
            }
            SettingsSection("Feed your mate", footer: "The shelf opens only when you drag a file onto the notch. The mate opens its mouth, then keeps the file ready to drag back out. Original files stay where they are; shelf bookmarks expire after one day.") {
                SettingsRow("File shelf", subtitle: "Drag a file to the notch to open your shelf.", systemImage: "arrow.down.doc") { EmptyView() }
            }.settingsAnchor(.notchContent)
        }
    }
}
