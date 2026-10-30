import CoreGraphics
import Foundation
import Testing
@testable import HeyMate

private func element(_ token: Int, _ role: String, _ label: String, value: String? = nil) -> DriveElement {
    DriveElement(token: token, role: role, label: label, value: value,
                 frame: CGRect(x: 100, y: 100, width: 80, height: 24), isFocused: false)
}

private func snapshot(_ elements: [DriveElement], visible: [String] = []) -> DriveSnapshot {
    DriveSnapshot(applicationName: "Notes", processIdentifier: 1, windowTitle: "Notes",
                  elements: elements, visibleStrings: visible + elements.map(\.label))
}

struct DriveEngineTests {
    @Test func parsesEveryDocumentedAction() {
        #expect(DriveEngine.parseDecision(#"{"action":"press","element":3}"#) == .press(token: 3))
        #expect(DriveEngine.parseDecision(#"Sure. ```json {"action":"type","element":"[4]","text":"hi","submit":true} ```"#)
            == .type(token: 4, text: "hi", submit: true))
        #expect(DriveEngine.parseDecision(#"{"action":"key","keys":"cmd+n"}"#) == .key("cmd+n"))
        #expect(DriveEngine.parseDecision(#"{"action":"scroll","direction":"up"}"#) == .scroll(direction: "up"))
        #expect(DriveEngine.parseDecision(#"{"action":"open_app","app":"Notes"}"#) == .openApplication("Notes"))
        #expect(DriveEngine.parseDecision(#"{"action":"click","x":10,"y":20.5}"#) == .clickPoint(CGPoint(x: 10, y: 20.5)))
        #expect(DriveEngine.parseDecision(#"{"action":"done","summary":"Note made"}"#) == .done(summary: "Note made"))
        #expect(DriveEngine.parseDecision(#"{"action":"blocked","reason":"login"}"#) == .blocked(reason: "login"))
        #expect(DriveEngine.parseDecision(#"{"action":"wait"}"#) == .wait)
    }

    @Test func refusesWhatIsNotADocumentedAction() {
        #expect(DriveEngine.parseDecision("I'll press Save") == nil)
        #expect(DriveEngine.parseDecision(#"{"action":"rm -rf"}"#) == nil)
        #expect(DriveEngine.parseDecision(#"{"action":"press"}"#) == nil)
        #expect(DriveEngine.parseDecision(#"{"action":"scroll","direction":"sideways"}"#) == nil)
    }

    @Test func jsonInsideStringsDoesNotConfuseTheReader() {
        #expect(DriveEngine.parseDecision(#"{"action":"type","text":"a } b {","element":2}"#)
            == .type(token: 2, text: "a } b {", submit: false))
    }

    @Test func neverPressIsEnforcedInCodeOnWholeWords() {
        let window = snapshot([element(1, "AXButton", "Send Now"), element(2, "AXButton", "Resend code"),
                               element(3, "AXButton", "Archive"), element(4, "AXButton", "Sender")])
        let request = DriveRequest(goal: "x", neverPress: ["Archive"])
        #expect(DriveEngine.vet(.press(token: 1), snapshot: window, request: request, hasScreenshot: false)
            == .refusedControl(label: "Send Now"))
        #expect(DriveEngine.vet(.press(token: 3), snapshot: window, request: request, hasScreenshot: false)
            == .refusedControl(label: "Archive"))
        #expect(DriveEngine.vet(.press(token: 2), snapshot: window, request: request, hasScreenshot: false) == nil)
        #expect(DriveEngine.vet(.press(token: 4), snapshot: window, request: request, hasScreenshot: false) == nil)
    }

    @Test func vetCatchesMadeUpTokensCredentialsAndBlindClicks() {
        let window = snapshot([element(1, "AXTextField", "Search")])
        let request = DriveRequest(goal: "x")
        #expect(DriveEngine.vet(.press(token: 9), snapshot: window, request: request, hasScreenshot: false)
            == .untrustedAnswer("there is no element 9"))
        if case .handedBack = DriveEngine.vet(.type(token: 1, text: "my password is x", submit: false),
                                             snapshot: window, request: request, hasScreenshot: false) {} else {
            Issue.record("credential-shaped text should hand back")
        }
        #expect(DriveEngine.vet(.clickPoint(.zero), snapshot: window, request: request, hasScreenshot: false) != nil)
        #expect(DriveEngine.vet(.clickPoint(.zero), snapshot: window, request: request, hasScreenshot: true) == nil)
        #expect(DriveEngine.vet(.key("cmd+q"), snapshot: window, request: request, hasScreenshot: false) == .refusedControl(label: "cmd+q"))
        #expect(DriveEngine.vet(.key("cmd+n"), snapshot: window, request: request, hasScreenshot: false) == nil)
    }

    @Test func successContainsNeedsEveryString() {
        let window = snapshot([element(1, "AXButton", "New Note")], visible: ["Buy milk", "Today"])
        #expect(DriveEngine.successContainsMatched(["buy milk"], in: window))
        #expect(!DriveEngine.successContainsMatched(["buy milk", "eggs"], in: window))
        #expect(!DriveEngine.successContainsMatched([], in: window))
    }

    @Test func suppliedValuesMatchFieldLabels() {
        let field = element(1, "AXTextField", "Search notes")
        #expect(DriveEngine.suppliedValue(for: field, values: ["search notes": "milk"]) == "milk")
        #expect(DriveEngine.suppliedValue(for: field, values: ["Search": "eggs"]) == "eggs")
        #expect(DriveEngine.suppliedValue(for: field, values: ["Title": "x"]) == nil)
    }

    @Test func promptListsTokensHistoryAndGuards() {
        let window = snapshot([element(1, "AXButton", "New Note"), element(2, "AXTextField", "Search", value: "milk")])
        let prompt = DriveEngine.stepPrompt(request: DriveRequest(goal: "a note says hi", neverPress: ["Archive"]),
                                            snapshot: window, step: 2, history: ["pressed \"New Note\""], hasScreenshot: false)
        #expect(prompt.contains("Goal: a note says hi"))
        #expect(prompt.contains("Step 3 of at most"))
        #expect(prompt.contains("[1] button \"New Note\""))
        #expect(prompt.contains("[2] textfield \"Search\" value=\"milk\""))
        #expect(prompt.contains("- pressed \"New Note\""))
        #expect(prompt.contains("Archive"))
        #expect(prompt.contains("Send"))
        #expect(!prompt.contains("Window text"))

        let calculator = snapshot([element(1, "AXButton", "Equals")], visible: ["12", "Equals"])
        let withResult = DriveEngine.stepPrompt(request: DriveRequest(goal: "shows 7 + 5"), snapshot: calculator,
                                                step: 4, history: [], hasScreenshot: false)
        #expect(withResult.contains("Window text"))
        #expect(withResult.contains("- 12"))
        #expect(!withResult.contains("- Equals"))
    }

    @Test func talkDirectivesBecomeRequests() {
        let reply = #"On it. [ACT:drive:Notes|a new note says "buy milk"] and [ACT:drive:the sidebar is hidden] [ACT:click:Save]"#
        let requests = DriveDirectiveParser.requests(in: reply)
        #expect(requests.count == 2)
        #expect(requests[0].applicationName == "Notes")
        #expect(requests[0].goal == #"a new note says "buy milk""#)
        #expect(requests[1].applicationName == nil)
        #expect(requests[1].goal == "the sidebar is hidden")
        #expect(ComputerUseTagParser.action(fromTagBody: "drive:Notes|x") == nil)
        #expect(GuidedReplyParser.strippingControlTags(from: reply).contains("drive") == false)
    }
}

private func calculator(result: String = "0") -> DriveSnapshot {
    var tokens = 0
    let keys = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "add", "subtract", "multiply", "divide", "equals", "all clear", "delete"]
    let buttons = keys.map { label -> DriveElement in tokens += 1; return element(tokens, "AXButton", label) }
    return DriveSnapshot(applicationName: "Calculator", processIdentifier: 1, windowTitle: "Calculator",
                         elements: buttons, visibleStrings: [result] + keys)
}

struct DriveFastLaneTests {
    @Test func readsSumsOutOfGoals() {
        #expect(DriveFastLane.parseSum("Use Calculator and work out 9 times 3 for me")?.result == "27")
        #expect(DriveFastLane.parseSum("what is 12 + 30")?.result == "42")
        #expect(DriveFastLane.parseSum("7×6")?.result == "42")
        #expect(DriveFastLane.parseSum("1 + 2 + 3")?.result == nil)
        #expect(DriveFastLane.parseSum("1 + 2 + 3")?.tokens.count == 5)
        #expect(DriveFastLane.parseSum("open the Notes app") == nil)
        #expect(DriveFastLane.parseSum("version 2.5 is out") == nil)
    }

    @Test func plansASumOnlyWhenTheWindowHasEveryKey() {
        let plan = DriveFastLane.plan(forGoal: "work out 9 times 3", in: calculator())
        #expect(plan?.labels == ["9", "multiply", "3", "equals"])
        #expect(plan?.expectedResult == "27")
        #expect(DriveFastLane.plan(forGoal: "work out 9 times 3", in: snapshot([element(1, "AXButton", "Downloads")])) == nil)
        #expect(DriveFastLane.plan(forGoal: "work out 12 times 3", in: calculator())?.labels == ["1", "2", "multiply", "3", "equals"])
    }

    @Test func resolvesLabelsToOneButtonAndSkipsFields() {
        let window = calculator()
        #expect(DriveFastLane.resolve("×", in: window)?.label == "multiply")
        #expect(DriveFastLane.resolve("=", in: window)?.label == "equals")
        #expect(DriveFastLane.resolve("5", in: window)?.label == "5")
        #expect(DriveFastLane.resolve("nothing", in: window) == nil)
        let twins = snapshot([element(1, "AXButton", "Open"), element(2, "AXButton", "Open")])
        #expect(DriveFastLane.resolve("open", in: twins) == nil)
        let field = snapshot([element(1, "AXTextField", "3")])
        #expect(DriveFastLane.resolve("3", in: field) == nil)
    }

    @Test func recognisesTheResultOnScreen() {
        #expect(DriveFastLane.windowShows("27", in: calculator(result: "\u{200E}27")))
        #expect(DriveFastLane.windowShows("1234", in: calculator(result: "1,234")))
        #expect(!DriveFastLane.windowShows("27", in: calculator(result: "270")))
        #expect(!DriveFastLane.windowShows("27", in: calculator(result: "27 items")))
    }

    @Test func plansComeFromPressRepliesOnly() {
        #expect(DriveEngine.parsePlan(#"{"action":"press","element":1,"plan":["multiply","3","equals"]}"#) == ["multiply", "3", "equals"])
        #expect(DriveEngine.parsePlan(#"{"action":"type","text":"x","plan":["a"]}"#).isEmpty)
        #expect(DriveEngine.parsePlan(#"{"action":"press","element":1,"plan":["a",2]}"#).isEmpty)
        #expect(DriveEngine.parsePlan(#"{"action":"press","element":1}"#).isEmpty)
    }
}

struct DriveTakeBackJudgeTests {
    @Test func clicksAndKeysTakeBackAtOnce() {
        var judge = DriveTakeBackJudge()
        #expect(judge.observe(DrivePointerInput(kind: .click, isSynthesized: false, location: .zero), at: Date()) == .pointer)
        #expect(judge.observe(DrivePointerInput(kind: .key(keyCode: 53), isSynthesized: false, location: .zero), at: Date()) == .escape)
        #expect(judge.observe(DrivePointerInput(kind: .key(keyCode: 0), isSynthesized: false, location: .zero), at: Date()) == .keyboard)
    }

    @Test func heyMatesOwnInputNeverCounts() {
        var judge = DriveTakeBackJudge()
        #expect(judge.observe(DrivePointerInput(kind: .click, isSynthesized: true, location: .zero), at: Date()) == nil)
        #expect(judge.observe(DrivePointerInput(kind: .move, isSynthesized: true, location: .zero), at: Date()) == nil)
        #expect(judge.userPointerMoveStart == nil)
    }

    @Test func movesCountOnlyPastTheThresholdAndOutsideActuation() {
        var judge = DriveTakeBackJudge()
        let now = Date()
        _ = judge.observe(DrivePointerInput(kind: .move, isSynthesized: false, location: CGPoint(x: 100, y: 100)), at: now)
        #expect(judge.evaluate(currentLocation: CGPoint(x: 103, y: 102), now: now, actuatingUntil: .distantPast) == nil)
        #expect(judge.evaluate(currentLocation: CGPoint(x: 140, y: 100), now: now, actuatingUntil: .distantPast) == .pointer)

        var acting = DriveTakeBackJudge()
        _ = acting.observe(DrivePointerInput(kind: .move, isSynthesized: false, location: .zero), at: now)
        #expect(acting.evaluate(currentLocation: CGPoint(x: 400, y: 0), now: now, actuatingUntil: now.addingTimeInterval(1)) == nil)
        #expect(acting.userPointerMoveStart == nil)
    }
}

@MainActor
private final class ScriptedDecider: DriveStepDeciding {
    var replies: [String]
    private(set) var prompts: [String] = []
    init(_ replies: [String]) { self.replies = replies }
    func decide(systemPrompt: String, prompt: String, images: [(data: Data, label: String)]) async throws -> String {
        prompts.append(prompt)
        return replies.isEmpty ? #"{"action":"blocked","reason":"script ran out"}"# : replies.removeFirst()
    }
}

@MainActor
private final class FakeAppDriver: DriveAppDriving {
    var lastPoint: CGPoint?
    var userTookOver = false
    var onWillAct: ((CGPoint) -> Void)?
    var windows: [DriveSnapshot]
    private(set) var performed: [DriveDecision] = []
    init(_ windows: [DriveSnapshot]) { self.windows = windows }
    func snapshot(processIdentifier: pid_t) async -> DriveSnapshot? {
        windows.count > 1 ? windows.removeFirst() : windows.first
    }
    func perform(_ decision: DriveDecision, in snapshot: DriveSnapshot, request: DriveRequest, screenshot: ScreenSnapshot?) async throws -> String {
        performed.append(decision)
        return "ok"
    }
}

@MainActor
struct DriveTakeOverControllerTests {
    private func controller(driver: FakeAppDriver, decider: ScriptedDecider, consent: Bool = true) -> DriveTakeOverController {
        DriveTakeOverController(
            makeDriver: { driver },
            makeDecider: { decider },
            accessibilityTrusted: { true },
            captureScreen: { nil },
            settleDelay: .zero,
            requestConsent: { _, _ in consent },
            watchesInput: false
        )
    }

    private let finder = DriveRequest(goal: "the Downloads folder is open", targetBundleID: "com.apple.finder", origin: "test")

    @Test func drivesUntilTheModelReadsDone() async {
        let driver = FakeAppDriver([snapshot([element(1, "AXButton", "Downloads")])])
        let decider = ScriptedDecider([#"{"action":"press","element":1}"#, #"{"action":"done","summary":"Downloads is open"}"#])
        let drive = controller(driver: driver, decider: decider)
        let outcome = await drive.run(finder)
        #expect(outcome.status == .done(summary: "Downloads is open"))
        #expect(outcome.ending == .completed)
        #expect(driver.performed == [.press(token: 1)])
        #expect(outcome.actionLog == ["pressed \"Downloads\" → ok"])
        #expect(drive.phase == .idle)
        #expect(drive.status(for: outcome.driveIdentifier)["status"] as? String == "done")
    }

    @Test func successContainsEndsBeforeAskingTheModel() async {
        let driver = FakeAppDriver([snapshot([element(1, "AXButton", "Downloads")], visible: ["Downloads — 12 items"])])
        let decider = ScriptedDecider([])
        var request = finder
        request.successContains = ["12 items"]
        let outcome = await controller(driver: driver, decider: decider).run(request)
        #expect(outcome.status == .successContainsMatched)
        #expect(decider.prompts.isEmpty)
    }

    @Test func declinedConsentNeverActs() async {
        let driver = FakeAppDriver([snapshot([element(1, "AXButton", "Downloads")])])
        let decider = ScriptedDecider([#"{"action":"press","element":1}"#])
        let outcome = await controller(driver: driver, decider: decider, consent: false).run(finder)
        #expect(outcome.status == .declined)
        #expect(driver.performed.isEmpty)
        #expect(decider.prompts.isEmpty)
    }

    @Test func refusedControlStopsWithoutPressing() async {
        let driver = FakeAppDriver([snapshot([element(1, "AXButton", "Empty Trash")])])
        let outcome = await controller(driver: driver, decider: ScriptedDecider([#"{"action":"press","element":1}"#])).run(finder)
        #expect(outcome.status == .refusedControl(label: "Empty Trash"))
        #expect(driver.performed.isEmpty)
    }

    @Test func stepCapEndsARunawayDrive() async {
        let driver = FakeAppDriver([snapshot([element(1, "AXButton", "Downloads")])])
        let decider = ScriptedDecider(Array(repeating: #"{"action":"press","element":1}"#, count: 5))
        var request = finder
        request.maxSteps = 3
        let outcome = await controller(driver: driver, decider: decider).run(request)
        #expect(outcome.status == .maxSteps)
        #expect(driver.performed.count == 3)
    }

    @Test func garbageTwiceIsUntrusted() async {
        let driver = FakeAppDriver([snapshot([element(1, "AXButton", "Downloads")])])
        let outcome = await controller(driver: driver, decider: ScriptedDecider(["hmm", "still no"])).run(finder)
        #expect(outcome.status == .untrustedAnswer("no valid action in the reply"))
        #expect(driver.performed.isEmpty)
    }

    @Test func aSumInTheGoalRunsWithoutAskingTheModel() async {
        let driver = FakeAppDriver([calculator(), calculator(), calculator(), calculator(), calculator(result: "27")])
        let decider = ScriptedDecider([])
        let outcome = await controller(driver: driver, decider: decider)
            .run(DriveRequest(goal: "work out 9 times 3", targetBundleID: "com.apple.calculator", origin: "test"))
        #expect(outcome.status == .done(summary: "The window shows 27."))
        #expect(decider.prompts.isEmpty)
        #expect(driver.performed.count == 4)
        #expect(driver.performed.first == .press(token: 10))
    }

    @Test func aModelPlanRunsThenDropsWhenTheWindowDiverges() async {
        let keys = calculator()
        let odd = snapshot([element(1, "AXButton", "Unrelated")])
        let driver = FakeAppDriver([keys, keys, odd])
        let decider = ScriptedDecider([
            #"{"action":"press","element":2,"plan":["multiply","3"]}"#,
            #"{"action":"done","summary":"asked again"}"#,
        ])
        let outcome = await controller(driver: driver, decider: decider)
            .run(DriveRequest(goal: "make it so", targetBundleID: "com.apple.calculator", origin: "test"))
        #expect(outcome.status == .done(summary: "asked again"))
        #expect(decider.prompts.count == 2)
        #expect(driver.performed.count == 2)
    }

    @Test func plannedPressesAreStillVetted() async {
        let keys = DriveSnapshot(applicationName: "Mail", processIdentifier: 1, windowTitle: nil,
                                 elements: [element(1, "AXButton", "Draft"), element(2, "AXButton", "Send")], visibleStrings: [])
        let driver = FakeAppDriver([keys])
        let decider = ScriptedDecider([#"{"action":"press","element":1,"plan":["send"]}"#])
        let outcome = await controller(driver: driver, decider: decider)
            .run(DriveRequest(goal: "tidy", targetBundleID: "com.apple.mail", origin: "test"))
        #expect(outcome.status == .refusedControl(label: "Send"))
        #expect(driver.performed == [.press(token: 1)])
    }

    @Test func oneDriveAtATime() async {
        let driver = FakeAppDriver([snapshot([element(1, "AXButton", "Downloads")])])
        let drive = controller(driver: driver, decider: ScriptedDecider([#"{"action":"done","summary":"ok"}"#]))
        let first = drive.offer(finder)
        #expect(first != nil)
        #expect(drive.offer(finder) == nil)
        drive.cancel()
    }
}

struct DriveRouteTests {
    @Test func offerNeedsAGoalAndATokenStatusAndCancelDoNot() {
        let route = LocalControlRouter.route(method: "POST", path: "/drive/offer", json: [
            "goal": "the note says hi", "app": "Notes", "never_press": ["Share"], "max_steps": 7,
            "values": ["Title": "hi"], "success_contains": ["hi"],
        ])
        guard case .accepted(let command) = route, case .driveOffer(let request) = command else {
            Issue.record("expected a drive offer"); return
        }
        #expect(request.goal == "the note says hi")
        #expect(request.applicationName == "Notes")
        #expect(request.neverPress == ["Share"])
        #expect(request.maxSteps == 7)
        #expect(request.values == ["Title": "hi"])
        #expect(request.successContains == ["hi"])
        #expect(request.origin == "bridge")
        #expect(command.touchesConnectedAccounts)

        #expect(LocalControlRouter.route(method: "POST", path: "/drive/offer", json: [:])
            == .rejected(statusCode: 400, message: "Missing goal"))
        #expect(LocalControlRouter.route(method: "GET", path: "/drive/status", json: [:]) == .accepted(.driveStatus(driveIdentifier: nil)))
        #expect(LocalControlRouter.route(method: "POST", path: "/drive/cancel", json: ["driveIdentifier": "a"])
            == .accepted(.driveCancel(driveIdentifier: "a")))
        #expect(!LocalControlCommand.driveStatus(driveIdentifier: nil).touchesConnectedAccounts)
        #expect(LocalControlRouter.route(method: "POST", path: "/drive/offer", json: ["goal": "x", "action": "click"])
            == .rejected(statusCode: 400, message: "Click is not supported"))
    }

    @Test func agentsGetTheDriveTool() {
        #expect(HeyMateMCPServer.toolNames.contains("heymate_drive"))
        #expect(HeyMateMCPServer.serverSource.contains("name: \"heymate_drive\""))
        #expect(HeyMateMCPServer.serverSource.contains("\"/drive/status\""))
    }
}
