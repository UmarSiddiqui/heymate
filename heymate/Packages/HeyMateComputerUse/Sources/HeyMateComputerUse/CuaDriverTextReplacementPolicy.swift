import Foundation

public enum CuaDriverTextReplacementPolicy {
    /// Only complete, window-rooted native text fields use AXValue replacement.
    /// A web-area ancestor, missing ancestry, or partial tree is not sufficient
    /// evidence: AXValue can change a web field without notifying its app.
    public static func nativeTextTokens(in state: [String: Any]) -> Set<String> {
        guard state["elements_complete"] as? Bool == true,
              state["truncated"] as? Bool != true,
              let elements = state["elements"] as? [[String: Any]] else { return [] }
        var indexed: [Int: [String: Any]] = [:]
        for element in elements {
            guard let index = element["element_index"] as? Int, indexed[index] == nil else { return [] }
            indexed[index] = element
        }
        let nativeContainers: Set<String> = ["AXGroup", "AXSplitGroup", "AXScrollArea", "AXTabGroup", "AXToolbar"]
        return Set(elements.compactMap { element -> String? in
            guard element["role"] as? String == "AXTextField",
                  element["subrole"] as? String != "AXSecureTextField",
                  let token = element["element_token"] as? String,
                  let index = element["element_index"] as? Int else { return nil }
            var current = element
            var visited: Set<Int> = [index]
            while let parent = current["parent_index"] as? Int {
                guard visited.insert(parent).inserted, let ancestor = indexed[parent],
                      let role = ancestor["role"] as? String else { return nil }
                if role == "AXWindow", ancestor["depth"] as? Int == 0 {
                    return token
                }
                guard nativeContainers.contains(role) else { return nil }
                current = ancestor
            }
            return nil
        })
    }

    public static func confirmsReplacement(_ result: [String: Any]) -> Bool {
        result["effect"] as? String == "confirmed"
            && (result["evidence"] as? [[String: Any]])?.contains(where: {
                $0["kind"] as? String == "value_readback"
            }) == true
    }
}
