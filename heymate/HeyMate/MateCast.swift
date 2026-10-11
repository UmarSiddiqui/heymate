//
//  MateCast.swift
//  HeyMate
//
//  A short local interview that proposes three mates from one pack.
//  No model call. The person edits them afterward.
//

import SwiftUI

struct MateCastAnswers: Equatable {
    var skill: String
    var style: String
    var project: String
    var packID: String
}

struct MateCastProposal: Equatable, Identifiable {
    var id: String { name }
    let name: String
    let job: String
    let soul: String
    let faceAssetName: String
    let faceTint: String
    let faceHair: String
    let faceOutfit: String
}

enum MateCast {
    static func shouldOffer(hasCompletedOnboarding: Bool, activeMateCount: Int, alreadyOffered: Bool) -> Bool {
        hasCompletedOnboarding && activeMateCount <= 1 && !alreadyOffered
    }

    static func proposals(from answers: MateCastAnswers, existingNames: [String]) -> [MateCastProposal] {
        let skill = cleaned(answers.skill, fallback: "the software I'm learning")
        let style = cleaned(answers.style, fallback: "patient and specific")
        let project = cleaned(answers.project, fallback: "what I'm working on")
        let pack = MateFace.packs.first { $0.id == answers.packID } ?? MateFace.packs[0]
        let faces = pack.faces.map(\.assetName)
        guard !faces.isEmpty else { return [] }

        let roles: [(job: String, soul: String, hair: String, outfit: String)] = [
            (
                "Teach me \(skill), one step at a time",
                "You teach \(skill). \(style). Wait while I try each step.",
                MateFaceHair.tuft.rawValue,
                MateFaceOutfit.collar.rawValue
            ),
            (
                "Check my work on \(skill) and tell me what I missed",
                "You review \(skill). \(style). Point at the exact thing to fix.",
                MateFaceHair.band.rawValue,
                MateFaceOutfit.scarf.rawValue
            ),
            (
                "Keep \(project) moving and remember where we left off",
                "You stay with \(project). \(style). Pick up from the last step.",
                MateFaceHair.hood.rawValue,
                MateFaceOutfit.collar.rawValue
            )
        ]

        var names = existingNames
        return roles.enumerated().map { index, role in
            let name = MateNameGenerator.name(for: role.job, existingNames: names)
            names.append(name)
            let tint = MateFace.tintSwatches[index % MateFace.tintSwatches.count]
            let face = faces[index % faces.count]
            return MateCastProposal(
                name: name,
                job: role.job,
                soul: role.soul,
                faceAssetName: face,
                faceTint: tint,
                faceHair: role.hair,
                faceOutfit: role.outfit
            )
        }
    }

    private static func cleaned(_ text: String, fallback: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}

struct MateCastSheet: View {
    var existingNames: [String]
    var onCreate: ([MateCastProposal]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var skill = ""
    @State private var style = ""
    @State private var project = ""
    @State private var packID = MateFace.packs[0].id
    @State private var proposals: [MateCastProposal] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(proposals.isEmpty ? "Meet a cast" : "Three agents for you")
                .font(DS.Fonts.hero)
                .foregroundColor(DS.Colors.textPrimary)
            if proposals.isEmpty {
                questions
            } else {
                reveal
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var questions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Four short answers. HeyMate makes three agents from them. You can change each one after.")
                .font(DS.Fonts.body)
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            field("What should they be good at?", text: $skill)
            field("How do you like to be helped?", text: $style)
            field("What are you working on now?", text: $project)
            Text("Starting look")
                .font(DS.Fonts.sectionLabel)
                .foregroundColor(DS.Colors.textTertiary)
            ForEach(MateFace.packs.filter { $0.id != "original" }) { pack in
                Button {
                    packID = pack.id
                } label: {
                    HStack(spacing: 8) {
                        ForEach(pack.faces.prefix(3)) { face in
                            MateFaceView(mate: preview(face.assetName), size: 28)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pack.name)
                                .font(DS.Fonts.headline)
                                .foregroundColor(DS.Colors.textPrimary)
                            Text(pack.summary)
                                .font(DS.Fonts.caption)
                                .foregroundColor(DS.Colors.textTertiary)
                        }
                        Spacer()
                        if packID == pack.id {
                            Image(systemName: "checkmark")
                                .foregroundColor(DS.Colors.accent)
                        }
                    }
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .fill(packID == pack.id ? DS.Colors.surface3 : DS.Colors.surface2)
                    )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
            HStack {
                Button("Not now") { dismiss() }
                Spacer()
                Button("Show them") { revealCast() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var reveal: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(proposals) { proposal in
                HStack(spacing: 10) {
                    MateFaceView(mate: preview(proposal), size: 44, expression: .idle)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(proposal.name)
                            .font(DS.Fonts.headline)
                            .foregroundColor(DS.Colors.textPrimary)
                        Text(proposal.job)
                            .font(DS.Fonts.caption)
                            .foregroundColor(DS.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            HStack {
                Button("Change answers") { proposals = [] }
                Spacer()
                Button("Add them") {
                    onCreate(proposals)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(DS.Fonts.sectionLabel)
                .foregroundColor(DS.Colors.textTertiary)
            TextField(title, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func revealCast() {
        proposals = MateCast.proposals(
            from: MateCastAnswers(skill: skill, style: style, project: project, packID: packID),
            existingNames: existingNames
        )
    }

    private func preview(_ asset: String) -> Mate {
        var mate = Mate(
            id: UUID(),
            name: "Preview",
            job: "Preview",
            pinned: false,
            archived: false,
            unreadCount: 0,
            createdAt: Date(),
            updatedAt: Date(),
            memoryNote: ""
        )
        mate.faceAssetName = asset
        return mate
    }

    private func preview(_ proposal: MateCastProposal) -> Mate {
        var mate = preview(proposal.faceAssetName)
        mate.faceTint = proposal.faceTint
        mate.faceHair = proposal.faceHair
        mate.faceOutfit = proposal.faceOutfit
        return mate
    }
}
