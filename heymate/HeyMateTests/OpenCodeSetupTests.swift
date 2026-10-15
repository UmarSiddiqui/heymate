import Foundation
import Testing
@testable import HeyMate

@MainActor
struct OpenCodeSetupTests {
    @Test func freePricingRequiresBothExplicitZeroCosts() {
        #expect(OpenCodeClient.hasZeroCost(["cost": ["input": 0, "output": 0]]))
        #expect(!OpenCodeClient.hasZeroCost(["cost": ["input": 0, "output": 1]]))
        #expect(!OpenCodeClient.hasZeroCost(["cost": ["input": 1, "output": 0]]))
        #expect(!OpenCodeClient.hasZeroCost(["cost": ["input": 0]]))
        #expect(!OpenCodeClient.hasZeroCost(["name": "Free model"]))
        #expect(!OpenCodeClient.hasZeroCost(nil))
    }

    @Test func freeSetupNeverPicksAnUnpricedOrThirdPartyModel() {
        let free = OpenCodeModelOption(providerID: "opencode", providerName: "OpenCode", modelID: "free", modelName: "Free", isFree: true)
        let unknown = OpenCodeModelOption(providerID: "opencode", providerName: "OpenCode", modelID: "unknown", modelName: "Free")
        let thirdParty = OpenCodeModelOption(providerID: "other", providerName: "Other", modelID: "free", modelName: "Free", isFree: true)
        #expect([unknown, thirdParty, free].filter(\.isFreeWithoutSignIn) == [free])
    }

    @Test func managedServerOnlyUsesDefaultLoopbackAddress() {
        for address in ["http://127.0.0.1:4096", "http://localhost:4096/"] {
            #expect(OpenCodeLocalServer.supports(URL(string: address)!))
        }
        for address in ["https://example.com:4096", "http://192.168.1.1:4096", "http://127.0.0.1:8080", "http://127.0.0.1:4096/proxy", "http://localhost:4096?other=1"] {
            #expect(!OpenCodeLocalServer.supports(URL(string: address)!))
        }
    }

    @Test func installerLeavesShellProfilesAloneAndResolverFindsItsDirectory() {
        #expect(SubscriptionCLIInstaller.installShellCommand(for: .openCode)?.contains("--no-modify-path") == true)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(LoginShellExecutableResolver.loginPATH().split(separator: ":").contains(Substring("\(home)/.opencode/bin")))
    }
}
