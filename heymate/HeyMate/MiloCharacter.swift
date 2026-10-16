import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The asset token is the persisted character configuration. Unknown values are
/// rejected rather than silently changing a saved appearance.
struct MiloLook: Equatable, Hashable {
    enum CharacterPack: String, CaseIterable, Identifiable {
        case milo = "Milo", nova = "Nova"
        var id: String { rawValue }
        var label: String { rawValue }
        var summary: String { self == .milo ? "Warm, playful company." : "Bright eyes. A bold new perspective." }
    }
    enum Hairstyle: String, CaseIterable, Identifiable {
        case sweep, crop
        var id: String { rawValue }
        var label: String { self == .sweep ? "Side sweep" : "Soft crop" }
    }
    enum Hair: String, CaseIterable, Identifiable {
        case tide, copper, lilac
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
        var color: Color {
            switch self {
            case .tide: Color(red: 0.12, green: 0.32, blue: 0.37)
            case .copper: Color(red: 0.65, green: 0.27, blue: 0.15)
            case .lilac: Color(red: 0.57, green: 0.42, blue: 0.73)
            }
        }
    }
    enum Skin: String, CaseIterable, Identifiable {
        case sand, caramel, umber
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
        var color: Color {
            switch self {
            case .sand: Color(red: 0.92, green: 0.73, blue: 0.56)
            case .caramel: Color(red: 0.70, green: 0.43, blue: 0.28)
            case .umber: Color(red: 0.34, green: 0.19, blue: 0.13)
            }
        }
    }
    enum Eye: String, CaseIterable, Identifiable {
        case sea, amber, violet
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
        var color: Color {
            switch self {
            case .sea: Color(red: 0.25, green: 0.60, blue: 0.65)
            case .amber: Color(red: 0.72, green: 0.44, blue: 0.15)
            case .violet: Color(red: 0.56, green: 0.40, blue: 0.74)
            }
        }
    }

    enum Outfit: String, CaseIterable, Identifiable {
        case classic, future
        var id: String { rawValue }
        var label: String { self == .classic ? "Classic blue" : "Future cobalt" }
    }

    enum Hat: String, CaseIterable, Identifiable {
        case none, orbitCap = "orbitcap"
        var id: String { rawValue }
        var label: String { self == .none ? "No hat" : "Orbit cap" }
    }
    enum Eyewear: String, CaseIterable, Identifiable {
        case none, sunglasses
        var id: String { rawValue }
        var label: String { self == .none ? "No glasses" : "Sunglasses" }
    }

    var characterPack: CharacterPack = .milo
    var hairstyle: Hairstyle = .sweep
    var hair: Hair = .tide
    var skin: Skin = .caramel
    var eye: Eye = .sea
    var outfit: Outfit = .classic
    var hat: Hat = .none
    var eyewear: Eyewear = .none

    static let standard = MiloLook()
    /// New unconfigured default mates wear the future outfit; saved classic tokens stay classic.
    static let defaultLook = MiloLook(outfit: .future)
    static func defaultLook(for characterPack: CharacterPack) -> MiloLook {
        MiloLook(characterPack: characterPack, outfit: .future)
    }
    /// Five-part tokens remain the classic outfit for backward compatibility.
    var assetName: String {
        headAssetName + (outfit == .future ? "-future" : "")
            + (hat == .none ? "" : "-hat-" + hat.rawValue)
            + (eyewear == .none ? "" : "-glasses-" + eyewear.rawValue)
    }
    var headAssetName: String { "\(characterPack.rawValue)-\(hairstyle.rawValue)-\(hair.rawValue)-\(skin.rawValue)-\(eye.rawValue)" }
    var bodyAssetName: String { "\(characterPack.rawValue)Body-\(hairstyle.rawValue)-\(hair.rawValue)-\(skin.rawValue)-\(eye.rawValue)-\(outfit.rawValue)" }
    var label: String { "\(characterPack.label) · \(hairstyleLabel(hairstyle)), \(hairLabel(hair)), \(skin.label), \(eye.label) eyes, \(outfit.label), \(hat.label), \(eyewear.label)" }
    var hasStandardFace: Bool { hairstyle == .sweep && hair == .tide && skin == .caramel && eye == .sea }
    func hairstyleLabel(_ style: Hairstyle) -> String {
        characterPack == .nova ? (style == .sweep ? "Sculpted bob" : "High bun") : style.label
    }
    func hairLabel(_ color: Hair) -> String { characterPack == .nova && color == .tide ? "Midnight" : color.label }
    func hairColor(_ color: Hair) -> Color {
        characterPack == .nova && color == .tide ? Color(red: 0.055, green: 0.075, blue: 0.14) : color.color
    }

    init(characterPack: CharacterPack = .milo, hairstyle: Hairstyle = .sweep, hair: Hair = .tide, skin: Skin = .caramel, eye: Eye = .sea, outfit: Outfit = .classic, hat: Hat = .none, eyewear: Eyewear = .none) {
        self.characterPack = characterPack
        self.hairstyle = hairstyle
        self.hair = hair
        self.skin = skin
        self.eye = eye
        self.outfit = outfit
        self.hat = hat
        self.eyewear = eyewear
    }

    init?(assetName: String) {
        let parts = assetName.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 5,
              let characterPack = CharacterPack(rawValue: parts[0]),
              let hairstyle = Hairstyle(rawValue: parts[1]),
              let hair = Hair(rawValue: parts[2]),
              let skin = Skin(rawValue: parts[3]),
              let eye = Eye(rawValue: parts[4]) else { return nil }
        var index = 5
        var outfit: Outfit = .classic
        var hat: Hat = .none
        var eyewear: Eyewear = .none
        if index < parts.count, parts[index] == "future" { outfit = .future; index += 1 }
        if index < parts.count, parts[index] == "hat" {
            guard index + 1 < parts.count, parts[index + 1] == Hat.orbitCap.rawValue else { return nil }
            hat = .orbitCap
            index += 2
        }
        if index < parts.count, parts[index] == "glasses" {
            guard index + 1 < parts.count, parts[index + 1] == Eyewear.sunglasses.rawValue else { return nil }
            eyewear = .sunglasses
            index += 2
        }
        guard index == parts.count else { return nil }
        self.init(characterPack: characterPack, hairstyle: hairstyle, hair: hair, skin: skin, eye: eye,
                  outfit: outfit, hat: hat, eyewear: eyewear)
    }

    static let allLooks: [MiloLook] = CharacterPack.allCases.flatMap { characterPack in
        Hairstyle.allCases.flatMap { style in
            Hair.allCases.flatMap { hair in
                Skin.allCases.flatMap { skin in
                    Eye.allCases.flatMap { eye in
                        Outfit.allCases.map { MiloLook(characterPack: characterPack, hairstyle: style, hair: hair, skin: skin, eye: eye, outfit: $0) }
                    }
                }
            }
        }
    }

    static func random(characterPack: CharacterPack = .milo) -> MiloLook {
        MiloLook(characterPack: characterPack, hairstyle: Hairstyle.allCases.randomElement()!, hair: Hair.allCases.randomElement()!,
                 skin: Skin.allCases.randomElement()!, eye: Eye.allCases.randomElement()!, outfit: Outfit.allCases.randomElement()!,
                 hat: Hat.allCases.randomElement()!, eyewear: Eyewear.allCases.randomElement()!)
    }

    func wearing(hat: Hat) -> MiloLook {
        var updated = self
        updated.hat = hat
        return updated
    }
    func wearing(eyewear: Eyewear) -> MiloLook {
        var updated = self
        updated.eyewear = eyewear
        return updated
    }

    var gazeBaseAssetName: String { "\(characterPack.rawValue)GazePeek-\(hairstyle.rawValue)-\(hair.rawValue)-\(skin.rawValue)-\(eye.rawValue)" }
    var gazeEyesAssetName: String { "\(characterPack.rawValue)GazeEyes-\(eye.rawValue)" }
    var perchedAssetName: String { "\(characterPack.rawValue)Peek-\(hairstyle.rawValue)-\(hair.rawValue)-\(skin.rawValue)-\(eye.rawValue)" }

    /// Custom combinations have a neutral perched render. Do not swap
    /// their materials back to the standard look when an agent changes state.
    func companionAsset(for expression: MateFaceExpression) -> String {
        guard hasStandardFace, hat == .none, eyewear == .none else { return perchedAssetName }
        let prefix = characterPack.rawValue + (outfit == .classic ? "" : "Future")
        switch expression {
        case .still: return prefix + "Peek"
        case .idle, .listening: return prefix + "Peek"
        case .thinking, .reading, .writing, .tooling, .browsing, .attention: return prefix + "PeekThink"
        case .speaking, .guiding: return prefix + "PeekWave"
        case .success: return prefix + "PeekCelebrate"
        case .failure: return prefix + "Peek"
        }
    }
}

enum LookArtworkKind: String { case head, peek, body }

/// Accessory layers share the base render's camera and transparent canvas.
/// Hats and glasses compose independently, so both may be worn together.
struct LookAccessoryOverlay: View {
    let look: MiloLook
    let kind: LookArtworkKind
    var body: some View {
        ZStack {
            if look.hat != .none { layer(look.hat.rawValue) }
            if look.eyewear != .none { layer(look.eyewear.rawValue) }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
    private func layer(_ accessory: String) -> some View {
        Image("\(look.characterPack.rawValue)Accessory-\(accessory)-\(kind.rawValue)")
            .resizable().interpolation(.high).scaledToFit()
    }
}

struct LookArtworkView: View {
    let look: MiloLook
    let kind: LookArtworkKind
    var baseAssetName: String? = nil
    private var base: String {
        if let baseAssetName { return baseAssetName }
        switch kind {
        case .head: return look.headAssetName
        case .peek: return look.perchedAssetName
        case .body: return look.bodyAssetName
        }
    }
    var body: some View {
        Image(base).resizable().interpolation(.high).scaledToFit()
            .overlay { LookAccessoryOverlay(look: look, kind: kind) }
    }
}

/// Transparent companion for the composer. Legacy art and user photos retain
/// their existing renderer. Customized Milo heads retain their selected look.
/// Original, bounded whole-head motion. Gaze follows the pointer only while it
/// is over the companion; no global input monitor or independent timer exists.
nonisolated struct MiloMotionPose: Equatable {
    var rotation: Double = 0
    var x: Double = 0
    var y: Double = 0
    var scale: Double = 1

    static func sample(expression: MateFaceExpression, elapsed: Double, gaze: CGSize = .zero) -> Self {
        guard expression != .still, elapsed.isFinite, elapsed > 0 else { return Self() }
        let safeX = gaze.width.isFinite ? min(max(Double(gaze.width), -1), 1) : 0
        let safeY = gaze.height.isFinite ? min(max(Double(gaze.height), -1), 1) : 0
        var pose = Self(rotation: safeX * 1.7, x: safeX * 0.014,
                        y: sin(elapsed * 1.6) * 0.006 + safeY * 0.007,
                        scale: 1 + sin(elapsed * 1.6) * 0.003)
        switch expression {
        case .thinking, .reading, .writing, .tooling, .browsing:
            pose.rotation += sin(elapsed * 1.9) * 1.1
        case .listening: pose.scale += 0.006
        case .speaking: pose.y += sin(elapsed * 7) * 0.006
        case .attention: pose.rotation += sin(elapsed * 2.3) * 1.4
        case .guiding: pose.rotation += sin(elapsed * 1.6) * 0.6
        case .success: pose.y -= sin(min(elapsed / 0.9, 1) * .pi) * 0.035
        case .failure: pose.rotation += sin(min(elapsed / 0.7, 1) * .pi * 4) * 2
        case .idle, .still: break
        }
        return pose
    }

    /// One short blink every 6.2 seconds, driven by the same display timeline.
    static func isBlinking(elapsed: Double) -> Bool {
        guard elapsed.isFinite, elapsed > 0 else { return false }
        let phase = elapsed.truncatingRemainder(dividingBy: 6.2)
        return phase >= 5.8 && phase < 5.94
    }
}

struct MiloCompanionView: View {
    let mate: Mate
    var size: CGFloat = 120
    var expression: MateFaceExpression = .idle
    var reactionEvent: MateReactionEvent? = nil
    var interactive = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.companionMotionSuppressed) private var motionSuppressed
    @Environment(\.companionSnapshotRendering) private var snapshotRendering
    @AppStorage(CompanionAppearancePreference.idleAnimationsKey) private var idleAnimations = true
    @State private var visible = false
    @State private var hover: CGSize = .zero
    @State private var startedAt = Date()
    @StateObject private var reactions = MateReactionDriver()

    private var policy: CompanionMotionPolicy {
        .init(reduceMotion: reduceMotion || motionSuppressed || snapshotRendering,
              idleAnimations: idleAnimations, isVisible: visible)
    }
    private var plays: Bool { expression != .still && policy.allowsPlayback(isIdle: expression == .idle) }
    private var reacting: Bool { expression != .still && reactions.active != nil && policy.allowsTransitions }

    var body: some View {
        Group {
            if let look = MiloLook(assetName: MateFace.selectionToken(for: mate)) {
                TimelineView(.animation(minimumInterval: 1 / 24, paused: !plays && !reacting)) { context in
                    let elapsed = plays ? max(0, context.date.timeIntervalSince(startedAt)) : 0
                    let pose = MiloMotionPose.sample(expression: expression, elapsed: elapsed,
                                                     gaze: plays ? hover : .zero)
                    let reaction = characterReaction(look: look, at: context.date)
                    companionArtwork(look: look, elapsed: elapsed,
                                     reactionBlink: reaction.leftEyeOpen < 0.3 || reaction.rightEyeOpen < 0.3,
                                     sampleDate: context.date)
                        .frame(width: size, height: size)
                        .scaleEffect(pose.scale, anchor: .bottom)
                        .rotationEffect(.degrees(pose.rotation), anchor: .bottom)
                        .offset(x: pose.x * size, y: pose.y * size)
                        .animation(policy.allowsTransitions ? .easeOut(duration: 0.22) : nil, value: hover)
                        .mateReactionTransform(reaction, size: size)
                }
                .frame(width: size, height: size)
                .contentShape(Rectangle())
                .mateReactionTaps(enabled: interactive && expression != .still && policy.allowsTransitions,
                                  size: size, driver: reactions, greeting: .hello)
                .onContinuousHover { phase in
                    guard plays else { hover = .zero; return }
                    switch phase {
                    case .active(let point):
                        let x = (point.x / max(size, 1) - 0.5) * 2
                        let y = (point.y / max(size, 1) - 0.5) * 2
                        let length = max(1, hypot(x, y))
                        hover = CGSize(width: x / length, height: y / length)
                    case .ended: hover = .zero
                    }
                }
                .onAppear { offerReaction() }
                .onChange(of: reactionEvent) { _, _ in offerReaction() }
                .onChange(of: policy) { _, newPolicy in
                    if newPolicy.reduceMotion || !newPolicy.isVisible { reactions.stop(); hover = .zero }
                    reactions.deliver(isVisible: newPolicy.isVisible,
                                      allowed: !newPolicy.reduceMotion && expression != .still)
                }
                .onChange(of: plays) { _, _ in startedAt = Date(); hover = .zero }
                .onChange(of: expression) { _, updated in
                    startedAt = Date()
                    if updated == .still { reactions.stop() }
                    if updated == .attention && policy.allowsTransitions { reactions.play(.approval) }
                }
                .onDisappear { reactions.stop(); hover = .zero }
                .background {
                    if !snapshotRendering && expression != .still { CompanionVisibilityProbe(isVisible: $visible) }
                }
                .accessibilityLabel("\(mate.name), \(look.label)")
            } else {
                MateFaceView(mate: mate, size: size, expression: expression,
                             reactionEvent: reactionEvent, interactive: interactive)
            }
        }
    }

    private func characterReaction(look: MiloLook, at date: Date) -> MateReactionPose {
        guard reacting else { return MateReactionPose() }
        var pose = reactions.pose(at: date)
        if look.characterPack == .nova {
            pose.tilt *= -0.75
            pose.lift *= 0.7
            pose.shake *= 0.65
        }
        return pose
    }

    @ViewBuilder
    private func companionArtwork(look: MiloLook, elapsed: Double, reactionBlink: Bool, sampleDate: Date) -> some View {
        let base = imageAsset(look: look, elapsed: elapsed, reactionBlink: reactionBlink)
        if (expression == .idle || expression == .listening), !base.hasSuffix("Blink"), look.eyewear == .none,
           NSImage(named: look.gazeBaseAssetName) != nil, NSImage(named: look.gazeEyesAssetName) != nil {
            MiloGazeArtwork(baseAssetName: look.gazeBaseAssetName, eyesAssetName: look.gazeEyesAssetName,
                            sampleDate: sampleDate, isEnabled: plays)
                .overlay { LookAccessoryOverlay(look: look, kind: .peek) }
        } else {
            LookArtworkView(look: look, kind: .peek, baseAssetName: base)
        }
    }

    private func imageAsset(look: MiloLook, elapsed: Double, reactionBlink: Bool) -> String {
        let base = look.companionAsset(for: expression)
        // A blink must use exactly the same head crop. Never substitute a full
        // body frame or change a customized character's materials to blink.
        guard expression != .still, look.hasStandardFace,
              (plays && MiloMotionPose.isBlinking(elapsed: elapsed)) || (reacting && reactionBlink) else { return base }
        let blink = look.characterPack.rawValue + (look.outfit == .classic ? "PeekBlink" : "FuturePeekBlink")
        return Self.installedBlinkAssets.contains(blink) ? blink : base
    }
    private static let installedBlinkAssets: Set<String> = Set(["MiloPeekBlink", "MiloFuturePeekBlink", "NovaPeekBlink", "NovaFuturePeekBlink"].filter { NSImage(named: $0) != nil })

    private func offerReaction() {
        reactions.offer(reactionEvent, isVisible: visible,
                        allowed: !policy.reduceMotion && expression != .still)
    }
}

/// One appearance editor for the original character, earlier packs, and photos.
/// Save is committed by its parent callback; cancelling discards the draft.
struct MiloCharacterEditor: View {
    let mate: Mate
    private let onSaveToken: (String) -> String?
    private let onCancel: (() -> Void)?
    private var supportsPacks = true
    @Environment(\.dismiss) private var dismiss
    @State private var look: MiloLook
    @State private var selectedToken: String
    @State private var section: EditorSection
    @State private var importingPhoto = false
    @State private var errorText: String?

    private enum EditorSection: String, CaseIterable {
        case customize = "Customize", packs = "Character packs"
    }

    init(mate: Mate, initialToken: String, onSave: @escaping (String) -> String?, onCancel: (() -> Void)? = nil) {
        self.mate = mate
        self.onSaveToken = onSave
        self.onCancel = onCancel
        let parsed = MiloLook(assetName: initialToken)
        _look = State(initialValue: parsed ?? .defaultLook)
        _selectedToken = State(initialValue: initialToken)
        _section = State(initialValue: parsed == nil ? .packs : .customize)
    }

    /// Compatibility for existing Milo-only callers while they migrate to tokens.
    init(name: String, initialLook: MiloLook, onSave: @escaping (MiloLook) -> Void) {
        self.init(mate: Self.previewMate(name: name), initialToken: initialLook.assetName, onSave: { token in
            if let look = MiloLook(assetName: token) { onSave(look) }
            return nil
        })
        supportsPacks = false
    }

    var body: some View {
        VStack(spacing: 0) {
            editorHeader
            Rectangle().fill(DS.Colors.borderSubtle).frame(height: 1)
            HStack(spacing: 0) {
                fixedPreview
                Rectangle().fill(DS.Colors.borderSubtle).frame(width: 1)
                VStack(spacing: 0) {
                    if supportsPacks {
                        Picker("Appearance options", selection: $section) {
                            ForEach(EditorSection.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.pickerStyle(.segmented).padding(22)
                    } else {
                        Text("Customize \(look.characterPack.label)").font(DS.Fonts.headline)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(22)
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            if section == .customize { customization } else { characterPacks }
                        }.padding(.horizontal, 24).padding(.bottom, 26)
                    }
                }.frame(maxWidth: .infinity)
            }
            if let errorText {
                Text(errorText).font(DS.Fonts.caption).foregroundStyle(DS.Colors.destructiveText)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.vertical, 12)
            }
        }
        .frame(width: 850, height: 680)
        .foregroundStyle(DS.Colors.textPrimary)
        .background(DS.Colors.background)
        .preferredColorScheme(.dark)
        .onChange(of: look) { _, updated in selectedToken = updated.assetName; errorText = nil }
        .onChange(of: section) { _, updated in
            if updated == .customize { selectedToken = look.assetName }
        }
        .fileImporter(isPresented: $importingPhoto, allowedContentTypes: [.image], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first, let token = MateFaceStore.importImage(from: url) else {
                    errorText = "That picture could not be saved."
                    return
                }
                selectedToken = token
                section = .packs
                errorText = nil
            case .failure:
                errorText = "That picture could not be opened."
            }
        }
    }

    private var editorHeader: some View {
        HStack {
            Button("Cancel") { onCancel?(); dismiss() }
                .buttonStyle(.plain).font(DS.Fonts.control)
                .foregroundStyle(DS.Colors.textSecondary)
                .padding(.horizontal, 15).padding(.vertical, 9)
                .background(DS.Colors.surface2, in: Capsule())
                .keyboardShortcut(.cancelAction)
            Spacer()
            VStack(spacing: 4) {
                Text("Edit appearance").font(DS.Fonts.headline)
                Text(mate.name).font(DS.Fonts.caption).foregroundStyle(DS.Colors.textSecondary)
            }
            Spacer()
            Button("Save appearance") {
                if let error = onSaveToken(selectedToken) { errorText = error } else { dismiss() }
            }.buttonStyle(.plain).font(DS.Fonts.control)
                .foregroundStyle(DS.Colors.glassInk)
                .padding(.horizontal, 17).padding(.vertical, 10)
                .background(DSGlassSurface(cornerRadius: 17))
                .keyboardShortcut(.defaultAction)
        }.padding(20)
    }

    private var fixedPreview: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 12)
            Group {
                if let selectedLook = MiloLook(assetName: selectedToken) {
                    LookArtworkView(look: selectedLook, kind: .body)
                        .accessibilityLabel(selectedLook.label)
                } else if let url = MateFaceStore.fileURL(for: selectedToken), let photo = NSImage(contentsOf: url) {
                    Image(nsImage: photo).resizable().interpolation(.high).scaledToFit()
                        .padding(24).accessibilityLabel("Your picture")
                } else {
                    Image(selectedToken).resizable().interpolation(.high).scaledToFit().padding(24)
                        .accessibilityLabel(MateFace.label(for: selectedToken))
                }
            }.frame(width: 300, height: 355)
            Text(mate.name).font(DS.Fonts.hero).lineLimit(2).multilineTextAlignment(.center)
            Text(MiloLook(assetName: selectedToken)?.outfit.label ?? (MateFaceStore.fileURL(for: selectedToken) == nil ? MateFace.label(for: selectedToken) : "Your picture"))
                .font(DS.Fonts.caption).foregroundStyle(DS.Colors.textSecondary)
            Button {
                look = .random(characterPack: look.characterPack)
                selectedToken = look.assetName
                section = .customize
                errorText = nil
            } label: {
                Label("Randomize character", systemImage: "dice")
                    .font(DS.Fonts.control).foregroundStyle(DS.Colors.textPrimary)
                    .padding(.horizontal, 17).padding(.vertical, 11)
                    .background(DS.Colors.surface2, in: Capsule())
                    .overlay(Capsule().stroke(DS.Colors.borderStrong, lineWidth: 1))
            }.buttonStyle(.plain).accessibilityLabel("Randomize \(look.characterPack.label)’s hair, colors, and outfit")
            Spacer(minLength: 18)
        }.padding(.horizontal, 18).frame(width: 340)
    }

    private var customization: some View {
        Group {
            if supportsPacks { packChoices }
            Text("Make \(look.characterPack.label) yours").font(DS.Fonts.headline)
            Text("Choose each detail. Your saved look follows your mate.")
                .font(DS.Fonts.caption).foregroundStyle(DS.Colors.textSecondary)
            VStack(alignment: .leading, spacing: 12) {
                Text("Hairstyle").font(DS.Fonts.headline)
                HStack(spacing: 12) {
                    ForEach(MiloLook.Hairstyle.allCases) { style in
                        let preview = MiloLook(characterPack: look.characterPack, hairstyle: style, hair: look.hair, skin: look.skin, eye: look.eye, outfit: look.outfit, hat: look.hat, eyewear: look.eyewear)
                        Button { look.hairstyle = style } label: {
                            VStack(spacing: 5) {
                                LookArtworkView(look: preview, kind: .head).frame(height: 90)
                                Text(look.hairstyleLabel(style)).font(DS.Fonts.caption)
                            }.frame(maxWidth: .infinity).padding(10)
                                .background(DS.Colors.surface1, in: RoundedRectangle(cornerRadius: 12))
                                .overlay(selection(look.hairstyle == style))
                        }.buttonStyle(.plain).accessibilityLabel(look.hairstyleLabel(style))
                            .accessibilityAddTraits(look.hairstyle == style ? .isSelected : [])
                    }
                }
            }
            swatches("Hair color", options: MiloLook.Hair.allCases, selected: $look.hair, label: { look.hairLabel($0) }, color: { look.hairColor($0) })
            swatches("Skin tone", options: MiloLook.Skin.allCases, selected: $look.skin, label: { $0.label }, color: { $0.color })
            swatches("Eye color", options: MiloLook.Eye.allCases, selected: $look.eye, label: { $0.label }, color: { $0.color })
            VStack(alignment: .leading, spacing: 12) {
                Text("Outfit").font(DS.Fonts.headline)
                HStack(spacing: 12) {
                    ForEach(MiloLook.Outfit.allCases) { outfit in
                        let preview = MiloLook(characterPack: look.characterPack, hairstyle: look.hairstyle, hair: look.hair, skin: look.skin, eye: look.eye, outfit: outfit, hat: look.hat, eyewear: look.eyewear)
                        Button { look.outfit = outfit } label: {
                            VStack(spacing: 5) {
                                LookArtworkView(look: preview, kind: .body).frame(height: 125)
                                Text(outfit.label).font(DS.Fonts.caption)
                            }.frame(maxWidth: .infinity).padding(10)
                                .background(DS.Colors.surface1, in: RoundedRectangle(cornerRadius: 12))
                                .overlay(selection(look.outfit == outfit))
                        }.buttonStyle(.plain).accessibilityLabel("Outfit: \(outfit.label)")
                            .accessibilityAddTraits(look.outfit == outfit ? .isSelected : [])
                    }
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("Hat").font(DS.Fonts.headline)
                HStack(spacing: 12) {
                    ForEach(MiloLook.Hat.allCases) { hat in
                        let preview = look.wearing(hat: hat)
                        accessoryTile(label: hat.label, preview: preview, selected: look.hat == hat) { look.hat = hat }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("Eyewear").font(DS.Fonts.headline)
                HStack(spacing: 12) {
                    ForEach(MiloLook.Eyewear.allCases) { eyewear in
                        let preview = look.wearing(eyewear: eyewear)
                        accessoryTile(label: eyewear.label, preview: preview, selected: look.eyewear == eyewear) { look.eyewear = eyewear }
                    }
                }
            }
            Text("Custom looks keep a neutral expression.")
                .font(DS.Fonts.caption).foregroundStyle(DS.Colors.textSecondary)
        }
    }

    private var characterPacks: some View {
        Group {
            packChoices
            Text("Your picture").font(DS.Fonts.headline)
            Text("Keep your own photo, or choose a new one. Existing saved pictures stay available.")
                .font(DS.Fonts.caption).foregroundStyle(DS.Colors.textSecondary)
            Button { importingPhoto = true } label: {
                Label("Choose photo…", systemImage: "photo")
                    .font(DS.Fonts.control).foregroundStyle(DS.Colors.textPrimary)
                    .frame(maxWidth: .infinity).padding(15)
                    .background(DS.Colors.surface1, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(DS.Colors.borderStrong, lineWidth: 1))
            }.buttonStyle(.plain)
            if MateFaceStore.fileURL(for: selectedToken) != nil {
                Label("Your picture is selected", systemImage: "checkmark.circle.fill")
                    .font(DS.Fonts.caption).foregroundStyle(DS.Colors.accentText)
            }
        }
    }

    private var packChoices: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Character pack").font(DS.Fonts.headline)
            HStack(spacing: 12) {
                ForEach(MiloLook.CharacterPack.allCases) { pack in
                    let preview = MiloLook(characterPack: pack, hairstyle: look.hairstyle, hair: look.hair, skin: look.skin, eye: look.eye, outfit: look.outfit, hat: look.hat, eyewear: look.eyewear)
                    Button {
                        look = preview
                        selectedToken = preview.assetName
                        section = .customize
                        errorText = nil
                    } label: {
                        VStack(spacing: 8) {
                            LookArtworkView(look: preview, kind: .body).frame(height: 145)
                            Text(pack.label).font(DS.Fonts.headline)
                            Text(pack.summary).font(DS.Fonts.caption).foregroundStyle(DS.Colors.textSecondary)
                                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                        }.frame(maxWidth: .infinity).padding(12)
                            .background(DS.Colors.surface1, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(selection(MiloLook(assetName: selectedToken)?.characterPack == pack))
                    }.buttonStyle(.plain).accessibilityLabel("Choose \(pack.label) character pack")
                        .accessibilityAddTraits(MiloLook(assetName: selectedToken)?.characterPack == pack ? .isSelected : [])
                }
            }
        }
    }

    private static func previewMate(name: String) -> Mate {
        Mate(id: UUID(), name: name, job: "", pinned: false, archived: false, unreadCount: 0,
             createdAt: .distantPast, updatedAt: .distantPast, memoryNote: "")
    }

    private func accessoryTile(label: String, preview: MiloLook, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                LookArtworkView(look: preview, kind: .head).frame(height: 88)
                Text(label).font(DS.Fonts.caption)
            }.frame(maxWidth: .infinity).padding(10)
                .background(DS.Colors.surface1, in: RoundedRectangle(cornerRadius: 12))
                .overlay(selection(selected))
        }.buttonStyle(.plain).accessibilityLabel(label)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func selection(_ selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 12).stroke(selected ? DS.Colors.accent : DS.Colors.borderSubtle, lineWidth: selected ? 2 : 1)
            .overlay(alignment: .topTrailing) {
                if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(DS.Colors.accent).padding(6) }
            }
    }

    private func swatches<Option: Hashable>(_ title: String, options: [Option], selected: Binding<Option>, label: @escaping (Option) -> String, color: @escaping (Option) -> Color) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(DS.Fonts.headline)
            HStack(spacing: 10) {
                ForEach(options, id: \.self) { option in
                    Button { selected.wrappedValue = option } label: {
                        VStack(spacing: 8) {
                            Circle().fill(color(option)).frame(width: 30, height: 30)
                            Text(label(option)).font(DS.Fonts.caption)
                        }.frame(maxWidth: .infinity).padding(.vertical, 13)
                            .background(DS.Colors.surface1, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(selection(selected.wrappedValue == option))
                    }.buttonStyle(.plain).accessibilityLabel("\(title): \(label(option))")
                        .accessibilityAddTraits(selected.wrappedValue == option ? .isSelected : [])
                }
            }
        }
    }
}
