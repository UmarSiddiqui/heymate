//
//  ChatHistoryPanel.swift
//  leanring-buddy
//
//  Past chats for the active mate. Opening a row uses openChat for that
//  session. Search hits do the same.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ChatHistoryPanel: View {
    @ObservedObject var companionManager: CompanionManager
    var onClose: () -> Void

    @State private var searchText = ""
    @State private var trimNotice: String?
    @State private var pendingConfirm: PendingConfirm?
    @State private var exportDocument = ChatPlainTextDocument(text: "")
    @State private var exportFilename = "Chat"
    @State private var isExportingFile = false

    private var sessions: [ChatSession] {
        companionManager.chatsForActiveMate()
    }

    private var visibleSessions: [ChatSession] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sessions }
        return sessions.filter { session in
            session.title.localizedStandardContains(query)
                || session.messages.contains { $0.text.localizedStandardContains(query) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            header
            if let trimNotice {
                Text(trimNotice)
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.warningText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField("Search messages", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .font(DS.Fonts.body)
            sessionList
            footer
        }
        .padding(DS.Spacing.lg)
        .frame(minWidth: 340, idealWidth: 380, minHeight: 420, alignment: .topLeading)
        .background(DS.Colors.background)
        .onAppear {
            if let notice = companionManager.chatTrimNotice() {
                trimNotice = notice
            }
        }
        .confirmationDialog(
            confirmTitle,
            isPresented: Binding(
                get: { pendingConfirm != nil },
                set: { isPresented in
                    if !isPresented { pendingConfirm = nil }
                }
            ),
            titleVisibility: .visible
        ) {
            Button(confirmButtonTitle, role: .destructive) {
                performConfirm()
            }
            Button("Cancel", role: .cancel) {
                pendingConfirm = nil
            }
        }
        .fileExporter(
            isPresented: $isExportingFile,
            document: exportDocument,
            contentType: .plainText,
            defaultFilename: exportFilename
        ) { _ in }
    }

    private var header: some View {
        HStack {
            Text("Chats")
                .font(DS.Fonts.title)
                .foregroundColor(DS.Colors.textPrimary)
            Spacer()
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
            }
            .dsIconButtonStyle(size: 28, tooltip: "Close")
            .accessibilityLabel("Close")
        }
    }

    @ViewBuilder
    private var sessionList: some View {
        if sessions.isEmpty {
            Text("No saved chats yet.")
                .font(DS.Fonts.body)
                .foregroundColor(DS.Colors.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } else if visibleSessions.isEmpty {
            Text("No matching chats.")
                .font(DS.Fonts.body)
                .foregroundColor(DS.Colors.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    ForEach(visibleSessions) { session in
                        sessionRow(session)
                    }
                }
            }
        }
    }

    private func sessionRow(_ session: ChatSession) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(session.title)
                    .font(DS.Fonts.headline)
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: DS.Spacing.sm)
                Text(session.updatedAt.formatted(.relative(presentation: .named)))
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(1)
            }
            HStack(spacing: DS.Spacing.md) {
                rowButton("Open", color: DS.Colors.textPrimary) {
                    openSession(session)
                }
                rowButton("Export", color: DS.Colors.textSecondary) {
                    copySession(session)
                }
                rowButton("Save…", color: DS.Colors.textSecondary) {
                    beginSave(session)
                }
                rowButton("Delete", color: DS.Colors.destructiveText) {
                    pendingConfirm = .deleteOne(session.id)
                }
            }
        }
        .padding(DS.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Colors.surface1)
        .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous))
    }

    private func rowButton(_ title: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(DS.Fonts.caption)
            .foregroundColor(color)
            .pointerCursor()
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Text("HeyMate keeps the latest 40 chats.")
                .font(DS.Fonts.caption)
                .foregroundColor(DS.Colors.textTertiary)
            HStack(spacing: DS.Spacing.md) {
                rowButton("Delete all chats for this mate", color: DS.Colors.destructiveText) {
                    pendingConfirm = .deleteMate
                }
                rowButton("Delete all chats", color: DS.Colors.destructiveText) {
                    pendingConfirm = .deleteAll
                }
            }
        }
    }

    private var confirmTitle: String {
        switch pendingConfirm {
        case .deleteOne:
            return "Delete this chat?"
        case .deleteMate:
            return "Delete all chats for this mate?"
        case .deleteAll:
            return "Delete all chats?"
        case nil:
            return ""
        }
    }

    private var confirmButtonTitle: String {
        switch pendingConfirm {
        case .deleteOne:
            return "Delete"
        case .deleteMate:
            return "Delete all chats for this mate"
        case .deleteAll:
            return "Delete all chats"
        case nil:
            return "Delete"
        }
    }

    private func performConfirm() {
        switch pendingConfirm {
        case .deleteOne(let id):
            companionManager.deleteChat(id: id)
        case .deleteMate:
            let mateID = companionManager.activeMateID ?? companionManager.mateDirectory.defaultMateID
            companionManager.clearChats(forMateID: mateID)
        case .deleteAll:
            companionManager.clearAllChats()
        case nil:
            break
        }
        pendingConfirm = nil
    }

    /// Opens this session. Search results use the same path, not openMate.
    private func openSession(_ session: ChatSession) {
        companionManager.openChat(id: session.id)
        onClose()
    }

    private func copySession(_ session: ChatSession) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(session.exportPlainText(), forType: .string)
    }

    private func beginSave(_ session: ChatSession) {
        exportDocument = ChatPlainTextDocument(text: session.exportPlainText())
        exportFilename = Self.exportFileName(for: session.title)
        isExportingFile = true
    }

    private static func exportFileName(for title: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>")
            .union(.newlines)
            .union(.controlCharacters)
        let scalars = title.unicodeScalars.filter { !forbidden.contains($0) }
        let cleaned = String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty { return "Chat" }
        return String(cleaned.prefix(60))
    }
}

nonisolated private enum PendingConfirm: Equatable {
    case deleteOne(UUID)
    case deleteMate
    case deleteAll
}

nonisolated private struct ChatPlainTextDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        text = String(decoding: data, as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
