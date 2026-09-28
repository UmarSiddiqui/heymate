//
//  MateSettingsSheet.swift
//  leanring-buddy
//
//  Picture, details, and soul for one mate.
//

import SwiftUI
import UniformTypeIdentifiers

struct MateSettingsSheet: View {
    let mate: Mate
    var isLastNonArchivedMate: Bool
    var onSave: (String, String, String, String?) -> String?
    var onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var job: String
    @State private var soul: String
    @State private var selectedFace: String
    @State private var isImportingPicture = false
    @State private var isConfirmingDelete = false
    @State private var errorText: String?

    init(
        mate: Mate,
        isLastNonArchivedMate: Bool,
        onSave: @escaping (String, String, String, String?) -> String?,
        onDelete: @escaping () -> Void
    ) {
        self.mate = mate
        self.isLastNonArchivedMate = isLastNonArchivedMate
        self.onSave = onSave
        self.onDelete = onDelete
        _name = State(initialValue: mate.name)
        _job = State(initialValue: mate.job)
        _soul = State(initialValue: mate.soul)
        _selectedFace = State(initialValue: MateFace.selectionToken(for: mate))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit \(mate.name)")
                .font(DS.Fonts.hero)
                .foregroundColor(DS.Colors.textPrimary)

            sectionLabel("Picture")
            if MateFaceStore.fileURL(for: selectedFace) != nil {
                HStack(spacing: 10) {
                    MateFaceView(mate: preview(selectedFace), size: 40)
                        .overlay {
                            Circle().stroke(DS.Colors.textPrimary, lineWidth: 2)
                        }
                    Text("Your picture")
                        .font(DS.Fonts.headline)
                        .foregroundColor(DS.Colors.textPrimary)
                }
            }
            ScrollView {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(44), spacing: 8), count: 6),
                    spacing: 8
                ) {
                    ForEach(MateFace.assetNames, id: \.self) { asset in
                        Button {
                            selectedFace = asset
                        } label: {
                            MateFaceView(mate: preview(asset), size: 40)
                                .overlay {
                                    Circle().stroke(
                                        selectedFace == asset ? DS.Colors.textPrimary : Color.clear,
                                        lineWidth: 2
                                    )
                                }
                        }
                        .buttonStyle(.plain)
                        .pointerCursor()
                        .accessibilityLabel("Choose this picture")
                    }
                }
            }
            .frame(maxHeight: 200)
            Button("Use your own picture") { isImportingPicture = true }
                .buttonStyle(.plain)
                .font(DS.Fonts.headline)
                .foregroundColor(DS.Colors.textSecondary)
                .pointerCursor()

            sectionLabel("Details")
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
            TextField("Job, in one sentence", text: $job)
                .textFieldStyle(.roundedBorder)

            sectionLabel("Soul")
            TextField("How this mate sounds and behaves", text: $soul, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...6)

            if let errorText {
                Text(errorText)
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.destructiveText)
            }

            HStack {
                Button("Delete", role: .destructive) { isConfirmingDelete = true }
                    .foregroundColor(DS.Colors.destructiveText)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .confirmationDialog(
            "Delete \(mate.name)?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                onDelete()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(Mate.deletionWarning(replacesWithFreshHeyMate: isLastNonArchivedMate))
        }
        .fileImporter(
            isPresented: $isImportingPicture,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first, let token = MateFaceStore.importImage(from: url) else {
                    errorText = "That picture could not be saved."
                    return
                }
                selectedFace = token
                errorText = nil
            case .failure:
                errorText = "That picture could not be opened."
            }
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(DS.Fonts.sectionLabel)
            .foregroundColor(DS.Colors.textTertiary)
    }

    private func preview(_ asset: String) -> Mate {
        var copy = mate
        copy.faceAssetName = asset
        return copy
    }

    private func save() {
        if let error = onSave(name, job, soul, selectedFace) {
            errorText = error
            return
        }
        dismiss()
    }
}
