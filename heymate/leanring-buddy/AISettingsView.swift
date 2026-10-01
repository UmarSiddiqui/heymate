//
//  AISettingsView.swift
//  leanring-buddy
//
//  Brain/provider settings as one column: Look, Brain, Audio, Google. The
//  notch presentation owns its scroll view and Look controls; the desktop
//  presentation drops both so it can sit inside a parent page.
//
//  The controls themselves live in AISettingsComponents.swift. The desktop
//  Settings window no longer embeds this view — its Accounts and Advanced
//  tabs place the same components separately — so this file is the notch's
//  layout of them.
//

import SwiftUI

struct AISettingsView: View {
    enum Presentation {
        case notch
        case desktop
    }

    @ObservedObject var companionManager: CompanionManager
    var presentation: Presentation = .notch

    var body: some View {
        Group {
            if presentation == .notch {
                ScrollView(.vertical, showsIndicators: true) {
                    settingsSections
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 8)
                }
                .scrollIndicators(.visible)
            } else {
                settingsSections
            }
        }
        .task {
            await AISettingsRefresh.refreshCatalogsAndReadiness(companionManager)
        }
    }

    @ViewBuilder
    private var settingsSections: some View {
        VStack(alignment: .leading, spacing: 18) {
            if presentation == .notch {
                lookSection
            }
            brainSection
            audioSection
            googleSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Look

    private var lookSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            NotchSettingsSectionHeader(title: "Look")
            AISettingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    AISettingsLabel("Color")
                    ThemeColorPicker(companionManager: companionManager)
                    AISettingsFootnote("Notch stays pitch black; accent applies to cursor and actions.")
                }
            }
        }
    }

    // MARK: - Brain

    private var brainSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            NotchSettingsSectionHeader(title: "Brain")
            AISettingsCard {
                CLIUpdateSettingsContent(companionManager: companionManager)
            }

            BrainChoiceGrid(companionManager: companionManager)

            Text(companionManager.selectedBrain.subtitle)
                .font(DS.Fonts.caption)
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let reason = companionManager.selectedBrain.unavailableReason {
                Text(reason)
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.warningText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            brainDetail

            AISettingsCard {
                AgentSignInSettingsContent(companionManager: companionManager)
            }
        }
    }

    @ViewBuilder
    private var brainDetail: some View {
        switch companionManager.selectedBrain {
        case .openCode:
            VStack(alignment: .leading, spacing: 10) {
                AISettingsCard {
                    OpenCodeModelsSettingsContent(companionManager: companionManager)
                }
                AISettingsCard {
                    OpenCodeServerSettingsContent(companionManager: companionManager)
                }
            }
        case .claudeCode:
            AISettingsCard {
                ClaudeModelSettingsContent(companionManager: companionManager)
            }
            AISettingsCard {
                VoiceChatSettingsContent(companionManager: companionManager)
            }
        case .codex:
            AISettingsCard {
                CodexModelSettingsContent(companionManager: companionManager)
            }
            AISettingsCard {
                VoiceChatSettingsContent(companionManager: companionManager)
            }
        case .customAPI:
            AISettingsCard {
                CustomAPISettingsContent(companionManager: companionManager)
            }
        case .onDevice:
            AISettingsCard {
                OnDeviceBrainSettingsContent(companionManager: companionManager)
            }
        }
    }

    // MARK: - Audio

    private var audioSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            NotchSettingsSectionHeader(title: "Audio")
            AISettingsCard {
                VoiceProviderSettingsContent(
                    companionManager: companionManager,
                    showsInteractionSoundsToggle: presentation == .notch
                )
            }
        }
    }

    // MARK: - Google

    private var googleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            NotchSettingsSectionHeader(title: "Google")
            AISettingsCard {
                GoogleCLISettingsContent()
            }
        }
    }
}

private struct NotchSettingsSectionHeader: View {
    let title: String

    var body: some View {
        DSSectionLabel(title: title)
    }
}
