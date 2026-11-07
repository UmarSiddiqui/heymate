import Foundation

/// HeyMate projects structured elements and also reads non-actionable text
/// from Markdown. Cua 0.38 defaults to Markdown only; 0.34 has no format option.
public struct CuaDriverWindowReadContract: Sendable {
    private let supportsBoth: Bool

    public init(inputSchema: [String: Any]) {
        let properties = inputSchema["properties"] as? [String: Any]
        let format = properties?["tree_format"] as? [String: Any]
        supportsBoth = (format?["enum"] as? [String])?.contains("both") == true
    }

    public func arguments(_ original: [String: Any]) -> [String: Any] {
        var result = original
        if supportsBoth, original["include_accessibility_tree"] as? Bool != false {
            result["tree_format"] = "both"
        }
        return result
    }
}
