import SwiftUI

/// Color tokens shared by the Mac workspace and iPhone companion.
enum HeyMatePalette {
    static let defaultAccentHex = "3380FF"
    static let workspace = rgb(0x1E1E1E)
    static let rail = rgb(0x202020)
    static let surface = rgb(0x242424)
    static let field = rgb(0x303030)
    static let border = rgb(0x38383A)
    static let primary = rgb(0xF5F5F7)
    static let secondary = rgb(0xB3B3BA)
    static let tertiary = rgb(0x84848C)
    static let glassInk = rgb(0x183451)
    static let destructive = rgb(0xE5484D)
    static let destructiveText = rgb(0xFF6369)
    static let chatReply = Color.white.opacity(0.045)
    static let glassStops: [Gradient.Stop] = [
        .init(color: rgb(0xF0F7FF), location: 0),
        .init(color: rgb(0xCCDEFF), location: 0.27),
        .init(color: rgb(0xA8CBFA), location: 0.62),
        .init(color: rgb(0x76ACEB), location: 1)
    ]
    static let workspaceStops: [Gradient.Stop] = [
        .init(color: .black, location: 0),
        .init(color: rgb(0x141414), location: 0.22),
        .init(color: workspace, location: 0.62),
        .init(color: rgb(0x1A1A1A), location: 1)
    ]

    static func accent(_ hex: String?, towardWhite: Double = 0, towardBlack: Double = 0) -> Color {
        let hex = hex?.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = hex.flatMap { $0.count == 6 ? UInt32($0, radix: 16) : nil } ?? UInt32(defaultAccentHex, radix: 16) ?? 0
        return rgb(value, towardWhite: towardWhite, towardBlack: towardBlack)
    }

    private static func rgb(_ value: UInt32, towardWhite: Double = 0, towardBlack: Double = 0) -> Color {
        func component(_ shift: UInt32) -> Double {
            let channel = Double((value >> shift) & 255) / 255
            return (channel + (1 - channel) * towardWhite) * (1 - towardBlack)
        }
        return Color(.sRGB, red: component(16), green: component(8), blue: component(0))
    }
}
