import Foundation

// Keep the probe independent of the app, its preferences, and its log directory.
enum HeyMateLog { static func log(_ message: String) {} }

@main
struct ExplanationProgramProbe {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    @MainActor
    final class GatedSpeech: TTSClient {
        var pending: CheckedContinuation<Void, Error>?
        var isPlaying = false
        func speakText(_ text: String) async throws {
            try await withCheckedThrowingContinuation { pending = $0 }
            isPlaying = true
        }
        func stopPlayback() {
            let continuation = pending
            pending = nil
            isPlaying = false
            continuation?.resume(throwing: CancellationError())
        }
        func beginPlayback() {
            let continuation = pending
            pending = nil
            continuation?.resume()
        }
    }

    @MainActor
    static func main() async throws {
        let focused = ExplanationProgram.viewport(captureFrame: CGRect(x: 40,y: 60,width: 1400,height: 820), imageSize: CGSize(width:2048,height:1201), displayFrame:CGRect(x:0,y:0,width:1512,height:982), existingFrame:nil, existingCanvas:nil)
        let full = ExplanationProgram.viewport(captureFrame: CGRect(x:0,y:0,width:1512,height:982),imageSize:CGSize(width:2048,height:1330),displayFrame:CGRect(x:0,y:0,width:1512,height:982),existingFrame:focused.frame,existingCanvas:focused.canvas)
        require(full.canvas == focused.canvas && full.frame == focused.frame, "Capture change reset retained viewport")
        let projectedX = 100 * focused.projection.scaleX + focused.projection.offsetX
        require(abs(projectedX / focused.canvas.width * focused.frame.width - (40 + 100.0 / 2048 * 1400)) < 0.001, "Focused screenshot projection shifted target")
        let first = #"{"id":"highlight","say":"This cylinder guides the piston.","ops":[{"op":"ring","id":"source","args":[100,100,180,60,"Cylinder"]}]}"#
        let second = #"{"id":"build","say":"The piston slides inside the cutaway cylinder.","ops":[{"op":"figure","id":"engine","args":[500,120,600,500,{"spin":0.6}]},{"op":"part","figure":"engine","id":"cylinder","kind":"tube","options":{"r":0.65,"inner":0.52,"h":1.6,"at":[0,0.2,0],"mat":"iron","cut":true,"name":"Cylinder"}},{"op":"part","figure":"engine","id":"piston","kind":"cyl","options":{"r":0.48,"h":0.4,"at":[0,0.27,0],"mat":"alu","name":"Piston"}},{"op":"call","target":"engine","method":"label","args":[{"ref":"piston"},"Piston"]}]}"#
        let third = #"{"id":"motion","say":"Both rod ends stay attached as the crank turns.","ops":[{"op":"part","figure":"engine","id":"rod","kind":"box","options":{"size":[0.15,1.15,0.13],"at":[0,-0.305,0],"mat":"steel","name":"Connecting rod"}},{"op":"part","figure":"engine","id":"crank","kind":"group","options":{"at":[0,-1.2,0],"name":"Crank"}},{"op":"part","figure":"engine","id":"shaft","kind":"cyl","options":{"parent":{"ref":"crank"},"r":0.12,"h":0.8,"axis":"z","mat":"iron"}},{"op":"part","figure":"engine","id":"pin","kind":"cyl","options":{"parent":{"ref":"crank"},"r":0.08,"h":0.3,"axis":"z","at":[0,0.32,0],"mat":"brass"}},{"op":"call","target":"engine","method":"label","args":[{"ref":"rod"},"Connecting rod"]},{"op":"call","target":"engine","method":"sliderCrank","args":[{"piston":{"ref":"piston"},"rod":{"ref":"rod"},"crank":{"ref":"crank"},"radius":0.32,"rodLength":1.15,"period":2.4}]}]}"#
        let text = ExplanationProgram.fence + first + "\n" + second + "\n" + third + "\n```"
        let compiled = ExplanationProgram.compile(text)!
        require(compiled.error == nil && compiled.lines.count == 3 && compiled.closed, "Valid lesson rejected")
        require(ExplainerParser.extract(from: text).lines.count == 3, "Talk did not recognise typed drawing")
        let raw = "```js\nstep(1);say(\"Unsafe\");globalThis.webkit.messageHandlers.heymate.postMessage({type:'action'});\n```"
        require(ExplainerParser.extract(from: ExplainerParser.validatedTalkReply(raw)).program == nil, "Talk accepted raw model source")
        require(compiled.inventory["rod"] == "box", "Named inventory lost")
        let loft = #"{"id":"body","say":"The body tapers in both dimensions.","ops":[{"op":"figure","id":"f","args":[10,10,400,400]},{"op":"part","figure":"f","id":"nose","kind":"loft","options":{"sections":[[-1,0.4,0.2],[1,0.1,0.05]],"squareness":4,"mat":"paint:red"}}]}"#
        let lofted = ExplanationProgram.compile(ExplanationProgram.fence + loft + "\n```")!
        require(lofted.error == nil && lofted.inventory["nose"] == "loft", "Tapered body grammar rejected")
        let localized = #"{"id":"構造","say":"These connected parts keep their names.","ops":[{"op":"figure","id":"図","args":[10,10,400,400]},{"op":"part","figure":"図","id":"stütze","kind":"cyl","options":{"r":0.05,"h":1}},{"op":"set","target":"stu\u0308tze","values":{"color":"red"}}]}"#
        let localizedProgram = ExplanationProgram.compile(ExplanationProgram.fence + localized + "\n```", availableIDs: [:])!
        require(localizedProgram.error == nil && localizedProgram.inventory["stütze"] == "cyl", "Localized handle rejected")
        let invalidID = localized.replacingOccurrences(of: "stütze", with: "bad;identifier")
        require(ExplanationProgram.compile(ExplanationProgram.fence + invalidID + "\n```")!.lines.isEmpty, "Source punctuation accepted as an id")
        let timeline = #"{"id":"release-plan","say":"Design takes two days; review takes three.","ops":[{"op":"timeline","id":"plan","args":[100,200,600,[[0,"Design","Mon"],[2,"Review","Wed"],[5,"Ship","Sat"]],{"from":0,"to":5}]}]}"#
        let timelineProgram = ExplanationProgram.compile(ExplanationProgram.fence + timeline + "\n```")!
        require(timelineProgram.error == nil, "Timeline event list treated as a height")
        let chart = #"{"id":"sales","say":"Wednesday recovers above Monday after Tuesday's dip.","ops":[{"op":"graph","id":"sales","args":[100,100,500,300,{"x":[1,3],"y":[0,20],"xTicks":[[1,"Mon"],[2,"Tue"],[3,"Wed"]],"yTicks":[0,10,20]}]},{"op":"call","id":"series","target":"sales","method":"plot","args":[[[1,12],[2,8],[3,15]],{"tone":"blue"}]}]}"#
        let chartProgram = ExplanationProgram.compile(ExplanationProgram.fence + chart + "\n```", availableIDs: [:])!
        require(chartProgram.error == nil, "Chart data protocol rejected")
        let chartEdit = #"{"id":"red-series","say":"Only the plotted series changes colour.","ops":[{"op":"recolor","target":"series","args":["red"]}]}"#
        let chartEdited = ExplanationProgram.compile(ExplanationProgram.fence + chartEdit + "\n```", availableIDs: chartProgram.inventory)!
        require(chartEdited.error == nil, "Chart series edit rejected")
        for length in 0..<third.count {
            let partial = ExplanationProgram.compile(ExplanationProgram.fence + first + "\n" + second + "\n" + third.prefix(length))!
            require(partial.lines.count == 2, "Partial beat executed")
        }
        let invalid = #"{"id":"bad","say":"This beat must stay silent.","ops":[{"op":"circle","args":[1,2,3]},{"op":"javascript","code":"while(true){}"}]}"#
        let stopped = ExplanationProgram.compile(ExplanationProgram.fence + first + "\n" + invalid + "\n" + third + "\n```")!
        require(stopped.error != nil && stopped.lines.count == 1, "Invalid beat partially executed or later beats released")
        let badGeometry = #"{"id":"bad","say":"Invalid size.","ops":[{"op":"figure","id":"f","args":[10,20,-100,400]}]}"#
        require(ExplanationProgram.compile(ExplanationProgram.fence + badGeometry + "\n```")!.lines.isEmpty, "Negative viewport created a partial beat")
        let badProperty = #"{"id":"bad","say":"Invalid vector.","ops":[{"op":"set","target":"rod","values":{"pos":[1,2]}}]}"#
        require(ExplanationProgram.compile(ExplanationProgram.fence + badProperty + "\n```")!.lines.isEmpty, "Malformed part transform was accepted")
        let injected = #"{"id":"escape","say":"Quote safe.","ops":[{"op":"text","args":[100,100,"\"); globalThis.escaped = true; //"]}]}"#
        let escaped = ExplanationProgram.compile(ExplanationProgram.fence + injected + "\n```")!
        require(escaped.error == nil, "Text containing source punctuation must remain text")
        let expansion = second.replacingOccurrences(of: "\"r\":0.65", with: "\"copies\":{\"count\":32},\"around\":{\"count\":32},\"r\":0.65")
        require(ExplanationProgram.compile(ExplanationProgram.fence + expansion + "\n```")!.lines.isEmpty, "Repeat expansion bypasses scene limit")
        let edit = #"{"id":"red","say":"The same rod is red.","ops":[{"op":"recolor","target":"rod","args":["red"]}]}"#
        let edited = ExplanationProgram.compile(ExplanationProgram.fence + edit + "\n```")!
        require(edited.error == nil, "Follow-up edit rejected")

        let speaker = GatedSpeech()
        var released = false
        let task = Task { try await ExplanationSpeech.start("Delayed voice", speaker: speaker, silent: false) { released = true } }
        while speaker.pending == nil { await Task.yield() }
        require(!released, "Visual released during synthesis")
        speaker.beginPlayback()
        _ = try await task.value
        require(released, "Visual did not start with playback")
        released = false
        let cancelled = Task { try await ExplanationSpeech.start("Interrupted", speaker: speaker, silent: false) { released = true } }
        while speaker.pending == nil { await Task.yield() }
        cancelled.cancel()
        speaker.stopPlayback()
        do { _ = try await cancelled.value; fatalError("Cancelled beat continued") }
        catch is CancellationError {}
        require(!released, "Cancelled beat released visuals")
        _ = try await ExplanationSpeech.start("Silent reading", speaker: speaker, silent: true) { released = true }
        require(released && speaker.pending == nil, "Silent beat invoked voice")

        let erase = #"{"id":"erase","say":"Only the screen mark goes away.","ops":[{"op":"erase","target":"source"}]}"#
        let erased = ExplanationProgram.compile(ExplanationProgram.fence + erase + "\n```")!
        require(erased.error == nil, "Named piece erase rejected")
        let missingReference = #"{"id":"missing","say":"No partial figure.","ops":[{"op":"figure","id":"new","args":[10,10,400,400]},{"op":"call","target":"absent","method":"label","args":[[0,0,0],"Missing"]}]}"#
        let rejected = ExplanationProgram.compile(ExplanationProgram.fence + missingReference + "\n```", availableIDs: [:])!
        require(rejected.rows.isEmpty && rejected.error != nil, "Missing handle left a partial beat")
        require(ExplanationProgram.compile(ExplanationProgram.fence + edit + "\n```", availableIDs: ["rod":"box"])!.error == nil, "Retained handle rejected")
        var output = ["erase": erased.source, "program": compiled.source, "edit": edited.source, "escaped": escaped.source, "reply": text,
                      "localized": localizedProgram.source, "timeline": timelineProgram.source, "chart": chartProgram.source, "chartEdit": chartEdited.source]
        if CommandLine.arguments.count > 1 {
            let input = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String:String]
            let base = ExplanationProgram.compile(input["base"]!, availableIDs: [:], projection: focused.projection)!
            let detail = ExplanationProgram.compile(input["detail"]!, availableIDs: base.inventory, projection: full.projection)!
            require(base.error == nil && detail.error == nil, "Actual space-cat replies failed validation")
            output["userBase"] = base.source
            output["userDetail"] = detail.source
        }
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]))
    }
}
