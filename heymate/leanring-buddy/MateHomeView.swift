//
//  MateHomeView.swift
//  leanring-buddy
//
//  The chat application. Desktop fills the window with a mate rail and a
//  conversation. The notch uses the same view in a compact layout.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MateHomeView: View {
    @ObservedObject var companionManager: CompanionManager
    var isCompactLayout: Bool
    var onOpenSection: (DesktopSection) -> Void
    var onClose: (() -> Void)? = nil
    var shouldFocusComposerOnAppear: Bool = false

    @State private var searchText = ""
    @State private var hoveredRailMateID: UUID?
    @State private var isDrawerOpen = false
    @State private var isShowingNewMate = false
    @State private var typedMessageInput = ""
    @State private var imageAttachments: [ChatImageAttachment] = []
    @State private var isShowingImageImporter = false
    @State private var attachmentErrorText: String?
    @State private var isImageDropTargeted = false
    @State private var isShowingComposerOverflow = false
    @State private var isNearBottom = true
    @State private var viewportHeight: CGFloat = 0
    @State private var extraRevealed = 0
    @State private var previewedFilePath: String?
    @State private var isHoldingTalk = false
    @State private var settingsMate: Mate?
    @State private var isShowingChatHistory = false
    @State private var matePendingDelete: Mate?
    @State private var matePendingArchive: Mate?
    @State private var filePendingDelete: String?
    @State private var isConfirmingFolderRemoval = false
    @State private var filesActionError: String?
    @FocusState private var isComposerFocused: Bool

    private var columns: [MateHomeColumn] {
        MateHomeLayout.visibleColumns(isCompact: isCompactLayout, isDrawerOpen: isDrawerOpen)
    }

    private var activeMate: Mate? {
        let activeID = companionManager.activeMateID ?? companionManager.mateDirectory.defaultMateID
        return companionManager.mates.first { $0.id == activeID }
    }

    var body: some View {
        HStack(spacing: 0) {
            if columns.contains(.rail) {
                mateRail
                    .frame(width: MateHomeLayout.railWidth)
                Rectangle().fill(DS.Colors.borderSubtle).frame(width: 1)
            }
            conversation
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if columns.contains(.drawer) {
                Rectangle().fill(DS.Colors.borderSubtle).frame(width: 1)
                mateDrawer
                    .frame(width: MateHomeLayout.drawerWidth)
            }
        }
        .background(CelestialAtmosphere())
        .sheet(isPresented: $isShowingNewMate) {
            NewMateSheet { name, job in
                companionManager.createMate(name: name, job: job) != nil
            }
        }
        .sheet(item: $settingsMate) { mate in
            MateSettingsSheet(
                mate: mate,
                companionManager: companionManager,
                isLastNonArchivedMate: deletionReplacesWithFreshHeyMate(mate),
                onOpenSection: onOpenSection,
                onSave: { name, job, soul, face in
                    companionManager.updateMateProfile(
                        id: mate.id,
                        name: name,
                        job: job,
                        soul: soul,
                        faceAssetName: face
                    )
                },
                onDelete: {
                    companionManager.deleteMate(id: mate.id)
                }
            )
        }
        .sheet(isPresented: $isShowingChatHistory) {
            ChatHistoryPanel(companionManager: companionManager, onClose: {
                isShowingChatHistory = false
            })
        }
        .sheet(isPresented: compactDrawerPresented) {
            mateDrawer
                .frame(minWidth: 320, minHeight: 420)
                .confirmationDialog(
                    "Delete \(matePendingDelete?.name ?? "this mate")?",
                    isPresented: sheetDeleteDialogPresented,
                    titleVisibility: .visible
                ) {
                    Button("Delete", role: .destructive) { confirmDeleteMate() }
                    Button("Cancel", role: .cancel) { matePendingDelete = nil }
                } message: {
                    Text(pendingDeletionWarning)
                }
        }
        .fileImporter(
            isPresented: $isShowingImageImporter,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true,
            onCompletion: handleImageImport
        )
        .onAppear {
            typedMessageInput = companionManager.currentChat.draftText ?? ""
            guard shouldFocusComposerOnAppear else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
                isComposerFocused = true
            }
        }
        .onDisappear {
            companionManager.updateCurrentDraft(typedMessageInput)
        }
        .onChange(of: companionManager.currentChat.id) { _, _ in
            typedMessageInput = companionManager.currentChat.draftText ?? ""
            isNearBottom = true
        }
        .onChange(of: typedMessageInput) { _, newValue in
            companionManager.updateCurrentDraft(newValue)
        }
        #if canImport(ImagePlayground)
        .modifier(ImagePlaygroundGate(concept: $companionManager.imagePlaygroundConcept) { url in
            companionManager.adoptImagePlaygroundFile(at: url)
        })
        #endif
        .confirmationDialog(
            "Delete \(matePendingDelete?.name ?? "this mate")?",
            isPresented: rootDeleteDialogPresented,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { confirmDeleteMate() }
            Button("Cancel", role: .cancel) { matePendingDelete = nil }
        } message: {
            Text(pendingDeletionWarning)
        }
        .confirmationDialog(
            "Archive \(matePendingArchive?.name ?? "this mate")?",
            isPresented: archiveDialogPresented,
            titleVisibility: .visible
        ) {
            Button("Archive") {
                if let mate = matePendingArchive {
                    companionManager.archiveMate(id: mate.id)
                }
                matePendingArchive = nil
            }
            Button("Cancel", role: .cancel) { matePendingArchive = nil }
        } message: {
            Text("They leave the main list. You can unarchive them from Archived.")
        }
    }

    private var compactDrawerPresented: Binding<Bool> {
        Binding(
            get: { isCompactLayout && isDrawerOpen },
            set: { isDrawerOpen = $0 }
        )
    }

    // MARK: Rail

    private var mateRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(DS.Glyph.small)
                    .foregroundColor(DS.Colors.textTertiary)
                TextField("Search mates", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(DS.Fonts.bodyLarge)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(DS.Colors.surface2.opacity(0.7))
            .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Button {
                isShowingNewMate = true
            } label: {
                Label("New mate", systemImage: "plus")
                    .font(DS.Fonts.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .frame(height: 32)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .padding(.horizontal, 8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if !rail.pinned.isEmpty {
                        railHeader("Pinned")
                        ForEach(rail.pinned) { mate in
                            mateRow(mate)
                        }
                    }
                    if showsActiveMateHeader {
                        railHeader(searchText.isEmpty ? "Mates" : "Results")
                    }
                    if rail.others.isEmpty && rail.pinned.isEmpty && (archivedRail.isEmpty || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                        Text(searchText.isEmpty ? "New mates show up here." : "No mates match that.")
                            .font(DS.Fonts.caption)
                            .foregroundColor(DS.Colors.textTertiary)
                            .padding(.horizontal, 12)
                            .padding(.top, 6)
                    }
                    ForEach(rail.others) { mate in
                        mateRow(mate)
                    }
                    if !archivedRail.isEmpty {
                        railHeader("Archived")
                        ForEach(archivedRail) { mate in
                            mateRow(mate)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 12)
                .padding(.bottom, 8)
            }

            Divider().overlay(DS.Colors.borderSubtle)
            HStack {
                Menu {
                    ForEach(MateHomeLayout.workspaceSections) { section in
                        Button {
                            onOpenSection(section)
                        } label: {
                            Label(section.displayName, systemImage: section.symbolName)
                        }
                    }
                } label: {
                    Image(systemName: "gearshape")
                        .font(DS.Glyph.regular)
                        .foregroundColor(DS.Colors.textSecondary)
                        .frame(width: 28, height: 28)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 36)
                .help("Apps and settings")
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(DS.Colors.surface1.opacity(0.9))
    }

    private var rail: (pinned: [Mate], others: [Mate]) {
        MateRailOrder.split(
            mates: companionManager.mates,
            sessions: companionManager.savedChats,
            query: searchText,
            defaultMateID: companionManager.mateDirectory.defaultMateID
        )
    }

    private var archivedRail: [Mate] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty else { return [] }
        return companionManager.mates
            .filter(\.archived)
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private var showsActiveMateHeader: Bool {
        if !rail.pinned.isEmpty || !rail.others.isEmpty { return true }
        let searching = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if !archivedRail.isEmpty && !searching { return false }
        return true
    }

    private func railHeader(_ title: String) -> some View {
        Text(title)
            .font(DS.Fonts.sectionLabel)
            .foregroundColor(DS.Colors.textTertiary)
            .padding(.horizontal, 8)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }

    private func mateRow(_ mate: Mate) -> some View {
        let selected = mate.id == (companionManager.activeMateID ?? companionManager.mateDirectory.defaultMateID)
        let presence = MateHomeLayout.presence(
            for: mate.id,
            routines: companionManager.routines,
            isWorking: isMateWorking(mate)
        )
        return HStack(alignment: .center, spacing: 8) {
            Button {
                beginMateSettings(mate)
            } label: {
                MateFaceView(mate: mate, size: 28)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Edit picture, details, and soul")
            VStack(alignment: .leading, spacing: 2) {
                Button {
                    beginMateSettings(mate)
                } label: {
                    Text(mate.name)
                        .font(DS.Fonts.headline)
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("Edit picture, details, and soul")
                // Buttons, not tap gestures: a tap gesture in an inactive
                // window ignores the click that activates it, so opening a
                // mate took two clicks whenever another app was in front.
                Button {
                    openMateFromRow(mate)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(mate.job)
                            .font(DS.Fonts.body)
                            .foregroundColor(DS.Colors.textSecondary)
                            .lineLimit(1)
                        Text(presence.label)
                            .font(DS.Fonts.caption.weight(.medium))
                            .foregroundColor(presence == .working ? DS.Colors.warningText : DS.Colors.textTertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(mate.name)")
            }
            .layoutPriority(1)
            Button {
                openMateFromRow(mate)
            } label: {
                Color.clear
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHidden(true)
            if mate.archived {
                Button("Unarchive") {
                    companionManager.unarchiveMate(id: mate.id)
                }
                .dsCapsuleButtonStyle(.quiet, height: DS.ControlSize.small)
            }
            // Row tools appear on hover only, so names and jobs get the
            // rail's full width the rest of the time.
            if hoveredRailMateID == mate.id {
                mateRailControl(
                    mate.pinned ? "Unpin" : "Pin",
                    systemImage: mate.pinned ? "pin.fill" : "pin"
                ) {
                    companionManager.toggleMatePinned(id: mate.id)
                }
                mateRailControl(
                    mate.unreadCount > 0 ? "Mark as Read" : "Mark as Unread",
                    systemImage: mate.unreadCount > 0 ? "envelope.open" : "envelope"
                ) {
                    if mate.unreadCount > 0 {
                        companionManager.markMateRead(id: mate.id)
                    } else {
                        companionManager.markMateUnread(id: mate.id)
                    }
                }
            }
            if mate.unreadCount > 0 {
                Text("\(mate.unreadCount)")
                    .font(DS.Fonts.caption.weight(.semibold))
                    .foregroundColor(DS.Colors.textOnAccent)
                    .padding(.horizontal, 6)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(Capsule().fill(companionManager.themeColor))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .fill(
                    selected
                        ? DS.Colors.surface3
                        : (hoveredRailMateID == mate.id ? DS.Colors.surface2 : Color.clear)
                )
        )
        .onHover { isHovering in
            if isHovering {
                hoveredRailMateID = mate.id
            } else if hoveredRailMateID == mate.id {
                hoveredRailMateID = nil
            }
        }
        .contextMenu {
            Button("Edit") { beginMateSettings(mate) }
            Button(mate.pinned ? "Unpin" : "Pin") {
                companionManager.toggleMatePinned(id: mate.id)
            }
            if mate.archived {
                Button("Unarchive") { companionManager.unarchiveMate(id: mate.id) }
            } else if !mate.conductsOthers {
                Button("Archive") { matePendingArchive = mate }
            }
            Button("Mark as Unread") { companionManager.markMateUnread(id: mate.id) }
            Button("Mark as Read") { companionManager.markMateRead(id: mate.id) }
            Button("Delete", role: .destructive) { matePendingDelete = mate }
        }
    }

    private func mateRailControl(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(DS.Glyph.small)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .foregroundColor(DS.Colors.textTertiary)
        .pointerCursor()
        .help(title)
        .accessibilityLabel(title)
    }

    private func openMateFromRow(_ mate: Mate) {
        if NSEvent.modifierFlags.contains(.shift) {
            companionManager.toggleMatePinned(id: mate.id)
        } else {
            companionManager.openMate(id: mate.id)
        }
    }

    private func beginMateSettings(_ mate: Mate) {
        settingsMate = mate
    }

    private func editableMateIdentity(size: CGFloat, nameFont: Font, nameColor: Color) -> some View {
        HStack(spacing: 8) {
            if let mate = activeMate {
                Button {
                    beginMateSettings(mate)
                } label: {
                    MateFaceView(mate: mate, size: size)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("Edit picture, details, and soul")
                Button {
                    beginMateSettings(mate)
                } label: {
                    Text(mate.name)
                        .font(nameFont)
                        .foregroundColor(nameColor)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("Edit picture, details, and soul")
            }
        }
    }

    private func isMateWorking(_ mate: Mate) -> Bool {
        guard mate.id == companionManager.activeMateID else { return false }
        if !companionManager.streamingAssistantText.isEmpty { return true }
        switch companionManager.state {
        case .thinking, .capturingContext, .speaking, .finalizingTranscript:
            return true
        default:
            return false
        }
    }

    // MARK: Conversation

    private var conversation: some View {
        VStack(spacing: 0) {
            conversationHeader
            transcript
            mateJobsStrip
            composer
                .padding(.horizontal, isCompactLayout ? 12 : 20)
                .padding(.bottom, isCompactLayout ? 10 : 16)
        }
        .dropDestination(for: URL.self) { urls, _ in
            addImageFiles(urls)
            return true
        } isTargeted: { isImageDropTargeted = $0 }
    }

    private var conversationHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            headerTitles
            if isCompactLayout {
                Menu {
                    ForEach(companionManager.mates.filter { !$0.archived }) { mate in
                        Button(mate.name) { companionManager.openMate(id: mate.id) }
                    }
                    Divider()
                    Button("New mate") { isShowingNewMate = true }
                    if let mate = activeMate {
                        Divider()
                        if mate.archived {
                            Button("Unarchive") { companionManager.unarchiveMate(id: mate.id) }
                        } else if !mate.conductsOthers {
                            Button("Archive") { matePendingArchive = mate }
                        }
                        Button("Delete", role: .destructive) { matePendingDelete = mate }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(DS.Glyph.small)
                        .frame(width: 22, height: 22)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 28)
                .help("Switch mate")
            }
            Spacer(minLength: 8)
            jobsButton
            Button {
                isShowingChatHistory = true
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(DS.Glyph.regular)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Chat history")
            Button {
                companionManager.startNewChat()
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(DS.Glyph.regular)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .keyboardShortcut("n", modifiers: .command)
            .help("New chat")
            Button {
                isDrawerOpen.toggle()
            } label: {
                Image(systemName: "sidebar.right")
                    .font(DS.Glyph.regular)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                            .fill(isDrawerOpen ? DS.Colors.surface3 : Color.clear)
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help(isDrawerOpen ? "Hide mate details" : "Mate details")
            if isCompactLayout {
                Menu {
                    ForEach(MateHomeLayout.workspaceSections) { section in
                        Button(section.displayName) { onOpenSection(section) }
                    }
                } label: {
                    Image(systemName: "gearshape")
                        .font(DS.Glyph.regular)
                        .frame(width: 28, height: 28)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 32)
            }
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "chevron.up")
                        .font(DS.Glyph.small)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("Collapse")
            }
        }
        .foregroundColor(DS.Colors.textSecondary)
        .padding(.horizontal, isCompactLayout ? 12 : 22)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(DS.Colors.borderSubtle).frame(height: 1)
        }
    }

    /// The way into Jobs: the work mates are doing over time. The count is
    /// everything still running or waiting on you, across all mates, and it
    /// turns amber when something is blocked on your approval.
    private var jobsButton: some View {
        let runs = companionManager.agentRuns
        let activeCount = MateJobs.activeCount(in: runs)
        let needsYou = MateJobs.needsYouCount(in: runs) > 0
        return Button {
            onOpenSection(.agents)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: DesktopSection.agents.symbolName)
                    .font(DS.Glyph.regular)
                if !isCompactLayout {
                    Text("Jobs")
                        .font(DS.Fonts.control)
                }
                if activeCount > 0 {
                    Text("\(activeCount)")
                        .font(DS.Fonts.caption.weight(.semibold))
                        .foregroundColor(needsYou ? DS.Colors.warningText : DS.Colors.textSecondary)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(
                            Capsule().fill(needsYou ? DS.Colors.warning.opacity(0.18) : DS.Colors.surface3)
                        )
                }
            }
            .padding(.horizontal, isCompactLayout ? 4 : 8)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(jobsHelp(activeCount: activeCount, needsYou: needsYou))
        .accessibilityLabel(jobsHelp(activeCount: activeCount, needsYou: needsYou))
    }

    private func jobsHelp(activeCount: Int, needsYou: Bool) -> String {
        if needsYou { return "Jobs: something needs your approval" }
        if activeCount > 0 { return "Jobs: \(activeCount) in progress" }
        return "Jobs: work your mates do over time"
    }

    private var headerTitles: some View {
        HStack(spacing: 10) {
            if let mate = activeMate {
                Button {
                    beginMateSettings(mate)
                } label: {
                    MateFaceView(mate: mate, size: isCompactLayout ? 28 : 36)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("Edit picture, details, and soul")
            }
            VStack(alignment: .leading, spacing: 2) {
                Button {
                    if let mate = activeMate { beginMateSettings(mate) }
                } label: {
                    HStack(spacing: 6) {
                        Text(activeMate?.name ?? Mate.defaultName)
                            .font(isCompactLayout ? DS.Fonts.title : DS.Fonts.hero)
                            .foregroundColor(DS.Colors.textPrimary)
                            .lineLimit(1)
                        if activeMate?.conductsOthers == true {
                            Text("All mates")
                                .font(DS.Fonts.keycap)
                                .foregroundColor(DS.Colors.textSecondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(DS.Colors.surface3))
                        }
                    }
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("Edit picture, details, and soul")
                Text(activeMate?.job ?? Mate.defaultJob)
                    .font(DS.Fonts.body.weight(.medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
            }
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    if companionManager.currentChat.messages.isEmpty
                        && companionManager.streamingAssistantText.isEmpty {
                        emptyMate
                            .padding(.top, 36)
                    }
                    if messageWindow.hiddenCount > 0 {
                        Button("Earlier messages (\(messageWindow.hiddenCount))") {
                            extraRevealed += MateHomeLayout.messagePageSize
                        }
                        .buttonStyle(.plain)
                        .font(DS.Fonts.control)
                        .foregroundColor(DS.Colors.textSecondary)
                        .pointerCursor()
                    }
                    ForEach(messageWindow.visible) { message in
                        messageRow(message)
                            .id(message.id)
                    }
                    if !companionManager.streamingAssistantText.isEmpty {
                        streamingRow
                            .id("mate-streaming")
                    }
                    Color.clear.frame(height: 1).id("mate-transcript-bottom")
                }
                .frame(maxWidth: MateHomeLayout.readingMeasure, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, isCompactLayout ? 16 : 28)
                .padding(.vertical, 18)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: MateTranscriptOffsetKey.self,
                            value: geo.frame(in: .named("mateTranscript")).maxY
                        )
                    }
                )
            }
            .coordinateSpace(name: "mateTranscript")
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: MateViewportHeightKey.self, value: geo.size.height)
                }
            )
            .onPreferenceChange(MateViewportHeightKey.self) { viewportHeight = $0 }
            .onPreferenceChange(MateTranscriptOffsetKey.self) { maxY in
                let near = maxY - viewportHeight < 72
                if near != isNearBottom { isNearBottom = near }
            }
            .onChange(of: companionManager.currentChat.messages.count) { _, _ in
                followLatest(proxy)
            }
            .onChange(of: companionManager.streamingAssistantText) { _, _ in
                followLatest(proxy)
            }
            .onChange(of: companionManager.currentChat.id) { _, _ in
                extraRevealed = 0
                isNearBottom = true
                scrollToLatest(proxy)
            }
            .onAppear { scrollToLatest(proxy) }
            .overlay(alignment: .bottom) {
                if !isNearBottom && !companionManager.currentChat.messages.isEmpty {
                    Button {
                        isNearBottom = true
                        scrollToLatest(proxy)
                    } label: {
                        Label("Latest", systemImage: "arrow.down")
                            .font(DS.Fonts.control)
                            .padding(.horizontal, 12)
                            .frame(height: 28)
                            .background(Capsule().fill(DS.Colors.surface3))
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .padding(.bottom, 10)
                }
            }
        }
    }

    private func followLatest(_ proxy: ScrollViewProxy) {
        guard MateHomeLayout.shouldFollowLatest(isNearBottom: isNearBottom) else { return }
        scrollToLatest(proxy)
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy) {
        if !companionManager.streamingAssistantText.isEmpty {
            proxy.scrollTo("mate-streaming", anchor: .bottom)
        } else {
            proxy.scrollTo("mate-transcript-bottom", anchor: .bottom)
        }
    }

    private var emptyMate: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let mate = activeMate {
                Button {
                    beginMateSettings(mate)
                } label: {
                    MateFaceView(mate: mate, size: 64)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("Edit picture, details, and soul")
            }
            Text(activeMate?.job ?? Mate.defaultJob)
                .font(DS.Fonts.reading)
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(MateStarterPrompts.lines(for: activeMate?.job ?? ""), id: \.self) { line in
                Button {
                    typedMessageInput = line
                    sendTypedMessageFromInput()
                } label: {
                    Text(line)
                        .font(DS.Fonts.reading)
                        .foregroundColor(DS.Colors.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                                .fill(DS.Colors.surface2)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
    }

    private func messageRow(_ message: ChatMessage) -> some View {
        let isUser = message.role == .user
        let canRegenerate = companionManager.precedingUserText(for: message.id) != nil
        return HStack(alignment: .top, spacing: 0) {
            if isUser { Spacer(minLength: 48) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
                if !isUser {
                    editableMateIdentity(
                        size: 22,
                        nameFont: DS.Fonts.control,
                        nameColor: DS.Colors.textSecondary
                    )
                }
                if let names = message.attachmentNames, !names.isEmpty {
                    ForEach(names, id: \.self) { name in
                        Label(name, systemImage: "photo")
                            .font(DS.Fonts.body)
                            .foregroundColor(DS.Colors.textSecondary)
                    }
                }
                if isUser {
                    Text(message.text)
                        .font(DS.Fonts.reading)
                        .foregroundColor(DS.Colors.textOnAccent)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
                                .fill(DS.Colors.helpChatUserBubble)
                        )
                } else {
                    ChatMarkdownText(text: message.text)
                }
                HStack(spacing: 12) {
                    if isUser {
                        ChatMessageActionButton(title: "Edit", help: "Edit message") {
                            if let text = companionManager.editMessageInComposer(id: message.id) {
                                typedMessageInput = text
                                isComposerFocused = true
                            }
                        }
                    } else if canRegenerate {
                        ChatMessageActionButton(title: "Regenerate", help: "Regenerate reply") {
                            companionManager.regenerateAssistantMessage(id: message.id)
                        }
                    }
                    ChatMessageActionButton(title: "Delete", help: "Delete message") {
                        companionManager.deleteMessage(id: message.id)
                    }
                }
            }
            .frame(maxWidth: isCompactLayout ? .infinity : 460, alignment: isUser ? .trailing : .leading)
            if !isUser { Spacer(minLength: 48) }
        }
    }

    private var streamingRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                editableMateIdentity(
                    size: 22,
                    nameFont: DS.Fonts.control,
                    nameColor: DS.Colors.textSecondary
                )
                ChatMarkdownText(text: companionManager.streamingAssistantText)
            }
            Spacer(minLength: 48)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !imageAttachments.isEmpty {
                ChatAttachmentPreviewStrip(attachments: imageAttachments, remove: removeImageAttachment)
            }
            VStack(alignment: .leading, spacing: 6) {
                TextField("Message \(activeMate?.name ?? Mate.defaultName)", text: $typedMessageInput, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(DS.Fonts.reading)
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1...6)
                    .focused($isComposerFocused)
                    .onSubmit(sendTypedMessageFromInput)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                HStack(spacing: 6) {
                    Button { isShowingImageImporter = true } label: {
                        Image(systemName: "paperclip")
                            .font(DS.Glyph.regular)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .help("Attach images")
                    // Silent mode means no mic, so hold-to-talk would only
                    // be a button that contradicts the mode.
                    if !companionManager.isSilentModeEnabled {
                        holdToTalkButton
                    }
                    silentModeButton
                    if companionManager.selectedBrain.offersSubscriptionVoiceChat {
                        subscriptionVoiceChatButton
                    }
                    Spacer(minLength: 4)
                    DesktopComposerModelButton(companionManager: companionManager)
                    Button { isShowingComposerOverflow = true } label: {
                        Image(systemName: "ellipsis")
                            .font(DS.Glyph.large)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .help("Connectors")
                    .popover(isPresented: $isShowingComposerOverflow, arrowEdge: .top) {
                        DesktopConnectorScopeMenu(companionManager: companionManager, compact: true)
                            .padding(12)
                    }
                    Button {
                        if companionManager.isComposerStopVisible {
                            companionManager.cancelInFlightChatTurn()
                        } else {
                            sendTypedMessageFromInput()
                        }
                    } label: {
                        Image(systemName: companionManager.isComposerStopVisible ? "stop.fill" : "arrow.up")
                            .font(DS.Glyph.regular)
                            .foregroundColor(
                                companionManager.isComposerStopVisible || canSend
                                    ? DS.Colors.textOnAccent
                                    : DS.Colors.textTertiary
                            )
                            .frame(width: 28, height: 28)
                            .background(
                                Circle().fill(
                                    companionManager.isComposerStopVisible || canSend
                                        ? companionManager.themeColor
                                        : DS.Colors.surface3
                                )
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .disabled(!companionManager.isComposerStopVisible && !canSend)
                    .help(companionManager.isComposerStopVisible ? "Stop" : "Send")
                    .accessibilityLabel(companionManager.isComposerStopVisible ? "Stop" : "Send")
                }
                .foregroundColor(DS.Colors.textSecondary)
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.hero, style: .continuous)
                    .fill(DS.Colors.surface1.opacity(0.94))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.hero, style: .continuous)
                    .stroke(
                        isImageDropTargeted || isComposerFocused
                            ? DS.Colors.accent.opacity(0.7)
                            : DS.Colors.borderSubtle,
                        lineWidth: 1
                    )
            )
            .shadow(color: Color.black.opacity(isCompactLayout ? 0 : 0.16), radius: 18, y: 10)
            if companionManager.isSilentModeSuggestionVisible {
                silentModeSuggestion
            }
            if companionManager.isSilentModeEnabled {
                Label("Silent mode · replies stay on screen", systemImage: "speaker.slash.fill")
                    .font(DS.Fonts.micro)
                    .foregroundColor(DS.Colors.textTertiary)
                    .accessibilityLabel("Silent mode is on. Replies stay on screen and are not spoken.")
            }
            if companionManager.isRecordingMeeting {
                Text("Meeting notes are on. Say stop meeting notes when you're done. Audio is not saved.")
                    .font(DS.Fonts.micro)
                    .foregroundColor(DS.Colors.textSecondary)
            }
            if let notice = companionManager.openCodeTrainingNotice {
                openCodeTrainingConfirm(notice)
            } else if let status = composerStatus {
                Text(status)
                    .font(DS.Fonts.micro)
                    .foregroundColor(DS.Colors.textTertiary)
            }
        }
    }

    // MARK: Jobs in chat

    /// This mate's jobs, newest first.
    private var activeMateJobs: [AgentRun] {
        guard let mate = activeMate else { return [] }
        return MateJobs.runs(
            for: mate,
            in: companionManager.agentRuns,
            owners: companionManager.mateRunOwners
        )
    }

    /// Unfinished jobs sit just above the composer, in the chat that asked
    /// for them: a plan waiting on you gets its Approve right here, and
    /// running work shows its live step. Finished jobs report back as chat
    /// messages, so they need no row.
    @ViewBuilder
    private var mateJobsStrip: some View {
        let unfinished = activeMateJobs.filter { !$0.status.isTerminal }
        let limit = isCompactLayout ? 1 : 3
        if !unfinished.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(unfinished.prefix(limit)) { run in
                    mateJobRow(run)
                }
                if unfinished.count > limit {
                    Button("\(unfinished.count - limit) more in Jobs") {
                        onOpenSection(.agents)
                    }
                    .buttonStyle(.plain)
                    .font(DS.Fonts.control)
                    .foregroundColor(DS.Colors.textSecondary)
                    .pointerCursor()
                }
            }
            .frame(maxWidth: MateHomeLayout.readingMeasure, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, isCompactLayout ? 12 : 20)
            .padding(.bottom, 8)
        }
    }

    private func mateJobRow(_ run: AgentRun) -> some View {
        HStack(spacing: 8) {
            Group {
                switch run.status {
                case .awaitingPlanApproval:
                    Image(systemName: "checklist")
                case .waitingForApproval:
                    Image(systemName: "hand.raised.fill")
                default:
                    ProgressView().controlSize(.small)
                }
            }
            .font(DS.Glyph.small)
            .foregroundColor(run.status.needsUser ? DS.Colors.warningText : DS.Colors.textSecondary)
            .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(run.title)
                    .font(DS.Fonts.headline)
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
                Text(mateJobDetail(run))
                    .font(DS.Fonts.caption)
                    .foregroundColor(run.status.needsUser ? DS.Colors.warningText : DS.Colors.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            switch run.status {
            case .awaitingPlanApproval:
                Button("Approve plan") { companionManager.approveAgentPlan(runID: run.id) }
                    .dsCapsuleButtonStyle(.primary, height: DS.ControlSize.small)
                    .help("Let this job make the changes its plan describes")
            case .waitingForApproval:
                Button("Allow") { companionManager.approveAgent(runID: run.id) }
                    .dsCapsuleButtonStyle(.primary, height: DS.ControlSize.small)
                Button("Deny") { companionManager.denyAgent(runID: run.id) }
                    .dsCapsuleButtonStyle(.quiet, height: DS.ControlSize.small)
            default:
                EmptyView()
            }
            Button(run.status == .awaitingPlanApproval ? "Review" : "Open") {
                onOpenSection(.agents)
            }
            .dsCapsuleButtonStyle(.quiet, height: DS.ControlSize.small)
            .help("Open this job in Jobs")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(DS.Colors.surface2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .stroke(
                    run.status.needsUser ? DS.Colors.warning.opacity(0.45) : DS.Colors.borderSubtle,
                    lineWidth: 1
                )
        )
    }

    private func mateJobDetail(_ run: AgentRun) -> String {
        let status = MateJobs.statusLabel(for: run.status)
        switch run.status {
        case .awaitingPlanApproval:
            // An approval that could not start leaves the job here, so the
            // reason has to be on the row or the button looks dead.
            if !run.error.isEmpty { return "Couldn't start · \(run.error)" }
            return "\(status) · nothing has changed yet"
        case .waitingForApproval:
            let step = run.latestAction.trimmingCharacters(in: .whitespacesAndNewlines)
            return step.isEmpty ? "\(status) for the next step" : "\(status) · \(step)"
        default:
            let step = run.latestAction.trimmingCharacters(in: .whitespacesAndNewlines)
            return step.isEmpty ? status : "\(status) · \(step)"
        }
    }

    private var holdToTalkButton: some View {
        Image(systemName: isHoldingTalk ? "waveform" : "mic")
            .font(DS.Glyph.regular)
            .foregroundColor(isHoldingTalk ? DS.Colors.textOnAccent : DS.Colors.textSecondary)
            .frame(width: 28, height: 28)
            .background(
                Circle().fill(isHoldingTalk ? companionManager.themeColor : DS.Colors.surface3)
            )
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !isHoldingTalk { beginHoldToTalk() }
                    }
                    .onEnded { _ in
                        endHoldToTalk()
                    }
            )
            .help("Hold to talk")
            .accessibilityLabel("Hold to talk")
    }

    /// Quick switch for silent mode, next to where you type. Tinted while on
    /// so the mode is visible without opening Settings.
    private var silentModeButton: some View {
        let isSilent = companionManager.isSilentModeEnabled
        return Button {
            companionManager.isSilentModeEnabled.toggle()
        } label: {
            Image(systemName: isSilent ? "speaker.slash.fill" : "speaker.wave.2")
                .font(DS.Glyph.regular)
                .foregroundColor(isSilent ? DS.Colors.textOnAccent : DS.Colors.textSecondary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(isSilent ? companionManager.themeColor : DS.Colors.surface3))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(isSilent ? "Silent mode is on — click to hear replies again" : "Silent mode: type instead of talk, read instead of hear")
        .accessibilityLabel(isSilent ? "Turn off silent mode" : "Turn on silent mode")
    }

    /// Shown once after HeyMate answered out loud through the Mac's own
    /// speakers, where everyone nearby heard it too.
    private var silentModeSuggestion: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("HeyMate just answered out loud through your Mac's speakers. Switch to silent mode to type and read instead?")
                .font(DS.Fonts.micro)
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button("Keep talking") { companionManager.dismissSilentModeSuggestion() }
                    .buttonStyle(.plain)
                    .font(DS.Fonts.micro)
                    .foregroundColor(DS.Colors.textSecondary)
                    .pointerCursor()
                Button("Go silent") { companionManager.acceptSilentModeSuggestion() }
                    .buttonStyle(.plain)
                    .font(DS.Fonts.caption.weight(.semibold))
                    .foregroundColor(companionManager.themeColor)
                    .pointerCursor()
            }
        }
    }

    private var subscriptionVoiceChatButton: some View {
        let active = companionManager.isSubscriptionVoiceChatActive
        return Button {
            companionManager.toggleSubscriptionVoiceChat()
        } label: {
            Image(systemName: active ? "waveform.circle.fill" : "waveform.circle")
                .font(DS.Glyph.large)
                .foregroundColor(active ? DS.Colors.textOnAccent : DS.Colors.textSecondary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(active ? companionManager.themeColor : DS.Colors.surface3))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(active ? "Stop voice chat" : "Voice chat on your ChatGPT or Claude plan")
        .accessibilityLabel(active ? "Stop voice chat" : "Start voice chat")
    }

    private func openCodeTrainingConfirm(_ notice: OpenCodeTrainingNotice) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(notice.detail)
                .font(DS.Fonts.micro)
                .foregroundColor(DS.Colors.warningText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button("Don't send") { companionManager.cancelOpenCodeTrainingSend() }
                    .buttonStyle(.plain)
                    .font(DS.Fonts.micro)
                    .foregroundColor(DS.Colors.textSecondary)
                    .pointerCursor()
                Button("Send anyway") { companionManager.confirmOpenCodeTrainingSend() }
                    .buttonStyle(.plain)
                    .font(DS.Fonts.caption.weight(.semibold))
                    .foregroundColor(DS.Colors.warningText)
                    .pointerCursor()
            }
        }
    }

    private var canSend: Bool {
        (!typedMessageInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !imageAttachments.isEmpty)
            && companionManager.canAcceptTypedAgentTask
    }

    private var composerStatus: String? {
        if let attachmentErrorText { return attachmentErrorText }
        return companionManager.commandBarFeedback ?? companionManager.typedMessageBusyReason
    }

    private func sendTypedMessageFromInput() {
        guard canSend else { return }
        if companionManager.sendTypedMessage(typedMessageInput, imageAttachments: imageAttachments) {
            typedMessageInput = ""
            imageAttachments = []
            attachmentErrorText = nil
        }
    }

    private func beginHoldToTalk() {
        isHoldingTalk = true
        let attachments = imageAttachments
        Task {
            await companionManager.buddyDictationManager.startHoldToTalk(
                currentDraftText: typedMessageInput,
                updateDraftText: { typedMessageInput = $0 },
                submitDraftText: { finalText in
                    let trimmed = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty || !attachments.isEmpty else { return }
                    if companionManager.sendTypedMessage(trimmed, imageAttachments: attachments) {
                        typedMessageInput = ""
                        imageAttachments = []
                        attachmentErrorText = nil
                    } else {
                        typedMessageInput = finalText
                    }
                }
            )
        }
    }

    private func endHoldToTalk() {
        guard isHoldingTalk else { return }
        isHoldingTalk = false
        companionManager.buddyDictationManager.stopPersistentDictationFromMicrophoneButton()
    }

    private func handleImageImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            addImageFiles(urls)
        case .failure(let error):
            attachmentErrorText = error.localizedDescription
        }
    }

    private func addImageFiles(_ urls: [URL]) {
        attachmentErrorText = nil
        let availableSlots = max(0, ChatImageAttachment.maximumCount - imageAttachments.count)
        guard availableSlots > 0 else {
            attachmentErrorText = "Up to \(ChatImageAttachment.maximumCount) images per message."
            return
        }
        for url in urls.prefix(availableSlots) {
            do {
                imageAttachments.append(try ChatImageAttachment.load(from: url))
            } catch {
                attachmentErrorText = error.localizedDescription
            }
        }
        if urls.count > availableSlots {
            attachmentErrorText = "Up to \(ChatImageAttachment.maximumCount) images per message."
        }
    }

    private func removeImageAttachment(_ id: UUID) {
        imageAttachments.removeAll { $0.id == id }
        attachmentErrorText = nil
    }

    // MARK: Drawer

    private var mateDrawer: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                editableMateIdentity(
                    size: 36,
                    nameFont: DS.Fonts.hero,
                    nameColor: DS.Colors.textPrimary
                )
                if let unread = activeMate?.unreadCount, unread > 0 {
                    Text(unread == 1 ? "1 unread routine result" : "\(unread) unread routine results")
                        .font(DS.Fonts.body.weight(.medium))
                        .foregroundColor(DS.Colors.warningText)
                }
                jobsSection
                memorySection
                filesSection
                routinesSection
                if let mate = activeMate {
                    Button("Delete mate", role: .destructive) {
                        matePendingDelete = mate
                    }
                    .buttonStyle(.plain)
                    .font(DS.Fonts.control)
                    .foregroundColor(DS.Colors.destructiveText)
                    .pointerCursor()
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(DS.Colors.surface1.opacity(0.94))
    }

    /// This mate's recent jobs, finished ones included, so "what did it do
    /// for me?" is answered next to the chat rather than on another page.
    private var jobsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Jobs")
                .font(DS.Fonts.sectionLabel)
                .foregroundColor(DS.Colors.textTertiary)
            let recent = activeMateJobs.prefix(5)
            if recent.isEmpty {
                Text("Ask this mate to make or change something and the job shows up here.")
                    .font(DS.Fonts.body)
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(recent) { run in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(run.title)
                        .font(DS.Fonts.bodyLarge.weight(.medium))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(MateJobs.statusLabel(for: run.status))
                        .font(DS.Fonts.caption.weight(.medium))
                        .foregroundColor(run.status.needsUser ? DS.Colors.warningText : DS.Colors.textTertiary)
                }
            }
            Button("All jobs") { onOpenSection(.agents) }
                .buttonStyle(.plain)
                .font(DS.Fonts.control)
                .foregroundColor(DS.Colors.textSecondary)
                .pointerCursor()
        }
    }

    private var memorySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Memory")
                .font(DS.Fonts.sectionLabel)
                .foregroundColor(DS.Colors.textTertiary)
            TextField(
                "A short note only this mate keeps",
                text: memoryNoteBinding,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(DS.Fonts.bodyLarge)
            .lineLimit(2...5)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                    .fill(DS.Colors.surface2)
            )
        }
    }

    private var messageWindow: (hiddenCount: Int, visible: [ChatMessage]) {
        MateHomeLayout.visibleMessages(
            companionManager.currentChat.messages,
            extraRevealed: extraRevealed
        )
    }

    private var filesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Files")
                .font(DS.Fonts.sectionLabel)
                .foregroundColor(DS.Colors.textTertiary)
            if let path = activeMate?.folderPath {
                let entries = MateWorkspace.files(in: path)
                if entries.isEmpty {
                    Text("This folder is empty.")
                        .font(DS.Fonts.body)
                        .foregroundColor(DS.Colors.textTertiary)
                }
                ForEach(entries) { entry in
                    HStack(spacing: 6) {
                        Button {
                            guard !entry.isDirectory else { return }
                            previewedFilePath = entry.id
                        } label: {
                            Label(entry.name, systemImage: entry.isDirectory ? "folder" : "doc.text")
                                .font(DS.Fonts.bodyLarge.weight(.medium))
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(DS.Colors.textPrimary)
                        .pointerCursor()
                        Spacer(minLength: 4)
                        if !entry.isDirectory {
                            Button {
                                filePendingDelete = entry.id
                            } label: {
                                Image(systemName: "trash")
                                    .font(DS.Glyph.small)
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(DS.Colors.textTertiary)
                            .pointerCursor()
                            .help("Delete file")
                            .accessibilityLabel("Delete \(entry.name)")
                        }
                    }
                }
                if let previewedFilePath,
                   let preview = MateWorkspace.previewText(at: previewedFilePath) {
                    Text(preview)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(8)
                        .textSelection(.enabled)
                }
                Button("Show in Finder") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
                }
                .buttonStyle(.plain)
                .font(DS.Fonts.control)
                .foregroundColor(DS.Colors.textSecondary)
                .pointerCursor()
                Button("Remove folder from HeyMate") {
                    isConfirmingFolderRemoval = true
                }
                .buttonStyle(.plain)
                .font(DS.Fonts.control)
                .foregroundColor(DS.Colors.textSecondary)
                .pointerCursor()
            } else if let mate = activeMate, !mate.conductsOthers {
                Button("Create folder") {
                    companionManager.ensureMateFolder(id: mate.id)
                }
                .buttonStyle(.plain)
                .font(DS.Fonts.control)
                .foregroundColor(DS.Colors.textSecondary)
                .pointerCursor()
            } else {
                Text("New mates get a folder under Projects.")
                    .font(DS.Fonts.body)
                    .foregroundColor(DS.Colors.textTertiary)
            }
            if let filesActionError {
                Text(filesActionError)
                    .font(DS.Fonts.body)
                    .foregroundColor(DS.Colors.destructiveText)
            }
        }
        .confirmationDialog(
            "Delete this file?",
            isPresented: fileDeleteDialogPresented,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { deletePendingFile() }
            Button("Cancel", role: .cancel) { filePendingDelete = nil }
        } message: {
            Text("This file will be moved to the Trash.")
        }
        .confirmationDialog(
            "Remove this folder from HeyMate?",
            isPresented: $isConfirmingFolderRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove folder from HeyMate") {
                forgetActiveMateFolder()
            }
            .keyboardShortcut(.defaultAction)
            Button("Move files to Trash", role: .destructive) {
                trashActiveMateFolder()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removing the folder keeps the files where they are. Move files to Trash only if you want those files moved to the Trash.")
        }
    }

    private var memoryNoteBinding: Binding<String> {
        Binding(
            get: { activeMate?.memoryNote ?? "" },
            set: { newValue in
                guard let id = activeMate?.id else { return }
                companionManager.updateMateMemory(id: id, note: newValue)
            }
        )
    }

    private var routinesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Routines")
                .font(DS.Fonts.sectionLabel)
                .foregroundColor(DS.Colors.textTertiary)
            RoutineAddField(companionManager: companionManager, mateID: activeMate?.id)
            let mine = companionManager.routines.filter { $0.mateID == activeMate?.id }
            if mine.isEmpty {
                Text("Nothing scheduled.")
                    .font(DS.Fonts.body)
                    .foregroundColor(DS.Colors.textTertiary)
            }
            ForEach(mine) { routine in
                routineRow(routine)
            }
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 8) {
                    if companionManager.routines.isEmpty {
                        Text("Nothing scheduled.")
                            .font(DS.Fonts.body)
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                    ForEach(companionManager.routines) { routine in
                        routineRow(routine, showsMateName: true)
                    }
                }
                .padding(.top, 4)
            } label: {
                Text("All routines")
                    .font(DS.Fonts.control)
                    .foregroundColor(DS.Colors.textSecondary)
            }
            .tint(DS.Colors.textSecondary)
        }
    }

    private func routineRow(_ routine: MateRoutine, showsMateName: Bool = false) -> some View {
        RoutineRow(
            routine: routine,
            showsMateName: showsMateName,
            mateName: companionManager.mates.first { $0.id == routine.mateID }?.name ?? Mate.defaultName,
            companionManager: companionManager
        )
    }

    private var pendingDeletionWarning: String {
        Mate.deletionWarning(
            replacesWithFreshHeyMate: matePendingDelete.map(deletionReplacesWithFreshHeyMate) ?? false
        )
    }

    private func deletionReplacesWithFreshHeyMate(_ mate: Mate) -> Bool {
        guard !mate.archived else { return false }
        return !companionManager.mates.contains { $0.id != mate.id && !$0.archived }
    }

    private func confirmDeleteMate() {
        if let mate = matePendingDelete {
            companionManager.deleteMate(id: mate.id)
        }
        matePendingDelete = nil
    }

    private var rootDeleteDialogPresented: Binding<Bool> {
        Binding(
            get: { matePendingDelete != nil && !(isCompactLayout && isDrawerOpen) },
            set: { presented in
                if !presented, !(isCompactLayout && isDrawerOpen) {
                    matePendingDelete = nil
                }
            }
        )
    }

    private var sheetDeleteDialogPresented: Binding<Bool> {
        Binding(
            get: { matePendingDelete != nil && isCompactLayout && isDrawerOpen },
            set: { presented in
                if !presented { matePendingDelete = nil }
            }
        )
    }

    private var archiveDialogPresented: Binding<Bool> {
        Binding(
            get: { matePendingArchive != nil },
            set: { presented in
                if !presented { matePendingArchive = nil }
            }
        )
    }

    private var fileDeleteDialogPresented: Binding<Bool> {
        Binding(
            get: { filePendingDelete != nil },
            set: { presented in
                if !presented { filePendingDelete = nil }
            }
        )
    }

    private func deletePendingFile() {
        guard let path = filePendingDelete else { return }
        do {
            try MateWorkspace.moveToTrash(path: path)
            if previewedFilePath == path { previewedFilePath = nil }
            filesActionError = nil
        } catch {
            filesActionError = "That file could not be moved to the Trash."
        }
        filePendingDelete = nil
    }

    private func forgetActiveMateFolder() {
        guard let id = activeMate?.id else { return }
        previewedFilePath = nil
        filesActionError = nil
        companionManager.forgetMateFolder(id: id)
    }

    private func trashActiveMateFolder() {
        guard let id = activeMate?.id else { return }
        previewedFilePath = nil
        if companionManager.trashMateFolder(id: id) {
            filesActionError = nil
        } else {
            filesActionError = "Those files could not be moved to the Trash."
        }
    }
}

private struct MateTranscriptOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct MateViewportHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct NewMateSheet: View {
    var onCreate: (String, String) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var job = ""
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New mate")
                .font(DS.Fonts.hero)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
            TextField("Job, in one sentence", text: $job)
                .textFieldStyle(.roundedBorder)
            if let errorText {
                Text(errorText)
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.destructiveText)
            }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func create() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedJob = job.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedJob.isEmpty else {
            errorText = "A mate needs a name and a job."
            return
        }
        if onCreate(trimmedName, trimmedJob) {
            dismiss()
        } else {
            errorText = "That name is already taken."
        }
    }
}

/// One routine with its controls. Shared by the chat drawer and the mate's
/// sheet, which both list that mate's routines.
struct RoutineRow: View {
    let routine: MateRoutine
    var showsMateName: Bool
    var mateName: String
    @ObservedObject var companionManager: CompanionManager
    @State private var isEditing = false
    @State private var taskDraft = ""
    @State private var scheduleDraft = ""
    @State private var errorText: String?
    @State private var confirmingDelete = false

    init(
        routine: MateRoutine,
        showsMateName: Bool,
        mateName: String,
        companionManager: CompanionManager
    ) {
        self.routine = routine
        self.showsMateName = showsMateName
        self.mateName = mateName
        self.companionManager = companionManager
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsMateName {
                Text(mateName)
                    .font(DS.Fonts.caption.weight(.semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(1)
            }
            if isEditing {
                editFields
            } else {
                Text(routine.task)
                    .font(DS.Fonts.headline)
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(2)
                Text(routine.pausedReason ?? routine.schedule.summary)
                    .font(DS.Fonts.body)
                    .foregroundColor(routine.pausedReason == nil ? DS.Colors.textSecondary : DS.Colors.warningText)
                    .lineLimit(2)
                if let status = routine.lastStatusMessage, !status.isEmpty {
                    Text(status)
                        .font(DS.Fonts.body)
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(3)
                }
                HStack(spacing: 10) {
                    if routine.pausedReason == nil {
                        Button("Pause") { companionManager.pauseRoutine(id: routine.id) }
                        Button("Run now") { companionManager.runRoutineNow(id: routine.id) }
                    } else {
                        Button("Resume") { companionManager.resumeRoutine(id: routine.id) }
                    }
                    Button("Edit") { beginEditing() }
                    Button("Delete") { confirmingDelete = true }
                }
                .font(DS.Fonts.control)
                .buttonStyle(.plain)
                .foregroundColor(DS.Colors.textSecondary)
                .pointerCursor()
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(DS.Colors.surface2)
        )
        .confirmationDialog("Delete this routine?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                companionManager.deleteRoutine(id: routine.id)
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var editFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Task", text: $taskDraft)
                .textFieldStyle(.plain)
                .font(DS.Fonts.bodyLarge)
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                        .fill(DS.Colors.background)
                )
            TextField("every morning", text: $scheduleDraft)
                .textFieldStyle(.plain)
                .font(DS.Fonts.bodyLarge)
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                        .fill(DS.Colors.background)
                )
                .onSubmit(save)
            if let errorText {
                Text(errorText)
                    .font(DS.Fonts.micro)
                    .foregroundColor(DS.Colors.destructiveText)
            }
            HStack(spacing: 10) {
                Button("Save", action: save)
                Button("Cancel") {
                    errorText = nil
                    isEditing = false
                }
            }
            .font(DS.Fonts.control)
            .buttonStyle(.plain)
            .foregroundColor(DS.Colors.textSecondary)
            .pointerCursor()
        }
    }

    private func beginEditing() {
        taskDraft = routine.task
        scheduleDraft = routine.schedule.instructionPhrase
        errorText = nil
        isEditing = true
    }

    private func save() {
        if let message = companionManager.updateRoutine(
            id: routine.id,
            task: taskDraft,
            schedulePhrase: scheduleDraft
        ) {
            errorText = message
            return
        }
        errorText = nil
        isEditing = false
    }
}

struct RoutineAddField: View {
    @ObservedObject var companionManager: CompanionManager
    var mateID: UUID?
    @State private var draft = ""
    @State private var errorText: String?

    init(companionManager: CompanionManager, mateID: UUID?) {
        self.companionManager = companionManager
        self.mateID = mateID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                TextField("Check this every morning", text: $draft)
                    .textFieldStyle(.plain)
                    .font(DS.Fonts.bodyLarge)
                    .onSubmit(add)
                Button("Add", action: add)
                    .font(DS.Fonts.control)
                    .buttonStyle(.plain)
                    .pointerCursor()
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                    .fill(DS.Colors.background)
            )
            if let errorText {
                Text(errorText)
                    .font(DS.Fonts.micro)
                    .foregroundColor(DS.Colors.destructiveText)
            }
        }
    }

    private func add() {
        guard let mateID else { return }
        guard let routine = RoutinePhraseParser.parse(
            draft,
            mateID: mateID,
            now: Date(),
            calendar: .current
        ) else {
            errorText = RoutinePhraseParser.invalidScheduleMessage
            return
        }
        companionManager.addRoutine(routine)
        draft = ""
        errorText = nil
    }
}
