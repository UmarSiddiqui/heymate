//
//  MateHomeView.swift
//  HeyMate
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
    var startsWithDrawerOpen: Bool = false

    @State private var searchText = ""
    @State private var hoveredRailMateID: UUID?
    @State private var hoveredRailChatID: UUID?
    @State private var chatPendingDelete: ChatSession?
    @AppStorage(MateRailTab.storageKey) private var railTabRawValue = MateRailTab.defaultTab.rawValue
    @State private var isDrawerOpen = false
    @State private var isShowingNewMate = false
    @State private var isShowingCast = false
    @State private var typedMessageInput = ""
    @State private var imageAttachments: [ChatImageAttachment] = []
    @State private var isShowingImageImporter = false
    @State private var attachmentErrorText: String?
    @State private var isImageDropTargeted = false
    @State private var isNearBottom = true
    @State private var viewportHeight: CGFloat = 0
    @State private var transcriptContentMaxY: CGFloat = 0
    @State private var isHoveringTalk = false
    @State private var extraRevealed = 0
    @State private var previewedFilePath: String?
    @State private var isHoldingTalk = false
    @State private var isComposerExpanded = false
    @State private var settingsMate: Mate?
    @State private var isShowingChatHistory = false
    @State private var matePendingDelete: Mate?
    @State private var matePendingArchive: Mate?
    @State private var filePendingDelete: String?
    @State private var isConfirmingFolderRemoval = false
    @State private var filesActionError: String?
    @FocusState private var isComposerFocused: Bool
    @FocusState private var focusedRailTab: MateRailTab?

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
                // The header sits in the titlebar row, level with the
                // traffic lights, instead of under an empty band.
                .ignoresSafeArea(.container, edges: isCompactLayout ? [] : .top)
            if columns.contains(.drawer) {
                Rectangle().fill(DS.Colors.borderSubtle).frame(width: 1)
                mateDrawer
                    .frame(width: MateHomeLayout.drawerWidth)
            }
        }
        .background(CelestialAtmosphere())
        .onAppear {
            if MateCast.shouldOffer(
                hasCompletedOnboarding: companionManager.hasCompletedOnboarding,
                activeMateCount: companionManager.mates.filter { !$0.archived }.count,
                alreadyOffered: UserDefaults.standard.bool(forKey: MateHomeView.castOfferedKey)
            ) {
                isShowingCast = true
            }
        }
        .sheet(isPresented: $isShowingCast, onDismiss: markCastOffered) {
            MateCastSheet(
                existingNames: companionManager.mates.map(\.name),
                onCreate: addCast
            )
        }
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
                onSave: { name, job, soul, face, tint, hair, outfit in
                    companionManager.updateMateProfile(
                        id: mate.id,
                        name: name,
                        job: job,
                        soul: soul,
                        faceAssetName: face,
                        faceTint: tint,
                        faceHair: hair,
                        faceOutfit: outfit
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
                    "Delete \(matePendingDelete?.name ?? "this agent")?",
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
            if startsWithDrawerOpen { isDrawerOpen = true }
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
        .onChange(of: isComposerFocused) { _, focused in
            if !focused && typedMessageInput.isEmpty { isComposerExpanded = false }
        }
        #if canImport(ImagePlayground)
        .modifier(ImagePlaygroundGate(concept: $companionManager.imagePlaygroundConcept) { url in
            companionManager.adoptImagePlaygroundFile(at: url)
        })
        #endif
        .confirmationDialog(
            "Delete \(matePendingDelete?.name ?? "this agent")?",
            isPresented: rootDeleteDialogPresented,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { confirmDeleteMate() }
            Button("Cancel", role: .cancel) { matePendingDelete = nil }
        } message: {
            Text(pendingDeletionWarning)
        }
        .confirmationDialog(
            "Delete this chat?",
            isPresented: Binding(
                get: { chatPendingDelete != nil },
                set: { if !$0 { chatPendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let session = chatPendingDelete {
                    companionManager.deleteChat(id: session.id)
                }
                chatPendingDelete = nil
            }
            Button("Cancel", role: .cancel) { chatPendingDelete = nil }
        } message: {
            Text("\(chatPendingDelete?.title ?? "This chat") is removed from your history.")
        }
        .confirmationDialog(
            "Archive \(matePendingArchive?.name ?? "this agent")?",
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

    private var railTab: MateRailTab { MateRailTab.stored(railTabRawValue) }

    private var mateRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            railTabBar
                .padding(.horizontal, 12)
                .padding(.top, 14)
            .onChange(of: railTabRawValue) { _, _ in
                searchText = ""
            }


            // Search and "new mate" share one row, like a messages inbox.
            HStack(spacing: 6) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .font(DS.Glyph.small)
                        .foregroundColor(DS.Colors.textTertiary)
                    TextField(railTab.searchPrompt, text: $searchText)
                        .textFieldStyle(.plain)
                        .font(DS.Fonts.bodyLarge)
                        .accessibilityLabel(railTab.searchPrompt)
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(DS.Colors.surface2.opacity(0.7))
                .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous))

                Button {
                    isShowingNewMate = true
                } label: {
                    Image(systemName: "plus")
                        .font(DS.Glyph.regular)
                }
                .dsToolbarIconButtonStyle()
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .help("New agent (⇧⌘N)")
                .accessibilityLabel("New agent")
                Button {
                    isShowingCast = true
                } label: {
                    Image(systemName: "person.3")
                        .font(DS.Glyph.regular)
                }
                .dsToolbarIconButtonStyle()
                .help("Meet a cast")
                .accessibilityLabel("Meet a cast")
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 10)

            switch railTab {
            case .chats:
                chatsRailList
            case .mates:
                matesRailList
            }

            Divider().overlay(DS.Colors.borderSubtle)
            // Labeled rows, not a lone gear: there are only two places to
            // go, and a 28pt unlabeled icon was easy to miss.
            VStack(spacing: 2) {
                ForEach(MateHomeLayout.workspaceSections) { section in
                    SettingsSidebarItem(
                        title: section.displayName,
                        symbolName: section.symbolName
                    ) {
                        onOpenSection(section)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .background(DS.Colors.surface1.opacity(0.9))
    }

    /// Chats and Mates. Drawn with DS tokens rather than a system segmented
    /// control, which would pick up the system accent color.
    private var railTabBar: some View {
        HStack(spacing: 2) {
            ForEach(MateRailTab.allCases) { tab in
                let isSelected = tab == railTab
                Button {
                    railTabRawValue = tab.rawValue
                } label: {
                    Text(tab.title)
                        .font(DS.Fonts.control)
                        .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.small - 2, style: .continuous)
                                .fill(isSelected ? DS.Colors.selectionFill : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.small - 2, style: .continuous)
                                .stroke(focusedRailTab == tab ? DS.Colors.focusRing : Color.clear, lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerCursor()
                // A DS ring instead of the system one, which uses the accent color.
                .focusEffectDisabled()
                .focused($focusedRailTab, equals: tab)
                .accessibilityLabel("\(tab.title) tab")
                .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                .fill(DS.Colors.surface2.opacity(0.7))
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sidebar: Chats or Mates")
    }

    private func railActionButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(DS.Fonts.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .frame(height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .padding(.horizontal, 8)
    }

    // MARK: Chats tab

    private var mainChats: [ChatSession] {
        MainChatList.sessions(
            saved: companionManager.savedChats,
            current: companionManager.currentChat,
            defaultMateID: companionManager.mateDirectory.defaultMateID,
            query: searchText
        )
    }

    private var chatsRailList: some View {
        let chats = mainChats
        let selectedID = MainChatList.selectedID(
            current: companionManager.currentChat,
            activeMateID: companionManager.activeMateID,
            defaultMateID: companionManager.mateDirectory.defaultMateID
        )
        return VStack(alignment: .leading, spacing: 0) {
            // ⌘N lives on the header's new-chat button, which follows the
            // open mate; this one always starts with main HeyMate.
            railActionButton("New chat", systemImage: "square.and.pencil") {
                companionManager.startNewMainChat()
            }
            .help("New chat with HeyMate")
            .accessibilityLabel("New chat with HeyMate")

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    railHeader(searchText.isEmpty ? "Chats" : "Results")
                    if chats.isEmpty {
                        Text(searchText.isEmpty ? "Chats with HeyMate show up here." : "No chats match that.")
                            .font(DS.Fonts.caption)
                            .foregroundColor(DS.Colors.textTertiary)
                            .padding(.horizontal, 12)
                            .padding(.top, 6)
                    }
                    ForEach(chats) { session in
                        chatRow(session, selected: session.id == selectedID)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 12)
                .padding(.bottom, 8)
            }
        }
    }

    private func chatRow(_ session: ChatSession, selected: Bool) -> some View {
        let isSaved = companionManager.savedChats.contains { $0.id == session.id }
        return Button {
            openMainChat(session)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(DS.Fonts.headline)
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
                Text(session.updatedAt.formatted(.relative(presentation: .named)))
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                    .fill(
                        selected
                            ? DS.Colors.selectionFill
                            : (hoveredRailChatID == session.id ? DS.Colors.surface2 : Color.clear)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { isHovering in
            if isHovering {
                hoveredRailChatID = session.id
            } else if hoveredRailChatID == session.id {
                hoveredRailChatID = nil
            }
        }
        .accessibilityLabel("Open chat \(session.title)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {
            if isSaved {
                Button("Delete", role: .destructive) { chatPendingDelete = session }
            }
        }
    }

    /// Opens a main HeyMate chat, leaving any mate chat that is open.
    private func openMainChat(_ session: ChatSession) {
        let defaultID = companionManager.mateDirectory.defaultMateID
        let mateIsOpen = (companionManager.activeMateID ?? defaultID) != defaultID
        if session.id == companionManager.currentChat.id {
            // The fresh, unsaved chat is already open; just make sure main
            // HeyMate is the active mate.
            if mateIsOpen { companionManager.startNewMainChat() }
            return
        }
        if companionManager.savedChats.contains(where: { $0.id == session.id }) {
            companionManager.openChat(id: session.id)
        } else {
            companionManager.startNewMainChat()
        }
    }

    // MARK: Mates tab

    private var matesRailList: some View {
        VStack(alignment: .leading, spacing: 0) {

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if !rail.pinned.isEmpty {
                        railHeader("Pinned")
                        ForEach(rail.pinned) { mate in
                            mateRow(mate)
                        }
                    }
                    if !suggestedAgents.isEmpty {
                        railHeader("Suggested")
                        ForEach(suggestedAgents) { suggestion in
                            suggestedRow(suggestion)
                        }
                    }
                    if showsActiveMateHeader {
                        railHeader(searchText.isEmpty ? "Agents" : "Results")
                    }
                    if rail.others.isEmpty && rail.pinned.isEmpty && (archivedRail.isEmpty || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                        Text(searchText.isEmpty ? "New agents show up here." : "No agents match that.")
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
        }
    }

    private var rail: (pinned: [Mate], others: [Mate]) {
        MateRailOrder.split(
            mates: companionManager.mates,
            sessions: companionManager.savedChats,
            query: searchText,
            defaultMateID: companionManager.mateDirectory.defaultMateID
        )
    }

    private var suggestedAgents: [AgentSuggestion] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty else { return [] }
        return AgentSuggestionCatalog.offers(existingJobs: companionManager.mates.map(\.job))
    }

    private func suggestedRow(_ suggestion: AgentSuggestion) -> some View {
        Button {
            addSuggestion(suggestion)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle")
                    .font(DS.Glyph.regular)
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.name)
                        .font(DS.Fonts.headline)
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)
                    Text(suggestion.job)
                        .font(DS.Fonts.body)
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .accessibilityLabel("Add \(suggestion.name)")
    }

    private func addSuggestion(_ suggestion: AgentSuggestion) {
        guard let mate = companionManager.createMate(
            name: suggestion.name,
            job: suggestion.job,
            soul: suggestion.soul
        ) else { return }
        _ = companionManager.updateMateProfile(
            id: mate.id,
            name: mate.name,
            job: mate.job,
            soul: suggestion.soul,
            faceAssetName: suggestion.faceAssetName
        )
    }

    private func liveFace(_ mate: Mate, size: CGFloat) -> some View {
        MateFaceView(
            mate: mate,
            size: size,
            expression: MateFaceExpression.live(companionManager.state)
        )
    }

    private func addCast(_ members: [MateCastProposal]) {
        var created: Mate?
        for member in members {
            guard let mate = companionManager.createMate(
                name: member.name,
                job: member.job,
                soul: member.soul,
                opensChat: false
            ) else { continue }
            _ = companionManager.updateMateProfile(
                id: mate.id,
                name: mate.name,
                job: mate.job,
                soul: member.soul,
                faceAssetName: member.faceAssetName,
                faceTint: member.faceTint,
                faceHair: member.faceHair,
                faceOutfit: member.faceOutfit
            )
            created = mate
        }
        if let created {
            companionManager.openMate(id: created.id)
        }
    }

    private static let castOfferedKey = "heymate.castOffered"

    private func markCastOffered() {
        UserDefaults.standard.set(true, forKey: Self.castOfferedKey)
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
        let preview = MateRailPreview.make(
            for: mate,
            sessions: companionManager.savedChats,
            defaultMateID: companionManager.mateDirectory.defaultMateID
        )
        return HStack(alignment: .center, spacing: 4) {
            // One target for the whole row: clicking anywhere opens the
            // chat. Editing is the pencil on hover or the context menu, so a
            // click on the face or name no longer lands in the editor.
            // A Button, not a tap gesture, so the click that activates an
            // inactive window still opens the mate.
            Button {
                openMateFromRow(mate)
            } label: {
                HStack(alignment: .center, spacing: 10) {
                    MateFaceView(mate: mate, size: 36)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(mate.name)
                                .font(DS.Fonts.headline)
                                .foregroundColor(DS.Colors.textPrimary)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            if presence != .idle {
                                Text(presence.label)
                                    .font(DS.Fonts.caption.weight(.medium))
                                    .foregroundColor(presence == .working ? DS.Colors.warningText : DS.Colors.textTertiary)
                            } else if let date = preview.date, hoveredRailMateID != mate.id {
                                Text(MateRailPreview.timestamp(date))
                                    .font(DS.Fonts.caption)
                                    .foregroundColor(DS.Colors.textTertiary)
                                    .lineLimit(1)
                            }
                        }
                        Text(preview.text)
                            .font(DS.Fonts.body)
                            .foregroundColor(mate.unreadCount > 0 ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .accessibilityLabel("Open \(mate.name)")
            if mate.archived {
                Button("Unarchive") {
                    companionManager.unarchiveMate(id: mate.id)
                }
                .dsCapsuleButtonStyle(.quiet, height: DS.ControlSize.small)
            }
            // Row tools appear on hover only, so names and jobs get the
            // rail's full width the rest of the time.
            if hoveredRailMateID == mate.id {
                mateRailControl("Edit", systemImage: "pencil") {
                    beginMateSettings(mate)
                }
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
                Circle()
                    .fill(companionManager.themeColor)
                    .frame(width: 8, height: 8)
                    .accessibilityLabel("Unread")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .fill(
                    selected
                        ? companionManager.themeColor.opacity(0.22)
                        : (hoveredRailMateID == mate.id ? DS.Colors.surface2 : Color.clear)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .strokeBorder(selected ? companionManager.themeColor.opacity(0.45) : Color.clear, lineWidth: 1)
        )
        // Hairline between rows, starting after the face, as in an inbox.
        .overlay(alignment: .bottom) {
            if !selected {
                Rectangle()
                    .fill(DS.Colors.borderSubtle)
                    .frame(height: 1)
                    .padding(.leading, 54)
                    .padding(.trailing, 8)
                    .offset(y: 1)
            }
        }
        .onHover { isHovering in
            if isHovering {
                hoveredRailMateID = mate.id
            } else if hoveredRailMateID == mate.id {
                hoveredRailMateID = nil
            }
        }
        .contextMenu {
            Button("Edit…") { beginMateSettings(mate) }
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
        }
        .dsToolbarIconButtonStyle(size: DS.ControlSize.small)
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
                .accessibilityHidden(true)
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
                .accessibilityLabel("Edit \(mate.name)")
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
            if isCompactLayout {
                headerTitles
            }
            if isCompactLayout {
                Menu {
                    ForEach(companionManager.mates.filter { !$0.archived }) { mate in
                        Button(mate.name) { companionManager.openMate(id: mate.id) }
                    }
                    Divider()
                    Button("New agent") { isShowingNewMate = true }
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
                .help("Switch agent")
            }
            Spacer(minLength: 8)
            jobsButton
            // On desktop, main HeyMate's chats live in the rail's Chats tab,
            // so history here is only for a mate's own past chats.
            if showsChatHistoryButton {
                Button {
                    isShowingChatHistory = true
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(DS.Glyph.regular)
                }
                .dsToolbarIconButtonStyle()
                .help(chatHistoryHelp)
                .accessibilityLabel(chatHistoryHelp)
            }
            Button {
                companionManager.startNewChat()
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(DS.Glyph.regular)
            }
            .dsToolbarIconButtonStyle()
            .keyboardShortcut("n", modifiers: .command)
            .help("New chat (⌘N)")
            .accessibilityLabel("New chat")
            Button {
                isDrawerOpen.toggle()
            } label: {
                Image(systemName: "sidebar.right")
                    .font(DS.Glyph.regular)
            }
            .dsToolbarIconButtonStyle(isActive: isDrawerOpen)
            .help(isDrawerOpen ? "Hide agent details" : "Agent details")
            .accessibilityLabel(isDrawerOpen ? "Hide agent details" : "Agent details")
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
                }
                .dsToolbarIconButtonStyle()
                .help("Collapse")
                .accessibilityLabel("Collapse")
            }
        }
        .foregroundColor(DS.Colors.textSecondary)
        .padding(.horizontal, isCompactLayout ? 12 : 22)
        .padding(.vertical, 10)
        .frame(minHeight: isCompactLayout ? nil : 64)
        .overlay {
            if !isCompactLayout {
                centeredMateIdentity
            }
        }
    }

    private var isMainHeyMateActive: Bool {
        let defaultID = companionManager.mateDirectory.defaultMateID
        return (companionManager.activeMateID ?? defaultID) == defaultID
    }

    private var showsChatHistoryButton: Bool {
        isCompactLayout || !isMainHeyMateActive
    }

    private var chatHistoryHelp: String {
        if !isMainHeyMateActive, let mate = activeMate {
            return "Past chats with \(mate.name)"
        }
        return "Chat history"
    }

    /// The face over a name pill, centered above the chat. The pill opens
    /// the mate's profile on the right; the face opens the editor.
    private var centeredMateIdentity: some View {
        VStack(spacing: 4) {
            if let mate = activeMate {
                Button {
                    beginMateSettings(mate)
                } label: {
                    liveFace(mate, size: 30)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("Edit picture, details, and soul")
                .accessibilityHidden(true)
            }
            Button {
                withAnimation(DS.Animation.controlSpring) { isDrawerOpen.toggle() }
            } label: {
                HStack(spacing: 3) {
                    Text(activeMate?.name ?? Mate.defaultName)
                        .font(DS.Fonts.control)
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)
                    Image(systemName: isDrawerOpen ? "chevron.left" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .padding(.horizontal, 10)
                .frame(height: 22)
                .background(Capsule().fill(DS.Colors.surface2.opacity(0.9)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help(isDrawerOpen ? "Hide profile" : "Show profile")
            .accessibilityLabel(isDrawerOpen ? "Hide \(activeMate?.name ?? Mate.defaultName)'s profile" : "Show \(activeMate?.name ?? Mate.defaultName)'s profile")
        }
        .padding(.top, 6)
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
                    Text("Agents")
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
        if needsYou { return "Agents: something needs your approval" }
        if activeCount > 0 { return "Agents: \(activeCount) in progress" }
        return "Agents: work they do over time"
    }

    private var headerTitles: some View {
        HStack(spacing: 10) {
            if let mate = activeMate {
                Button {
                    beginMateSettings(mate)
                } label: {
                    liveFace(mate, size: isCompactLayout ? 28 : 32)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("Edit picture, details, and soul")
                .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Button {
                    if let mate = activeMate { beginMateSettings(mate) }
                } label: {
                    Text(activeMate?.name ?? Mate.defaultName)
                        .font(DS.Fonts.title)
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("Edit picture, details, and soul")
                .accessibilityLabel("Edit \(activeMate?.name ?? Mate.defaultName)")
                Text(activeMate?.job ?? Mate.defaultJob)
                    .font(DS.Fonts.body)
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(1)
            }
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                // The action row under each message reserves its height even
                // while hidden, so the gap between messages can stay small.
                VStack(alignment: .leading, spacing: 10) {
                    if let firstMoment = companionManager.currentChat.firstMoment {
                        Label(firstMoment.confirmation, systemImage: "checkmark.circle")
                            .font(DS.Fonts.caption)
                            .foregroundColor(DS.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.bottom, 12)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("HeyMate confirmation: \(firstMoment.confirmation)")
                    }
                    if companionManager.currentChat.messages.isEmpty
                        && companionManager.streamingAssistantText.isEmpty
                        && companionManager.currentChat.firstMoment == nil {
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
                        messageRow(message, isLatest: message.id == messageWindow.visible.last?.id)
                            .id(message.id)
                    }
                    if let starter = companionManager.currentChat.firstMoment?.starter,
                       !companionManager.currentChat.messages.contains(where: { $0.role == .user }) {
                        firstMateStarter(starter)
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
                // Geometry reads rather than preferences: a preference set
                // inside the ScrollView never reached onPreferenceChange, so
                // "Latest" never showed and following never paused.
                .onGeometryChange(for: CGFloat.self) { geo in
                    geo.frame(in: .named("mateTranscript")).maxY
                } action: { maxY in
                    transcriptContentMaxY = maxY
                    updateIsNearBottom()
                }
            }
            .coordinateSpace(name: "mateTranscript")
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                viewportHeight = height
                updateIsNearBottom()
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
                scrollToLatestAfterLayout(proxy)
            }
            .onAppear { scrollToLatestAfterLayout(proxy) }
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

    private func updateIsNearBottom() {
        guard viewportHeight > 0 else { return }
        let near = transcriptContentMaxY - viewportHeight < 72
        if near != isNearBottom { isNearBottom = near }
    }

    /// Opening a chat scrolls before long replies have measured their
    /// height, which left the newest reply below the fold. Scroll again
    /// once layout has settled.
    private func scrollToLatestAfterLayout(_ proxy: ScrollViewProxy) {
        scrollToLatest(proxy)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            scrollToLatest(proxy)
        }
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
                    liveFace(mate, size: 64)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("Edit picture, details, and soul")
                .accessibilityLabel("Edit \(mate.name)")
            }
            Text(activeMate?.job ?? Mate.defaultJob)
                .font(DS.Fonts.reading)
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let mate = activeMate {
                let starter = MateFirstMoment.starter(for: mate)
                Button {
                    typedMessageInput = starter.prompt
                    isComposerFocused = true
                } label: {
                    Text(starter.label)
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
                .disabled(!typedMessageInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Add an editable message without sending")
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
    }

    private func firstMateStarter(_ starter: MateStarterSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 12) {
                Button {
                    if let draft = companionManager.useMateStarterInComposer() {
                        typedMessageInput = draft
                        isComposerFocused = true
                    }
                } label: {
                    Label(starter.label, systemImage: "square.and.pencil")
                        .font(DS.Fonts.headline)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .disabled(!typedMessageInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Add an editable message without sending")
                .accessibilityIdentifier("mate-starter-use")
                Spacer(minLength: 8)
                Button("Not now") { companionManager.dismissMateStarter() }
                    .buttonStyle(.plain)
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textSecondary)
                    .pointerCursor()
                    .accessibilityLabel("Dismiss starter suggestion")
            }
            Text("Edit the message, then send when you're ready.")
                .font(DS.Fonts.caption)
                .foregroundColor(DS.Colors.textSecondary)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: DS.CornerRadius.medium).fill(DS.Colors.surface2))
        .padding(.top, 2)
    }

    private func messageRow(_ message: ChatMessage, isLatest: Bool) -> some View {
        let isUser = message.role == .user
        let canRegenerate = companionManager.precedingUserText(for: message.id) != nil
        return ChatMessageHoverRow { isHovered in
            HStack(alignment: .top, spacing: 0) {
                if isUser { Spacer(minLength: 48) }
                VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
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
                    HStack(spacing: 6) {
                        if !isUser {
                            Text(message.createdAt.formatted(date: .omitted, time: .shortened))
                                .font(DS.Fonts.caption)
                                .foregroundColor(DS.Colors.textTertiary)
                        }
                    ChatMessageActionBar(
                        text: message.text,
                        isUser: isUser,
                        isRevealed: isHovered || isLatest,
                        onEdit: isUser ? {
                            if let text = companionManager.editMessageInComposer(id: message.id) {
                                typedMessageInput = text
                                isComposerFocused = true
                            }
                        } : nil,
                        onRegenerate: !isUser && canRegenerate ? {
                            companionManager.regenerateAssistantMessage(id: message.id)
                        } : nil,
                        onDelete: { companionManager.deleteMessage(id: message.id) }
                    )
                    }
                }
                .frame(maxWidth: isCompactLayout ? .infinity : 460, alignment: isUser ? .trailing : .leading)
                if !isUser { Spacer(minLength: 48) }
            }
        }
    }

    private var streamingRow: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
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
            if showsTalkFirstComposer {
                talkFirstComposer
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Message \(activeMate?.name ?? Mate.defaultName)", text: $typedMessageInput, axis: .vertical)
                        .accessibilityLabel("Message \(activeMate?.name ?? Mate.defaultName)")
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
                        }
                        .dsToolbarIconButtonStyle()
                        .help("Attach images")
                        .accessibilityLabel("Attach images")
                        // Silent mode means no mic, so hold-to-talk would only
                        // be a button that contradicts the mode.
                        if !companionManager.isSilentModeEnabled {
                            holdToTalkButton
                        }
                        voiceMenu
                        Spacer(minLength: 4)
                        DesktopConnectorScopeMenu(companionManager: companionManager, compact: true, isNarrow: isCompactLayout)
                        DesktopComposerModelButton(companionManager: companionManager)
                        Button {
                            if companionManager.isComposerStopVisible {
                                companionManager.cancelInFlightChatTurn()
                            } else {
                                sendTypedMessageFromInput()
                            }
                        } label: {
                            Image(systemName: companionManager.isComposerStopVisible ? "stop.fill" : "arrow.up")
                                .font(DS.Glyph.large.weight(.semibold))
                                .foregroundColor(
                                    companionManager.isComposerStopVisible || canSend
                                        ? DS.Colors.textOnAccent
                                        : DS.Colors.textTertiary
                                )
                                .frame(width: DS.ControlSize.large, height: DS.ControlSize.large)
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
                        .help(companionManager.isComposerStopVisible ? "Stop" : "Send (Return)")
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
            }
            if companionManager.isSilentModeSuggestionVisible {
                silentModeSuggestion
            }
            else if companionManager.isStarNudgeVisible {
                starNudge
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
                    Button("\(unfinished.count - limit) more in Agents") {
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
                    .help("Let this agent make the changes its plan describes")
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
            .help("Open this work in Agents")
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

    /// Talking is the main way in, so an idle composer leads with it: the
    /// mate's face, a wide hold-to-talk control and a small "Type…" that
    /// opens the full composer. Anything typed, attached or focused keeps
    /// the full composer up.
    private var showsTalkFirstComposer: Bool {
        !companionManager.isSilentModeEnabled
            && !isComposerExpanded
            && !isComposerFocused
            && typedMessageInput.isEmpty
            && imageAttachments.isEmpty
            && !companionManager.isComposerStopVisible
    }

    private var talkShortcutLabel: String {
        companionManager.talkShortcutOption.keyCapsuleLabels
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " + ")
    }

    private var talkFirstComposer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            Spacer(minLength: 0)
            if let mate = activeMate, !isCompactLayout {
                MateFaceView(mate: mate, size: 44)
                    .offset(y: -14)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    wideTalkButton
                    Button {
                        isComposerExpanded = true
                        DispatchQueue.main.async { isComposerFocused = true }
                    } label: {
                        Label("Type…", systemImage: "keyboard")
                            .font(DS.Fonts.control)
                            .foregroundColor(DS.Colors.textSecondary)
                            .padding(.horizontal, 14)
                            .frame(height: 40)
                            .background(Capsule().fill(DS.Colors.surface1.opacity(0.94)))
                            .overlay(Capsule().strokeBorder(DS.Colors.borderSubtle, lineWidth: 1))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .keyboardShortcut("l", modifiers: .command)
                    .help("Type a message (⌘L)")
                }
                Text(isHoldingTalk ? "Release to send" : "Or hold \(talkShortcutLabel) anywhere")
                    .font(DS.Fonts.micro)
                    .foregroundColor(DS.Colors.textTertiary)
                    .padding(.leading, 12)
            }
            Spacer(minLength: 0)
        }
    }

    private var wideTalkButton: some View {
        HStack(spacing: 8) {
            Image(systemName: isHoldingTalk ? "waveform" : "mic.fill")
                .font(DS.Glyph.regular)
            Text(isHoldingTalk ? "Listening…" : "Hold to talk")
                .font(DS.Fonts.controlLarge)
                .lineLimit(1)
        }
        .foregroundColor(DS.Colors.textOnAccent)
        .frame(minWidth: 220, maxWidth: 340)
        .frame(height: 40)
        .background(
            Capsule().fill(
                isHoldingTalk
                    ? companionManager.themeColor
                    : companionManager.themeColor.opacity(isHoveringTalk ? 0.92 : 0.8)
            )
        )
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
        .contentShape(Capsule())
        .onHover { isHoveringTalk = $0 }
        .pointerCursor()
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !isHoldingTalk { beginHoldToTalk() }
                }
                .onEnded { _ in
                    endHoldToTalk()
                }
        )
        .help("Hold to talk, release to send")
        .accessibilityLabel("Hold to talk")
    }

    private var holdToTalkButton: some View {
        Image(systemName: isHoldingTalk ? "waveform" : "mic")
            .font(DS.Glyph.regular)
            .foregroundColor(
                isHoldingTalk ? DS.Colors.textOnAccent
                    : isHoveringTalk ? DS.Colors.textPrimary : DS.Colors.textSecondary
            )
            .frame(width: DS.ControlSize.regular, height: DS.ControlSize.regular)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                    .fill(
                        isHoldingTalk ? companionManager.themeColor
                            : isHoveringTalk ? DS.Colors.surface2 : Color.clear
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous))
            .onHover { isHoveringTalk = $0 }
            .pointerCursor()
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

    /// Everything about hearing HeyMate, in one place: whether replies are
    /// read aloud, and live voice chat when the plan offers it. Two bare
    /// speaker and waveform icons beside the mic read as three mic buttons.
    private var voiceMenu: some View {
        let isSilent = companionManager.isSilentModeEnabled
        let isVoiceChatActive = companionManager.isSubscriptionVoiceChatActive
        return Menu {
            Toggle("Read replies aloud", isOn: Binding(
                get: { !companionManager.isSilentModeEnabled },
                set: { companionManager.isSilentModeEnabled = !$0 }
            ))
            if companionManager.selectedBrain.offersSubscriptionVoiceChat {
                Divider()
                Button(isVoiceChatActive ? "Stop voice chat" : "Start voice chat") {
                    companionManager.toggleSubscriptionVoiceChat()
                }
            }
        } label: {
            Image(systemName: isVoiceChatActive ? "waveform" : isSilent ? "speaker.slash" : "speaker.wave.2")
                .font(DS.Glyph.regular)
                .foregroundColor(isVoiceChatActive ? DS.Colors.textOnAccent : DS.Colors.textSecondary)
                .frame(width: DS.ControlSize.regular, height: DS.ControlSize.regular)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                        .fill(isVoiceChatActive ? companionManager.themeColor : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .pointerCursor()
        .help(isVoiceChatActive ? "Voice chat is on" : isSilent ? "Replies are silent" : "Replies are read aloud")
        .accessibilityLabel("Voice options")
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

    /// Shown once, after HeyMate has answered a few of the user's questions.
    private var starNudge: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Enjoying HeyMate? It's free and open source, and a star on GitHub helps other people find it.")
                .font(DS.Fonts.micro)
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button("Not now") { companionManager.dismissStarNudge() }
                    .buttonStyle(.plain)
                    .font(DS.Fonts.micro)
                    .foregroundColor(DS.Colors.textSecondary)
                    .pointerCursor()
                Button("Star on GitHub") { companionManager.acceptStarNudge() }
                    .buttonStyle(.plain)
                    .font(DS.Fonts.caption.weight(.semibold))
                    .foregroundColor(companionManager.themeColor)
                    .pointerCursor()
            }
        }
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
            await companionManager.voiceDictation.beginHoldToTalk(
                existingDraft: typedMessageInput,
                onDraftChange: { typedMessageInput = $0 },
                onSubmit: { finalText in
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
        companionManager.voiceDictation.finishHoldToTalk()
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
            // A profile first: who this mate is, then what it runs on a
            // schedule, what it has made, and what it remembers.
            VStack(alignment: .leading, spacing: 22) {
                mateProfileHeader
                if let unread = activeMate?.unreadCount, unread > 0 {
                    Text(unread == 1 ? "1 unread routine result" : "\(unread) unread routine results")
                        .font(DS.Fonts.body.weight(.medium))
                        .foregroundColor(DS.Colors.warningText)
                }
                routinesSection
                filesSection
                jobsSection
                memorySection
                if let mate = activeMate {
                    Divider()
                    Button("Delete agent…", role: .destructive) {
                        matePendingDelete = mate
                    }
                    .dsCapsuleButtonStyle(.destructive, height: DS.ControlSize.small)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(DS.Colors.surface1.opacity(0.94))
    }

    private var mateProfileHeader: some View {
        VStack(spacing: 10) {
            if !isCompactLayout {
                HStack {
                    Button {
                        withAnimation(DS.Animation.controlSpring) { isDrawerOpen = false }
                    } label: {
                        Image(systemName: "xmark")
                            .font(DS.Glyph.small)
                    }
                    .dsToolbarIconButtonStyle(size: DS.ControlSize.small)
                    .help("Hide profile")
                    .accessibilityLabel("Hide profile")
                    Spacer()
                }
            }
            if let mate = activeMate {
                liveFace(mate, size: 88)
                    .accessibilityHidden(true)
                Button {
                    beginMateSettings(mate)
                } label: {
                    Label("Edit agent", systemImage: "paintbrush.pointed")
                        .font(DS.Fonts.control)
                }
                .dsCapsuleButtonStyle(.secondary, height: DS.ControlSize.small)
                VStack(spacing: 3) {
                    Text(mate.name)
                        .font(DS.Fonts.title)
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)
                    Text(mate.job)
                        .font(DS.Fonts.body)
                        .foregroundColor(DS.Colors.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                    if !mate.soul.isEmpty {
                        Text(mate.soul)
                            .font(DS.Fonts.caption)
                            .foregroundColor(DS.Colors.textTertiary)
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                            .padding(.top, 4)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// This mate's recent jobs, finished ones included, so "what did it do
    /// for me?" is answered next to the chat rather than on another page.
    private var jobsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Work")
                .font(DS.Fonts.sectionLabel)
                .foregroundColor(DS.Colors.textTertiary)
            let recent = activeMateJobs.prefix(5)
            if recent.isEmpty {
                Text("Ask this agent to make or change something and the work shows up here.")
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
                .dsCapsuleButtonStyle(.quiet, height: DS.ControlSize.small)
        }
    }

    private var memorySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Memory")
                .font(DS.Fonts.sectionLabel)
                .foregroundColor(DS.Colors.textTertiary)
            TextField(
                "A short note only this agent keeps",
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
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                    spacing: 8
                ) {
                    ForEach(entries) { entry in
                        MateArtifactCard(
                            path: entry.id,
                            name: entry.name,
                            isDirectory: entry.isDirectory,
                            onOpen: {
                                if entry.isDirectory {
                                    NSWorkspace.shared.open(URL(fileURLWithPath: entry.id))
                                } else {
                                    previewedFilePath = previewedFilePath == entry.id ? nil : entry.id
                                }
                            },
                            onDelete: entry.isDirectory ? nil : { filePendingDelete = entry.id }
                        )
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
                Text("An agent's folder is created when they start file work.")
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

private struct NewMateSheet: View {
    var onCreate: (String, String) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var job = ""
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New agent")
                .font(DS.Fonts.hero)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
            TextField("What they do, in one sentence", text: $job)
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
            errorText = "An agent needs a name and what it does."
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
