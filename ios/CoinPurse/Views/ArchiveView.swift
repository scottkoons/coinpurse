import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

/// A place in the Archive: a folder, or an open coin.
enum ArchiveRoute: Hashable {
    case folder(String)
    case coin(String)
}

/// A coin pressed, held and dragged onto a folder in the Archive. Only this
/// app accepts it.
nonisolated struct DraggedCoin: Codable, Transferable {
    let id: String
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .coinPurseCoin)
    }
}

extension UTType {
    nonisolated static let coinPurseCoin = UTType(exportedAs: "com.yetignome.coinpurse.coin")
}

/// Moving rows in the Archive by their handle (≡): followed here, the row
/// moves with the finger at once, the others make room, and a coin can go
/// onto a folder or, inside a folder, onto "Take out of". (A coin can also be
/// pressed, held and dragged onto a folder: the system's drag, which shares the
/// press with the menu, so it does not move rows.)
@Observable
final class ArchiveDrag {
    enum Item: Hashable {
        case coin(String)
        case folder(String)
    }
    /// Where rows and the finger are measured: the list's own space, so they
    /// agree even while the Archive slides up or a folder slides in.
    nonisolated static let space = "archiveDrag"

    /// The row being moved by its handle.
    private(set) var moving: Item?
    /// Where that row's top is now, in the list.
    private(set) var top: CGFloat = 0
    /// The folder it is over (a coin let go there goes in it).
    private(set) var hoveredFolder: String?
    /// Over "Take out of" in a folder.
    private(set) var overTakeOut = false

    /// Where each row is in the list (kept up to date by the rows; nothing is
    /// redrawn when they change).
    @ObservationIgnored var frames: [Item: CGRect] = [:]
    /// Where "Take out of" is, while it shows.
    @ObservationIgnored var takeOutFrame: CGRect?
    /// The finger's height on the row when it was picked up.
    @ObservationIgnored private var grab: CGFloat = 0
    /// The rows it moves among, in their order as shown.
    @ObservationIgnored private var order: [Item] = []
    /// Folders it can be let go on (only in the Archive, not in a folder).
    @ObservationIgnored private var folders: [String] = []

    func begin(_ item: Item, at y: CGFloat, order: [Item], folders: [String]) {
        guard moving == nil, let frame = frames[item] else { return }
        self.order = order
        self.folders = folders
        grab = y - frame.minY
        top = frame.minY
        // Animated: in a folder, "Take out of" slides in at the bottom.
        withAnimation(.snappy(duration: 0.25)) { moving = item }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    func move(to y: CGFloat, model: AppModel) {
        guard let item = moving, let frame = frames[item] else { return }
        top = y - grab
        if case .coin = item {
            let folder = folders.first { name in frames[.folder(name)].map { y >= $0.minY && y <= $0.maxY } ?? false }
            let out = takeOutFrame.map { y >= $0.minY } ?? false
            if folder != hoveredFolder || out != overTakeOut {
                hoveredFolder = folder
                overTakeOut = out
                if folder != nil || out { UISelectionFeedbackGenerator().selectionChanged() }
            }
            // Over a folder or "Take out of", the list stays as it is.
            if folder != nil || out { return }
        }
        // A little past the middle of the row below (or above), it takes that
        // row's place (the little more keeps it from going back and forth).
        let center = top + frame.height / 2
        let margin: CGFloat = 6
        guard let i = order.firstIndex(of: item) else { return }
        let other: Int
        if i + 1 < order.count, let next = frames[order[i + 1]], center > next.midY + margin {
            other = i + 1
        } else if i > 0, let previous = frames[order[i - 1]], center < previous.midY - margin {
            other = i - 1
        } else {
            return
        }
        let target = order[other]
        order.swapAt(i, other)
        UISelectionFeedbackGenerator().selectionChanged()
        withAnimation(.snappy(duration: 0.25)) {
            switch (item, target) {
            case let (.coin(a), .coin(b)): model.moveArchived(a, to: b)
            case let (.folder(a), .folder(b)): model.moveFolder(a, to: b)
            default: break
            }
        }
    }

    func end(model: AppModel) {
        guard let item = moving else { return }
        if case .coin(let id) = item, hoveredFolder != nil || overTakeOut {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            // Into the folder, or out of the one it is in.
            withAnimation { model.moveToFolder(id, hoveredFolder) }
        }
        let goesIn = hoveredFolder != nil || overTakeOut
        hoveredFolder = nil
        overTakeOut = false
        // It settles into its place, then the row there shows again. (One that
        // went in or out of a folder simply fades.)
        if !goesIn, let frame = frames[item] {
            withAnimation(.snappy(duration: 0.2)) { top = frame.minY }
        }
        Task {
            try? await Task.sleep(for: .seconds(goesIn ? 0 : 0.2))
            moving = nil
        }
    }
}

/// The ≡ at the end of a row: touch and drag it to move the row, at once.
/// (VoiceOver has Move up and Move down instead.)
struct DragHandle: View {
    @Environment(AppModel.self) private var model
    @Environment(ArchiveDrag.self) private var drag
    let item: ArchiveDrag.Item
    let order: [ArchiveDrag.Item]
    let folders: [String]

    var body: some View {
        Image(systemName: "line.3.horizontal")
            .accessibilityHidden(true)
            .font(.body.weight(.semibold))
            .foregroundStyle(.tertiary)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .padding(.trailing, 6)
            // Before the list can scroll: the row moves, the list stays.
            .highPriorityGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(ArchiveDrag.space))
                    .onChanged { value in
                        if drag.moving == nil {
                            drag.begin(item, at: value.startLocation.y, order: order, folders: folders)
                        }
                        drag.move(to: value.location.y, model: model)
                    }
                    .onEnded { _ in drag.end(model: model) }
            )
            .accessibilityHidden(true)
    }
}

/// The row being moved by its handle, drawn above the list under the finger
/// (its own place in the list stays empty, showing where it will go).
struct MovingRow: View {
    @Environment(AppModel.self) private var model
    @Environment(ArchiveDrag.self) private var drag

    var body: some View {
        GeometryReader { proxy in
            if let item = drag.moving, let frame = drag.frames[item] {
                let origin = proxy.frame(in: .named(ArchiveDrag.space)).origin
                content(item)
                    .frame(width: frame.width, height: frame.height)
                    .background(Color(.secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
                    .scaleEffect(1.03)
                    .offset(x: frame.minX - origin.x, y: drag.top - origin.y)
                    .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func content(_ item: ArchiveDrag.Item) -> some View {
        HStack(spacing: 0) {
            switch item {
            case .coin(let id):
                if let coin = model.coin(id) {
                    ArchiveRow(coin: coin, veiled: model.isVeiled(coin))
                        .padding(.horizontal, 16)
                }
            case .folder(let name):
                ArchiveFolderLabel(name: name, count: model.folders.first { $0.name == name }?.count ?? 0, lit: false)
                    .padding(.horizontal, 16)
            }
            Spacer(minLength: 0)
            Image(systemName: "line.3.horizontal")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .padding(.trailing, 6)
        }
        .foregroundStyle(.primary)
    }
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
    /// The New Folder button's name alert is up.
    @State private var creatingFolder = false
    @State private var typedName = ""
    @State private var drag = ArchiveDrag()
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
                    if trimmed.isEmpty {
                        NewFolderButton {
                            typedName = ""
                            creatingFolder = true
                        }
                        .padding(.top, 12)
                    }
                    if !shownFolders.isEmpty {
                        ArchiveGroup(title: "Folders") {
                            ForEach(Array(shownFolders.enumerated()), id: \.element.name) { i, folder in
                                if i > 0 { RowDivider() }
                                ArchiveFolderRow(
                                    folder: folder,
                                    order: shownFolders.map { .folder($0.name) },
                                    above: i > 0 ? shownFolders[i - 1].name : nil,
                                    below: i + 1 < shownFolders.count ? shownFolders[i + 1].name : nil,
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
                            ArchivedCoinRows(coins: shownCoins, folders: shownFolders.map(\.name), actions: actions)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .overlay { MovingRow() }
            .coordinateSpace(.named(ArchiveDrag.space))
            .overlay {
                if model.archive.isEmpty && model.folders.isEmpty {
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
        .environment(drag)
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
        .alert("New Folder", isPresented: $creatingFolder) {
            TextField("Folder name", text: $typedName)
                .textInputAutocapitalization(.words)
                .accessibilityIdentifier("folderName")
            Button("Cancel", role: .cancel) {}
            Button("Create") { withAnimation { model.addFolder(typedName) } }
                .disabled(Coin.folderName(typedName) == nil)
        } message: {
            Text("Drag coins onto it to put them in it.")
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

/// At the top of the Archive: a folder, empty, ready for coins.
struct NewFolderButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("New Folder", systemImage: "folder.badge.plus")
                .font(.body.weight(.semibold))
                .padding(.horizontal, 18)
                .frame(minHeight: 44)
                .contentShape(Capsule())
        }
        .foregroundStyle(Color.accentColor)
        .glassCapsule()
        .accessibilityIdentifier("newFolder")
    }
}

/// One folder in the Archive: tap to open it, drop a coin on it to put the
/// coin in it, press and hold to rename or remove it, or drag its handle up or
/// down to a new place.
struct ArchiveFolderRow: View {
    @Environment(AppModel.self) private var model
    @Environment(ArchiveDrag.self) private var drag
    let folder: ArchiveFolder
    /// The folders shown, for its handle.
    let order: [ArchiveDrag.Item]
    /// The folders before and after it, for VoiceOver's Move up and Move down.
    let above: String?
    let below: String?
    let onRename: () -> Void
    let onRemove: () -> Void
    /// A dragged coin is over it.
    @State private var targeted = false

    /// A coin moved by its handle, or dragged, is over it.
    private var lit: Bool { targeted || drag.hoveredFolder == folder.name }

    var body: some View {
        HStack(spacing: 0) {
            link
            DragHandle(item: .folder(folder.name), order: order, folders: [])
        }
        // Lights up while a dragged coin is over it.
        .background(lit ? Color.accentColor.opacity(0.22) : Color.clear)
        .opacity(drag.moving == .folder(folder.name) ? 0 : 1)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(ArchiveDrag.space)) } action: { drag.frames[.folder(folder.name)] = $0 }
        .dropDestination(for: DraggedCoin.self) { items, _ in
            guard let id = items.first?.id else { return false }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation { model.moveToFolder(id, folder.name) }
            return true
        } isTargeted: { targeted = $0 }
    }

    private var link: some View {
        NavigationLink(value: ArchiveRoute.folder(folder.name)) {
            ArchiveFolderLabel(name: folder.name, count: folder.count, lit: lit)
        }
        .buttonStyle(ArchiveRowStyle())
        .foregroundStyle(.primary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(folder.name), \(folder.count) \(folder.count == 1 ? "coin" : "coins")")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("archiveFolder")
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contextMenu {
            Button("Rename…", systemImage: "pencil", action: onRename)
            Button("Remove Folder", systemImage: "folder.badge.minus", action: onRemove)
        }
        .accessibilityAction(named: "Rename") { onRename() }
        .accessibilityAction(named: "Remove Folder") { onRemove() }
        .accessibilityActions {
            if let above {
                Button("Move up") { withAnimation { model.moveFolder(folder.name, to: above) } }
            }
            if let below {
                Button("Move down") { withAnimation { model.moveFolder(folder.name, to: below) } }
            }
        }
    }
}

/// A folder's icon, name and how many coins it holds.
struct ArchiveFolderLabel: View {
    let name: String
    let count: Int
    let lit: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: lit ? "folder.fill" : "folder")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 30)
            Text(name)
                .font(.body.weight(.semibold))
                .lineLimit(2)
            Spacer(minLength: 8)
            Text("\(count)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
    }
}

/// The coins in one folder.
struct ArchiveFolderView: View {
    @Environment(AppModel.self) private var model
    @Environment(ArchiveDrag.self) private var drag
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
                        ArchivedCoinRows(coins: shown, folders: [], actions: actions)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        // While a coin is moved by its handle: let it go here, at the bottom,
        // to take it out. The coins stay where they are, none under it.
        .safeAreaInset(edge: .bottom) {
            if case .coin? = drag.moving {
                TakeOutBar(folder: name)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay { MovingRow() }
        .coordinateSpace(.named(ArchiveDrag.space))
        .overlay {
            if !q.isEmpty && shown.isEmpty {
                ContentUnavailableView.search(text: query)
            } else if inFolder.isEmpty {
                ContentUnavailableView(
                    "No coins in this folder",
                    systemImage: "folder",
                    description: Text("In the Archive, drag a coin onto this folder, or press and hold a coin and choose this folder.")
                )
            }
        }
        .background(PurseBackground().ignoresSafeArea())
        .searchable(text: $query, prompt: "Search \(name)")
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done", action: actions.close) }
        }
        .safeAreaInset(edge: .bottom) { UndoBar().padding(.bottom, 8) }
        // The folder was removed or renamed: back to the Archive.
        .onChange(of: model.folders.contains { $0.name == name }) { _, there in
            if !there { actions.leaveFolder(name) }
        }
    }
}

/// Inside a folder, while a coin is moved by its handle: let it go here and it
/// goes back in the Archive, out of the folder.
struct TakeOutBar: View {
    @Environment(ArchiveDrag.self) private var drag
    let folder: String

    var body: some View {
        Label("Take out of \(folder)", systemImage: "folder.badge.minus")
            .font(.body.weight(.semibold))
            .foregroundStyle(drag.overTakeOut ? Color.white : Color.accentColor)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(drag.overTakeOut ? Color.accentColor : Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4])))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(ArchiveDrag.space)) } action: { drag.takeOutFrame = $0 }
            .onDisappear { drag.takeOutFrame = nil }
            .accessibilityHidden(true)
    }
}

/// Archived coins, with a line between each two.
struct ArchivedCoinRows: View {
    let coins: [Coin]
    /// The folders shown above them, where one moved by its handle can go.
    let folders: [String]
    let actions: ArchiveActions

    var body: some View {
        let order = coins.map { ArchiveDrag.Item.coin($0.id) }
        ForEach(Array(coins.enumerated()), id: \.element.id) { i, coin in
            if i > 0 { RowDivider() }
            ArchivedCoinRow(
                coin: coin,
                order: order,
                folders: folders,
                above: i > 0 ? coins[i - 1].id : nil,
                below: i + 1 < coins.count ? coins[i + 1].id : nil,
                actions: actions
            )
        }
    }
}

/// An archived coin: tap to open it, press and hold for its menu (Move to
/// Folder, Unarchive, Delete), drag its handle up or down to a new place or
/// onto a folder, or press, hold and drag it onto a folder.
struct ArchivedCoinRow: View {
    @Environment(AppModel.self) private var model
    @Environment(ArchiveDrag.self) private var drag
    let coin: Coin
    /// The coins shown and the folders above them, for its handle.
    let order: [ArchiveDrag.Item]
    let folders: [String]
    /// The coins shown before and after it, for VoiceOver's Move up and Move down.
    let above: String?
    let below: String?
    let actions: ArchiveActions

    var body: some View {
        HStack(spacing: 0) {
            button
            DragHandle(item: .coin(coin.id), order: order, folders: folders)
        }
        .opacity(drag.moving == .coin(coin.id) ? 0 : 1)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(ArchiveDrag.space)) } action: { drag.frames[.coin(coin.id)] = $0 }
    }

    private var button: some View {
        Button { actions.open(coin) } label: {
            ArchiveRow(coin: coin, veiled: model.isVeiled(coin))
        }
        .buttonStyle(ArchiveRowStyle())
        .foregroundStyle(.primary)
        .accessibilityIdentifier("archivedCoin")
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(.dragPreview, RoundedRectangle(cornerRadius: 16, style: .continuous))
        // Press, hold and drag onto a folder.
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
        .accessibilityActions {
            if let above {
                Button("Move up") { withAnimation { model.moveArchived(coin.id, to: above) } }
            }
            if let below {
                Button("Move down") { withAnimation { model.moveArchived(coin.id, to: below) } }
            }
        }
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
                // Two Texts: in one with `veiled ? … : preview`, the picture
                // became plain words ("Image(provider: …)").
                Group {
                    if veiled {
                        Text("\(Image(systemName: "faceid")) Face ID")
                    } else {
                        Text(preview)
                    }
                }
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
