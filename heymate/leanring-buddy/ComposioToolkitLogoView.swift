//
//  ComposioToolkitLogoView.swift
//  leanring-buddy
//
//  Composio serves toolkit artwork as SVG. SwiftUI's AsyncImage does not
//  reliably turn those responses into an Image on macOS, while NSImage does.
//  This small loader keeps vendor artwork dynamic instead of bundling a logo
//  catalog that would immediately drift from Composio's directory.
//

import AppKit
import SwiftUI

struct ComposioToolkitLogoView: View {
    let toolkit: ComposioToolkit
    var isConnected = false
    /// Compact mode is for the notch suggestion card: flat white tile so
    /// dark brand marks (GitHub, Notion) stay legible on the matte surface.
    var compactSize: CGFloat?

    @State private var logoImage: NSImage?
    @State private var hasFinishedLoading = false

    var body: some View {
        if let compactSize {
            compactBody(size: compactSize)
        } else {
            fullBody
        }
    }

    private func compactBody(size: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
            .fill(Color.white)
            .frame(width: size, height: size)
            .overlay {
                if let logoImage {
                    Image(nsImage: logoImage)
                        .resizable()
                        .scaledToFit()
                        .padding(size * 0.2)
                } else if hasFinishedLoading {
                    Text(toolkit.logoMonogram)
                        .font(DS.Fonts.title)
                        .foregroundStyle(Color.black)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                    .stroke(DS.Colors.borderStrong.opacity(0.6), lineWidth: 0.5)
            }
            .task(id: toolkit.slug) {
                await loadLogo()
            }
            .accessibilityHidden(true)
    }

    private var fullBody: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [toolkit.visualAccent.opacity(0.24), DS.Colors.surface3],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Circle()
                .fill(toolkit.visualAccent.opacity(0.18))
                .frame(width: 32, height: 32)
                .blur(radius: 7)

            if let logoImage {
                Image(nsImage: logoImage)
                    .resizable()
                    .scaledToFit()
                    .padding(9)
            } else if hasFinishedLoading {
                Text(toolkit.logoMonogram)
                    .font(DS.Fonts.title)
                    .foregroundStyle(DS.Colors.textPrimary)
            } else {
                ProgressView()
                    .controlSize(.mini)
                    .tint(toolkit.visualAccent)
            }
        }
        .frame(width: 50, height: 50)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(toolkit.visualAccent.opacity(0.34), lineWidth: 1)
        )
        .shadow(color: toolkit.visualAccent.opacity(0.18), radius: 8, y: 3)
        .overlay(alignment: .bottomTrailing) {
            if isConnected {
                Circle()
                    .fill(DS.Colors.success)
                    .frame(width: 11, height: 11)
                    .overlay(Circle().stroke(DS.Colors.surface1, lineWidth: 2))
                    .offset(x: 2, y: 2)
            }
        }
        .task(id: toolkit.slug) {
            await loadLogo()
        }
        .accessibilityHidden(true)
    }

    private func loadLogo() async {
        logoImage = nil
        hasFinishedLoading = false

        for url in toolkit.logoCandidates {
            guard !Task.isCancelled else { return }
            var request = URLRequest(url: url)
            request.cachePolicy = .returnCacheDataElseLoad
            request.timeoutInterval = 12

            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode),
                  let image = NSImage(data: data) else { continue }

            logoImage = image
            hasFinishedLoading = true
            return
        }

        hasFinishedLoading = true
    }
}

extension ComposioToolkit {
    var visualAccent: Color {
        let palette: [Color] = [
            Color(hex: "#60A5FA"),
            Color(hex: "#A78BFA"),
            Color(hex: "#F472B6"),
            Color(hex: "#22D3EE"),
            Color(hex: "#FBBF24"),
            Color(hex: "#34D399")
        ]
        let stableIndex = slug.utf8.reduce(UInt64(0)) { partial, byte in
            (partial &* 31) &+ UInt64(byte)
        }
        return palette[Int(stableIndex % UInt64(palette.count))]
    }

    fileprivate var logoMonogram: String {
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let letters = words.prefix(2).compactMap(\.first)
        return letters.isEmpty ? "•" : String(letters).uppercased()
    }
}
