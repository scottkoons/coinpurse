import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

/// A place in the Archive: a folder, or an open coin.
enum ArchiveRoute: Hashable {
    case folder(String)
    case coin(String)
}

/// A coin dragged onto a folder in the Archive. Only this app accepts it.
nonisolated struct DraggedCoin: Codable, Transferable {
    let id: String
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .coinPurseCoin)
    }
}

extension UTType {
    nonisolated static let coinPurseCoin = UTType(exportedAs: "com.yetignome.coinpurse.coin")
}

/// What an archived coin's row can ask the Archive to do.
struct ArchiveActions {
    var open: (Coin) -> Void
    var delete: (Coin) -> Void
    var newFolder: (Coin) -> Void
    /// A folder was emptied while it was showing.
    var leaveFolder: (String) -> Void
    var close: () -> Void
}

/// Coins put away: out of the purse, kept for the day they are needed (the
/// neighbor's garage code, a lockbox combination). View one, put it back in
/// the purse, or delete it. Coins can go in folders, like "Home lights".
///
/// Not a List: a drag that starts in a List never reaches a drop target, so
/// coins could not be dragged onto folders. The page is drawn to look like one.
struct ArchiveView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// Opened from a search in the purse: straight to this coin.
    var startWith: String?
    @State private var query = ""
    @State private var path: [ArchiveRoute] = []
    @State private var pendingDelete: Coin?
    /// The coin going in a new folder, while the folder's name is typed.
    @State private var naming: Coin?
    /// The folder being renamed.
    @State private var renaming: String?
    @State private var typedName = ""
    @Namespace private var cards

    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }

    /// Folders, or those whose name matches the search.
    private var shownFolders: [ArchiveFolder] {
        trimmed.isEmpty ? model.folders : model.folders.filter { $0.name.localizedStandardContains(trimmed) }
    }

    /// Coins in no folder; when searching, every match, in a folder or not.
    private var shownCoins: [Coin] {
        trimmed.isEmpty ? model.archive.filter { $0.folder == nil } : model.archive.filter { $0.matches(trimmed) }
    }

    /// The coin open now, if one is.
    private var openCoinId: String? {
        if case .coin(let id)? = path.last { id } else { nil }
    }

    private var actions: ArchiveActions {
        ArchiveActions(
            open: open,
            delete: askToDelete,
            newFolder: { coin in
                typedName = ""
                naming = coin
            },
            leaveFolder: { name in
                if let i = path.firstIndex(of: .folder(name)) { path.removeSubrange(i...) }
            },
            close: { dismiss() }
        )
    }

    /// A hidden coin asks for Face ID before "Are you sure".
    private func askToDelete(_ coin: Coin) {
        Task { if await model.mayDelete(coin) { pendingDelete = coin } }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !shownFolders.isEmpty {
                        ArchiveGroup(title: "Folders") {
                            ForEach(shownFolders, id: \.name) { folder in
                                if folder.name != shownFolders.first?.name { RowDivider() }
                                ArchiveFolderRow(
                                    folder: folder,
                                    onRename: {
                                        typedName = folder.name
                                        renaming = folder.name
                                    },
                                    onRemove: { withAnimation { model.renameFolder(folder.name, to: nil) } }
                                )
                            }
                        }
                    }
                    if !shownCoins.isEmpty {
                        ArchiveGroup(title: shownFolders.isEmpty ? nil : "Coins") {
                            ArchivedCoinRows(coins: shownCoins, actions: actions)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .overlay {
                if model.archive.isEmpty {
                    ContentUnavailableView(
                        "Nothing archived",
                        systemImage: "archivebox",
                        description: Text("Archive a coin to keep it out of your purse until you need it, like a gate code you use once a year.")
                    )
                } else if shownCoins.isEmpty && shownFolders.isEmpty && !trimmed.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            // The purse's soft background behind the list.
            .background(PurseBackground().ignoresSafeArea())
            .searchable(text: $query, prompt: "Search archived coins")
            .navigationTitle("Archive")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .navigationDestination(for: ArchiveRoute.self) { route in
                switch route {
                case .folder(let name):
                    ArchiveFolderView(name: name, actions: actions)
                case .coin(let id):
                    coinDetail(id)
                }
            }
            .safeAreaInset(edge: .bottom) { UndoBar().padding(.bottom, 8) }
        }
        // On the whole stack, so they also show over a folder.
        .alert(
            "Are you sure you want to delete?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { coin in
            Button("Delete", role: .destructive) { model.deleteWithUndo(coin.id) }
            Button("Cancel", role: .cancel) {}
        } message: { coin in
            Text("“\(coin.title)” and everything in it will be deleted.")
        }
        .alert(
            "New Folder",
            isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } }),
            presenting: naming
        ) { coin in
            TextField("Folder name", text: $typedName)
                .textInputAutocapitalization(.words)
                .accessibilityIdentifier("folderName")
            Button("Cancel", role: .cancel) {}
            Button("Move") {
                if let name = model.folderName(for: typedName) {
                    withAnimation { model.moveToFolder(coin.id, name) }
                }
            }
            .disabled(Coin.folderName(typedName) == nil)
        } message: { coin in
            Text("“\(coin.title.isEmpty ? "Untitled" : coin.title)” goes in it.")
        }
        .alert(
            "Rename Folder",
            isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }),
            presenting: renaming
        ) { old in
            TextField("Folder name", text: $typedName)
                .textInputAutocapitalization(.words)
                .accessibilityIdentifier("folderName")
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                // Only its capitals changed: keep the new spelling.
                let new = typedName.trimmingCharacters(in: .whitespacesAndNewlines)
                    .compare(old, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                    ? Coin.folderName(typedName) : model.folderName(for: typedName)
                if let new { withAnimation { model.renameFolder(old, to: new) } }
            }
            .disabled(Coin.folderName(typedName) == nil)
        }
        // Leaving the app covers hidden coins again, including one left open.
        .onChange(of: model.revealed) { _, _ in
            if let id = openCoinId, let coin = model.coin(id), model.isVeiled(coin) { closeCoin() }
        }
        // Closed again, a hidden coin asks for Face ID the next time.
        .onChange(of: openCoinId) { _, id in model.keepRevealed(only: id) }
        // Again when iPhone Search asks for another coin while this is open.
        .task(id: startWith) {
            if let startWith, let coin = model.coin(startWith) {
                guard await model.reveal(coin) else { return }
                path = [.coin(coin.id)]
            }
        }
    }

    @ViewBuilder
    private func coinDetail(_ id: String) -> some View {
        if let coin = model.coin(id) {
            CoinDetailView(
                coin: coin,
                namespace: cards,
                pile: [],
                onClose: { closeCoin() },
                onDelete: {
                    closeCoin()
                    model.deleteWithUndo(id)
                },
                onSelect: { _ in },
                onArchive: {
                    // Back in the purse, in front.
                    closeCoin()
                    model.unarchive(id)
                }
            )
            .toolbar(.hidden, for: .navigationBar)
            .background(PurseBackground().ignoresSafeArea())
        }
    }

    /// Back to the list (or folder) it was opened from.
    private func closeCoin() {
        if case .coin? = path.last { path.removeLast() }
    }

    /// A hidden coin opens only after Face ID.
    private func open(_ coin: Coin) {
        Task {
            guard await model.reveal(coin) else { return }
            if case .coin? = path.last { path.removeLast() }
            path.append(.coin(coin.id))
        }
    }
}

/// A rounded group of rows with an optional heading, like a grouped list.
struct ArchiveGroup<Content: View>: View {
    let title: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 16)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(spacing: 0) { content }
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .padding(.top, 20)
    }
}

/// The thin line between two rows.
struct RowDivider: View {
    var body: some View {
        Divider().padding(.leading, 58)
    }
}

/// A row that darkens a little while pressed, like a list row.
struct ArchiveRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .contentShape(Rectangle())
            .background(configuration.isPressed ? Color(.systemGray4) : Color.clear)
    }
}

/// One folder in the Archive: tap to open it, drop a coin on it to put the
/// coin in it, or press and hold to rename or remove it.
struct ArchiveFolderRow: View {
    @Environment(AppModel.self) private var model
    let folder: ArchiveFolder
    let onRename: () -> Void
    let onRemove: () -> Void
    /// A dragged coin is over it.
    @State private var targeted = false

    var body: some View {
        NavigationLink(value: ArchiveRoute.folder(folder.name)) {
            HStack(spacing: 12) {
                Image(systemName: targeted ? "folder.fill" : "folder")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 30)
                Text(folder.name)
                    .font(.body.weight(.semibold))
                    .lineLimit(2)
                Spacer(minLength: 8)
                Text("\(folder.count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(ArchiveRowStyle())
        .foregroundStyle(.primary)
        // Lights up while a dragged coin is over it.
        .background(targeted ? Color.accentColor.opacity(0.22) : Color.clear)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(folder.name), \(folder.count) \(folder.count == 1 ? "coin" : "coins")")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("archiveFolder")
        .dropDestination(for: DraggedCoin.self) { items, _ in
            guard let id = items.first?.id else { return false }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation { model.moveToFolder(id, folder.name) }
            return true
        } isTargeted: { targeted = $0 }
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contextMenu {
            Button("Rename…", systemImage: "pencil", action: onRename)
            Button("Remove Folder", systemImage: "folder.badge.minus", action: onRemove)
        }
        .accessibilityAction(named: "Rename") { onRename() }
        .accessibilityAction(named: "Remove Folder") { onRemove() }
    }
}

/// The coins in one folder.
struct ArchiveFolderView: View {
    @Environment(AppModel.self) private var model
    let name: String
    let actions: ArchiveActions
    @State private var query = ""

    private var inFolder: [Coin] { model.archive.filter { $0.folder == name } }

    var body: some View {
        let q = query.trimmingCharacters(in: .whitespaces)
        let shown = q.isEmpty ? inFolder : inFolder.filter { $0.matches(q) }
        ScrollView {
            LazyVStack(spacing: 0) {
                if !shown.isEmpty {
                    ArchiveGroup(title: nil) {
                        ArchivedCoinRows(coins: shown, actions: actions)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .overlay {
            if !q.isEmpty && shown.isEmpty { ContentUnavailableView.search(text: query) }
        }
        .background(PurseBackground().ignoresSafeArea())
        .searchable(text: $query, prompt: "Search \(name)")
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done", action: actions.close) }
        }
        .safeAreaInset(edge: .bottom) { UndoBar().padding(.bottom, 8) }
        // Its last coin left (moved, unarchived or deleted): back to the Archive.
        .onChange(of: inFolder.isEmpty) { _, empty in
            if empty { actions.leaveFolder(name) }
        }
    }
}

/// Archived coins, with a line between each two.
struct ArchivedCoinRows: View {
    let coins: [Coin]
    let actions: ArchiveActions

    var body: some View {
        ForEach(coins) { coin in
            if coin.id != coins.first?.id { RowDivider() }
            ArchivedCoinRow(coin: coin, actions: actions)
        }
    }
}

/// An archived coin: tap to open it, press and hold for its menu (Move to
/// Folder, Unarchive, Delete), or drag it onto a folder.
struct ArchivedCoinRow: View {
    @Environment(AppModel.self) private var model
    let coin: Coin
    let actions: ArchiveActions

    var body: some View {
        Button { actions.open(coin) } label: {
            ArchiveRow(coin: coin, veiled: model.isVeiled(coin))
        }
        .buttonStyle(ArchiveRowStyle())
        .foregroundStyle(.primary)
        .accessibilityIdentifier("archivedCoin")
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(.dragPreview, RoundedRectangle(cornerRadius: 16, style: .continuous))
        .draggable(DraggedCoin(id: coin.id))
        .contextMenu {
            Section("Move to Folder") {
                ForEach(model.folders, id: \.name) { folder in
                    Button(folder.name, systemImage: folder.name == coin.folder ? "checkmark" : "folder") {
                        withAnimation { model.moveToFolder(coin.id, folder.name) }
                    }
                }
                Button("New Folder…", systemImage: "folder.badge.plus") { actions.newFolder(coin) }
                if coin.folder != nil {
                    Button("Remove from Folder", systemImage: "folder.badge.minus") {
                        withAnimation { model.moveToFolder(coin.id, nil) }
                    }
                }
            }
            Section {
                Button("Unarchive", systemImage: "tray.and.arrow.up") {
                    withAnimation { model.unarchive(coin.id) }
                }
                Button("Delete", systemImage: "trash", role: .destructive) { actions.delete(coin) }
            }
        }
        .accessibilityAction(named: "Unarchive") { model.unarchive(coin.id) }
        .accessibilityAction(named: "Delete") { actions.delete(coin) }
    }
}

/// One archived coin in a list: its color, title and the start of its note
/// (or "Hidden").
struct ArchiveRow: View {
    let coin: Coin
    let veiled: Bool

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(LinearGradient(colors: [AccentPalette.cardColors(coin.accent).top, AccentPalette.cardColors(coin.accent).bottom],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 30, height: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(coin.title.isEmpty ? "Untitled" : coin.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(2)
                Text(veiled ? "\(Image(systemName: "faceid")) Face ID" : preview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var preview: String {
        let firstLine = coin.notes.split(separator: "\n").first.map(String.init) ?? ""
        if !firstLine.isEmpty { return firstLine }
        if coin.pin != nil { return "Map pin" }
        let n = coin.pictures.count
        return n == 0 ? "" : n == 1 ? "1 picture" : "\(n) pictures"
    }
}

/// For a few seconds after a coin is deleted or archived: what happened, and Undo.
struct UndoBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let coin = model.undoable {
            HStack(spacing: 12) {
                Text("\(model.undoArchives ? "Archived" : "Deleted") “\(coin.title)”")
                    .font(.subheadline)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button("Undo") {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) { model.undoLast() }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.barAction)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityIdentifier("undoDelete")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 2)
            // Solid, not see-through: it sits over the colorful front card, and
            // its buttons must stay easy to read on any card color.
            .background(Color(.secondarySystemBackground), in: Capsule())
            .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
            .padding(.horizontal, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
