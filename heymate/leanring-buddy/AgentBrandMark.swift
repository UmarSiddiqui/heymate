//
//  AgentBrandMark.swift
//  leanring-buddy
//
//  The real mark for each AI engine, so "Claude" and "ChatGPT" read at a
//  glance instead of as generic symbols. Claude and OpenCode marks are
//  bundled vectors from Simple Icons (CC0 path data; the marks belong to
//  their owners and only name the service you sign in to). OpenAI asks
//  that its mark not be redistributed that way, so ChatGPT uses the
//  ChatGPT app's own icon when the app is installed, and a symbol if not.
//

import AppKit
import SwiftUI

struct AgentBrandMark: View {
    let brain: AgentBrain
    var size: CGFloat = 16

    var body: some View {
        Group {
            switch brain {
            case .claudeCode:
                Image("BrandClaude")
                    .resizable()
                    .scaledToFit()
            case .openCode:
                Image("BrandOpenCode")
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.08)
            case .codex:
                if let icon = Self.chatGPTAppIcon {
                    // App icons carry their own margin; draw them a touch
                    // larger so the visible tile matches the other marks.
                    Image(nsImage: icon)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(1.2)
                } else {
                    symbol
                }
            case .onDevice, .customAPI:
                symbol
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var symbol: some View {
        Image(systemName: brain.settingsSymbolName)
            .font(.system(size: size * 0.8, weight: .medium))
    }

    /// Looked up once: the icon doesn't change while HeyMate runs, and
    /// LaunchServices lookups are not free on every redraw.
    private static let chatGPTAppIcon: NSImage? = {
        for bundleID in ["com.openai.chat", "com.openai.codex"] {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                return NSWorkspace.shared.icon(forFile: url.path)
            }
        }
        return nil
    }()
}
