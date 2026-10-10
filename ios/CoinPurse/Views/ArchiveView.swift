import SwiftUI

/// Coins put away: out of the purse, kept for the day they are needed (the
/// neighbor's garage code, a lockbox combination). View one, put it back in
/// the purse, or delete it.
struct ArchiveView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// Opened from a search in the purse: straight to this coin.
    var startWith: String?
    @State private var query = ""
    @State private var path: [String] = []
    @State private var pendingDelete: Coin?
    @Namespace private var cards

    private var shown: [Coin] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? model.archive : model.archive.filter { $0.matches(q) }
    }

    /// A coin hidden with Face ID asks for Face ID before "Are you sure".
    private func askToDelete(_ coin: Coin) {
        Task { if await model.mayDelete(coin) { pendingDelete = coin } }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                ForEach(shown) { coin in
                    Button { open(coin) } label: {
                        ArchiveRow(coin: coin, veiled: model.isVeiled(coin))
                    }
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("archivedCoin")
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("Delete", systemImage: "trash", role: .destructive) { askToDelete(coin) }
                        Button("Unarchive", systemImage: "tray.and.arrow.up") {
                            withAnimation { model.unarchive(coin.id) }
                        }
                        .tint(.indigo)
                    }
                    .accessibilityAction(named: "Unarchive") { model.unarchive(coin.id) }
                    .accessibilityAction(named: "Delete") { askToDelete(coin) }
                }
            }
            .overlay {
                if model.archive.isEmpty {
                    ContentUnavailableView(
                        "Nothing archived",
                        systemImage: "archivebox",
                        description: Text("Archive a coin to keep it out of your purse until you need it, like a gate code you use once a year.")
                    )
                } else if shown.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .searchable(text: $query, prompt: "Search archived coins")
            .navigationTitle("Archive")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .navigationDestination(for: String.self) { id in
                if let coin = model.coin(id) {
                    CoinDetailView(
                        coin: coin,
                        namespace: cards,
                        pile: [],
                        onClose: { path.removeAll() },
                        onDelete: {
                            path.removeAll()
                            model.deleteWithUndo(id)
                        },
                        onSelect: { _ in },
                        onArchive: {
                            // Back in the purse, on top.
                            path.removeAll()
                            model.unarchive(id)
                        }
                    )
                    .toolbar(.hidden, for: .navigationBar)
                    .background(Color(.systemBackground))
                }
            }
            .safeAreaInset(edge: .bottom) { UndoBar().padding(.bottom, 8) }
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
        }
        // Leaving the app covers hidden coins again, including one left open.
        .onChange(of: model.revealed) { _, _ in
            if let id = path.last, let coin = model.coin(id), model.isVeiled(coin) { path.removeAll() }
        }
        // Closed again, a hidden coin asks for Face ID the next time.
        .onChange(of: path) { _, path in model.keepRevealed(only: path.last) }
        .task {
            if let startWith, let coin = model.coin(startWith) { open(coin) }
        }
    }

    /// A hidden coin opens only after Face ID.
    private func open(_ coin: Coin) {
        Task {
            guard await model.reveal(coin) else { return }
            path = [coin.id]
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
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityIdentifier("undoDelete")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 2)
            .background(.thinMaterial, in: Capsule())
            .padding(.horizontal, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
