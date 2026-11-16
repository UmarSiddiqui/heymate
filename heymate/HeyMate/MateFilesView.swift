//
//  MateFilesView.swift
//  HeyMate
//
//  A mate's folder as a file manager: a lazily loaded tree with search and
//  sort, a Quick Look / text / web preview, per-file version history, and
//  the usual file actions. All path work goes through MateFolderGuard,
//  MateFileTree, MateFileActions and MateFileStore; this file is only the UI.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MateFilesView: View {
    let folderPath: String
    let mateName: String
    /// Names the file in this mate's chat box.
    let onAsk: (String) -> Void
    let onClose: () -> Void

    private enum DetailTab: String, CaseIterable, Identifiable {
        case preview = "Preview"
        case history = "History"
        var id: String { rawValue }
    }

    @State private var sort: MateFileSort = .name
    @State private var listings: [String: MateFolderListing] = [:]
    @State private var expanded: Set<String> = []
    @State private var origins: [String: MateFileOrigin] = [:]
    @State private var selection: MateFileNode?
    @State private var query = ""
    @State private var searchResults: [MateFileNode]?
    @State private var searchComplete = true
    @State private var detailTab: DetailTab = .preview
    @State private var renaming: MateFileNode?
    @State private var renameText = ""
    @State private var isCreatingFolder = false
    @State private var newFolderName = ""
    @State private var pendingTrash: MateFileNode?
    @State private var errorText: String?
    @State private var isDropTargeted = false
    @State private var reloadToken = UUID()

    private var folder: URL { URL(fileURLWithPath: folderPath, isDirectory: true) }
    private var store: MateFileStore { MateFileStore(folder: folder) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                browser
                    .frame(minWidth: 320, idealWidth: 420)
                detail
                    .frame(minWidth: 320, idealWidth: 460)
            }
        }
        .frame(minWidth: 760, idealWidth: 940, minHeight: 520, idealHeight: 640)
        .background(DS.Colors.surface1)
        .task(id: reloadToken) { await reloadAll() }
        .task(id: query + "|" + sort.rawValue + "|" + reloadToken.uuidString) { await runSearch() }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
                .accessibilityLabel("New name")
            Button("Rename") { commitRename() }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .alert("New folder", isPresented: $isCreatingFolder) {
            TextField("Folder name", text: $newFolderName)
                .accessibilityLabel("Folder name")
            Button("Create") { commitNewFolder() }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Move \(pendingTrash?.name ?? "this item") to the Trash?",
            isPresented: Binding(get: { pendingTrash != nil }, set: { if !$0 { pendingTrash = nil } }),
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) { commitTrash() }
            Button("Cancel", role: .cancel) { pendingTrash = nil }
        } message: {
            Text("You can put it back from the Trash in Finder.")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(mateName)'s files")
                    .font(DS.Fonts.title)
                    .foregroundColor(DS.Colors.textPrimary)
                Text((folderPath as NSString).abbreviatingWithTildeInPath)
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button { newFolderName = ""; isCreatingFolder = true } label: {
                Image(systemName: "folder.badge.plus").font(DS.Glyph.regular)
            }
            .dsToolbarIconButtonStyle()
            .help("New folder")
            .accessibilityLabel("New folder")
            Button { reloadToken = UUID() } label: {
                Image(systemName: "arrow.clockwise").font(DS.Glyph.regular)
            }
            .dsToolbarIconButtonStyle()
            .help("Refresh")
            .accessibilityLabel("Refresh files")
            Button { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folderPath) } label: {
                Image(systemName: "folder").font(DS.Glyph.regular)
            }
            .dsToolbarIconButtonStyle()
            .help("Show folder in Finder")
            .accessibilityLabel("Show folder in Finder")
            Button("Done", action: onClose)
                .dsCapsuleButtonStyle(.secondary, height: DS.ControlSize.small)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close files")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: Tree

    private var browser: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(DS.Glyph.small)
                        .foregroundColor(DS.Colors.textTertiary)
                    TextField("Filter by name", text: $query)
                        .textFieldStyle(.plain)
                        .font(DS.Fonts.body)
                        .accessibilityLabel("Filter files by name")
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").dsIconHitArea(16) }
                            .buttonStyle(.plain)
                            .foregroundColor(DS.Colors.textTertiary)
                            .help("Clear filter")
                            .accessibilityLabel("Clear filter")
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: DS.ControlSize.regular)
                .background(RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous).fill(DS.Colors.surface2))
                Picker("Sort", selection: $sort) {
                    ForEach(MateFileSort.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Sort files")
                .onChange(of: sort) { _, _ in reloadToken = UUID() }
            }
            .padding(10)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if let searchResults {
                        ForEach(searchResults) { node in row(node, depth: 0, showsPath: true) }
                        if searchResults.isEmpty && searchComplete {
                            emptyLine("No files match.")
                        }
                        if !searchComplete {
                            emptyLine("Showing the first matches. Type more to narrow it down.")
                        }
                    } else {
                        let rows = MateFileTree.rows(listings: listings, expanded: expanded)
                        if rows.isEmpty, listings[""] != nil { emptyLine("This folder is empty. Drop files here to copy them in.") }
                        ForEach(rows) { item in
                            switch item {
                            case .node(let node, let depth):
                                row(node, depth: depth, showsPath: false)
                            case .more(let directory, let remaining, let depth):
                                Button("Show \(min(remaining, MateFileTree.pageSize)) more of \(remaining)") {
                                    listings[directory]?.shownCount += MateFileTree.pageSize
                                }
                                .buttonStyle(.plain)
                                .font(DS.Fonts.control)
                                .foregroundColor(DS.Colors.textSecondary)
                                .padding(.leading, CGFloat(depth) * 14 + 30)
                                .padding(.vertical, 4)
                                .pointerCursor()
                                .accessibilityLabel("Show more files, \(remaining) not shown")
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .stroke(DS.Colors.borderStrong, lineWidth: 2)
                        .padding(4)
                        .allowsHitTesting(false)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                copyIn(urls, to: MateFileActions.directory(for: selection?.isExpandable == true ? selection : nil))
            } isTargeted: { isDropTargeted = $0 }
            if let errorText {
                Text(errorText)
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.destructiveText)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text)
            .font(DS.Fonts.body)
            .foregroundColor(DS.Colors.textTertiary)
            .padding(12)
    }

    private func url(of node: MateFileNode) -> URL {
        folder.appendingPathComponent(node.relativePath)
    }

    private func row(_ node: MateFileNode, depth: Int, showsPath: Bool) -> some View {
        let isSelected = selection?.relativePath == node.relativePath
        let origin = MateFileOrigins.origin(of: node.relativePath, in: origins)
        return HStack(spacing: 6) {
            if node.isExpandable && !showsPath {
                Button { toggle(node) } label: {
                    Image(systemName: expanded.contains(node.relativePath) ? "chevron.down" : "chevron.right")
                        .font(DS.Glyph.small)
                        .foregroundColor(DS.Colors.textTertiary)
                        .dsIconHitArea(18)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded.contains(node.relativePath) ? "Collapse \(node.name)" : "Expand \(node.name)")
            } else {
                Color.clear.frame(width: 18, height: 18)
            }
            Image(nsImage: NSWorkspace.shared.icon(forFile: url(of: node).path))
                .resizable()
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(node.name)
                    .font(DS.Fonts.body)
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if showsPath, !node.parentPath.isEmpty {
                    Text(node.parentPath)
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 6)
            if origin != .other || !node.isDirectory {
                Text(origin.badge)
                    .font(DS.Fonts.micro)
                    .foregroundColor(origin == .other ? DS.Colors.textTertiary : DS.Colors.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(origin == .other ? Color.clear : DS.Colors.surface3))
                    .overlay(Capsule().stroke(DS.Colors.borderSubtle, lineWidth: origin == .other ? 1 : 0))
            }
            Text(MateFileTree.formattedSize(node.size))
                .font(DS.Fonts.numeric)
                .foregroundColor(DS.Colors.textTertiary)
                .frame(width: 64, alignment: .trailing)
            Text(node.modified.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "")
                .font(DS.Fonts.caption)
                .foregroundColor(DS.Colors.textTertiary)
                .lineLimit(1)
                .frame(width: 128, alignment: .trailing)
        }
        .padding(.leading, CGFloat(depth) * 14 + 6)
        .padding(.trailing, 10)
        .frame(minHeight: 26)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                .fill(isSelected ? DS.Colors.surface3 : Color.clear)
        )
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { open(node) }
        .onTapGesture { select(node) }
        .onDrag { NSItemProvider(contentsOf: url(of: node)) ?? NSItemProvider() }
        .dropDestination(for: URL.self) { urls, _ in
            copyIn(urls, to: MateFileActions.directory(for: node))
        }
        .contextMenu { actions(for: node) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(node.isDirectory ? "Folder" : "File") \(node.name), \(origin.badge)")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction(named: "Open") { open(node) }
    }

    @ViewBuilder private func actions(for node: MateFileNode) -> some View {
        Button("Open") { open(node) }
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url(of: node)]) }
        Button("Ask \(mateName) about this") { onAsk(node.relativePath) }
        Divider()
        Button("Rename…") { renameText = node.name; renaming = node }
        Button("New folder…") { select(node); newFolderName = ""; isCreatingFolder = true }
        Divider()
        Button("Move to Trash…", role: .destructive) { pendingTrash = node }
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        if let node = selection {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    if !node.isDirectory {
                        Picker("View", selection: $detailTab) {
                            ForEach(DetailTab.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        .accessibilityLabel("Preview or history")
                    }
                    Spacer(minLength: 4)
                    Button("Ask \(mateName)") { onAsk(node.relativePath) }
                        .dsCapsuleButtonStyle(.secondary, height: DS.ControlSize.small)
                        .help("Name this file in \(mateName)'s chat box")
                        .accessibilityLabel("Ask \(mateName) about \(node.name)")
                    Button { open(node) } label: { Image(systemName: "arrow.up.forward.square").font(DS.Glyph.regular) }
                        .dsToolbarIconButtonStyle()
                        .help("Open")
                        .accessibilityLabel("Open \(node.name)")
                    Button { NSWorkspace.shared.activateFileViewerSelecting([url(of: node)]) } label: {
                        Image(systemName: "magnifyingglass.circle").font(DS.Glyph.regular)
                    }
                    .dsToolbarIconButtonStyle()
                    .help("Reveal in Finder")
                    .accessibilityLabel("Reveal \(node.name) in Finder")
                    Button { renameText = node.name; renaming = node } label: { Image(systemName: "pencil").font(DS.Glyph.regular) }
                        .dsToolbarIconButtonStyle()
                        .help("Rename")
                        .accessibilityLabel("Rename \(node.name)")
                    Button { pendingTrash = node } label: { Image(systemName: "trash").font(DS.Glyph.regular) }
                        .dsToolbarIconButtonStyle(isDestructiveOnHover: true)
                        .help("Move to Trash")
                        .accessibilityLabel("Move \(node.name) to the Trash")
                }
                .padding(10)
                Divider()
                if node.isDirectory {
                    folderSummary(node)
                } else if detailTab == .history {
                    MateFileHistoryView(store: store, folder: folder, relativePath: node.relativePath) {
                        reloadToken = UUID()
                    }
                } else {
                    MateFilePreview(url: url(of: node), folder: folder)
                        .id(node.relativePath + reloadToken.uuidString)
                }
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 26))
                    .foregroundColor(DS.Colors.textTertiary)
                    .accessibilityHidden(true)
                Text("Select a file to preview it.")
                    .font(DS.Fonts.body)
                    .foregroundColor(DS.Colors.textSecondary)
                Text("Drag files in to copy them here, or drag files out to Finder.")
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func folderSummary(_ node: MateFileNode) -> some View {
        VStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url(of: node).path))
                .resizable()
                .frame(width: 48, height: 48)
                .accessibilityHidden(true)
            Text(node.name).font(DS.Fonts.headline).foregroundColor(DS.Colors.textPrimary)
            if let count = listings[node.relativePath]?.entries.count {
                Text(count == 1 ? "1 item" : "\(count) items")
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Loading

    private func list(_ directory: String) async -> MateFolderListing {
        let folder = folder, sort = sort
        return await Task.detached(priority: .userInitiated) {
            MateFileTree.list(directory, in: folder, sort: sort)
        }.value
    }

    private func reloadAll() async {
        let store = store
        let loadedOrigins = await Task.detached(priority: .utility) { store.origins() }.value
        origins = loadedOrigins
        var next: [String: MateFolderListing] = [:]
        for directory in [""] + expanded.sorted() {
            var listing = await list(directory)
            if let shown = listings[directory]?.shownCount { listing.shownCount = min(listing.entries.count, max(listing.shownCount, shown)) }
            next[directory] = listing
        }
        guard !Task.isCancelled else { return }
        listings = next
        if let current = selection {
            let refreshed = next[current.parentPath]?.entries.first { $0.relativePath == current.relativePath }
            if refreshed == nil, next[current.parentPath] != nil, searchResults == nil { selection = nil }
            else if let refreshed { selection = refreshed }
        }
    }

    private func toggle(_ node: MateFileNode) {
        if expanded.contains(node.relativePath) {
            expanded.remove(node.relativePath)
            return
        }
        expanded.insert(node.relativePath)
        guard listings[node.relativePath] == nil else { return }
        Task { listings[node.relativePath] = await list(node.relativePath) }
    }

    private func runSearch() async {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { searchResults = nil; searchComplete = true; return }
        do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
        let folder = folder, sort = sort
        let work = Task.detached(priority: .userInitiated) {
            MateFileTree.search(needle, in: folder, isCancelled: { Task.isCancelled })
        }
        let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        guard !Task.isCancelled else { return }
        searchResults = MateFileTree.sorted(result.matches, by: sort)
        searchComplete = result.complete
    }

    // MARK: Actions

    private func select(_ node: MateFileNode) {
        selection = node
        if node.isDirectory { detailTab = .preview }
    }

    private func open(_ node: MateFileNode) {
        if node.isExpandable, searchResults == nil {
            toggle(node)
        } else {
            NSWorkspace.shared.open(url(of: node))
        }
    }

    private func commitRename() {
        guard let node = renaming else { return }
        renaming = nil
        do {
            let path = try MateFileActions.rename(node.relativePath, to: renameText, in: folder, store: store)
            errorText = nil
            if expanded.remove(node.relativePath) != nil { expanded.insert(path) }
            listings[node.relativePath] = nil
            selection = nil
            reloadToken = UUID()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func commitNewFolder() {
        let directory = MateFileActions.directory(for: selection)
        do {
            try MateFileActions.newFolder(named: newFolderName, inDirectory: directory, in: folder)
            errorText = nil
            if !directory.isEmpty { expanded.insert(directory) }
            reloadToken = UUID()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func commitTrash() {
        guard let node = pendingTrash else { return }
        pendingTrash = nil
        do {
            try MateFileActions.moveToTrash(node.relativePath, in: folder, store: store)
            errorText = nil
            if selection?.relativePath == node.relativePath { selection = nil }
            expanded.remove(node.relativePath)
            reloadToken = UUID()
        } catch {
            errorText = "\(node.name) could not be moved to the Trash."
        }
    }

    private func copyIn(_ urls: [URL], to directory: String) -> Bool {
        do {
            let copied = try MateFileActions.copyIn(urls, toDirectory: directory, in: folder, store: store)
            errorText = copied.isEmpty && !urls.isEmpty ? "Those files could not be copied." : nil
            if !directory.isEmpty { expanded.insert(directory) }
            reloadToken = UUID()
            return !copied.isEmpty
        } catch {
            errorText = error.localizedDescription
            return false
        }
    }
}

/// Text and Markdown in HeyMate's own reader, HTML in the local web preview,
/// everything else in Quick Look.
struct MateFilePreview: View {
    let url: URL
    let folder: URL

    var body: some View {
        if ["html", "htm"].contains(url.pathExtension.lowercased()) {
            AgentWebPreview(previewTarget: .file(url, readAccessURL: folder), reloadIdentifier: UUID())
        } else {
            MateDocumentPreview(path: url.path, onClose: {}, showsHeader: false)
        }
    }
}

/// Earlier versions of one file, newest first, with a diff against the
/// current file for text and a Restore that keeps what it replaces.
struct MateFileHistoryView: View {
    let store: MateFileStore
    let folder: URL
    let relativePath: String
    let onRestored: () -> Void

    @State private var versions: [MateFileVersion] = []
    @State private var selected: MateFileVersion?
    @State private var diff: [MateDiffLine]?
    @State private var diffNote: String?
    @State private var pendingRestore: MateFileVersion?
    @State private var errorText: String?

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if versions.isEmpty {
                        Text("No earlier versions. HeyMate keeps one each time a mate changes this file.")
                            .font(DS.Fonts.body)
                            .foregroundColor(DS.Colors.textTertiary)
                            .padding(12)
                    }
                    ForEach(versions) { version in
                        Button { selected = version } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(version.date?.formatted(date: .abbreviated, time: .standard) ?? version.at)
                                    .font(DS.Fonts.body)
                                    .foregroundColor(DS.Colors.textPrimary)
                                Text((version.source == "restore" ? "Before a restore" : "Before a mate change")
                                     + " · " + ByteCountFormatter.string(fromByteCount: version.size, countStyle: .file))
                                    .font(DS.Fonts.caption)
                                    .foregroundColor(DS.Colors.textTertiary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                                    .fill(selected?.id == version.id ? DS.Colors.surface3 : Color.clear)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Version from \(version.date?.formatted() ?? version.at)")
                        .accessibilityAddTraits(selected?.id == version.id ? .isSelected : [])
                    }
                }
                .padding(6)
            }
            .frame(width: 200)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                if let version = selected {
                    HStack {
                        Text("Changes since this version")
                            .font(DS.Fonts.sectionLabel)
                            .foregroundColor(DS.Colors.textTertiary)
                        Spacer()
                        Button("Restore…") { pendingRestore = version }
                            .dsCapsuleButtonStyle(.secondary, height: DS.ControlSize.small)
                            .accessibilityLabel("Restore this version")
                    }
                    .padding(10)
                    Divider()
                    diffBody
                } else {
                    Text("Select a version to compare it with the file as it is now.")
                        .font(DS.Fonts.body)
                        .foregroundColor(DS.Colors.textTertiary)
                        .padding(12)
                }
                if let errorText {
                    Text(errorText).font(DS.Fonts.caption).foregroundColor(DS.Colors.destructiveText).padding(10)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .task(id: relativePath) { await loadVersions() }
        .task(id: selected?.id) { await loadDiff() }
        .confirmationDialog("Restore this version?", isPresented: Binding(
            get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } }
        ), titleVisibility: .visible) {
            Button("Restore") { restore() }
            Button("Cancel", role: .cancel) { pendingRestore = nil }
        } message: {
            Text("The file as it is now is kept as a version first, so you can switch back.")
        }
    }

    @ViewBuilder private var diffBody: some View {
        if let diffNote {
            Text(diffNote)
                .font(DS.Fonts.body)
                .foregroundColor(DS.Colors.textSecondary)
                .padding(12)
        } else if let diff {
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(diff.enumerated()), id: \.offset) { _, line in diffLine(line) }
                }
                .padding(8)
            }
        } else {
            ProgressView().padding(12)
        }
    }

    @ViewBuilder private func diffLine(_ line: MateDiffLine) -> some View {
        switch line {
        case .same(let text): diffText("  " + text, fill: .clear)
        case .removed(let text):
            diffText("− " + text, fill: DS.Colors.destructive.opacity(0.14)).accessibilityLabel("Removed: \(text)")
        case .added(let text):
            diffText("+ " + text, fill: DS.Colors.success.opacity(0.14)).accessibilityLabel("Added: \(text)")
        case .skipped(let count):
            Text(count == 1 ? "1 unchanged line" : "\(count) unchanged lines")
                .font(DS.Fonts.caption)
                .foregroundColor(DS.Colors.textTertiary)
                .padding(.vertical, 3)
        }
    }

    private func diffText(_ text: String, fill: Color) -> some View {
        Text(text)
            .font(DS.Fonts.mono)
            .foregroundColor(DS.Colors.textPrimary)
            .textSelection(.enabled)
            .fixedSize(horizontal: true, vertical: false)
            .frame(minWidth: 0, alignment: .leading)
            .background(fill)
    }

    private func loadVersions() async {
        let store = store, path = relativePath
        versions = await Task.detached(priority: .userInitiated) { store.versions(of: path) }.value
        if let selected, !versions.contains(selected) { self.selected = nil }
    }

    private func loadDiff() async {
        diff = nil
        diffNote = nil
        guard let version = selected else { return }
        let store = store, folder = folder, path = relativePath
        let outcome: (lines: [MateDiffLine]?, note: String?) = await Task.detached(priority: .userInitiated) {
            guard let oldData = store.data(of: version) else { return (nil, MateFileStoreError.missingVersion.errorDescription) }
            let current = MateFolderGuard.url(forRelative: path, in: folder).flatMap { try? Data(contentsOf: $0) } ?? Data()
            guard let old = MateTextDiff.text(from: oldData), let new = MateTextDiff.text(from: current) else {
                return (nil, "This file is not text, so there is no line diff. Restore puts this version back.")
            }
            if old == new { return (nil, "The file is the same as this version.") }
            return (MateTextDiff.compact(MateTextDiff.lines(old: old, new: new)), nil)
        }.value
        guard !Task.isCancelled else { return }
        diff = outcome.lines
        diffNote = outcome.note
    }

    private func restore() {
        guard let version = pendingRestore else { return }
        pendingRestore = nil
        do {
            try store.restore(version, of: relativePath)
            errorText = nil
            onRestored()
            Task { await loadVersions(); await loadDiff() }
        } catch {
            errorText = error.localizedDescription
        }
    }
}
