import SwiftUI

/// Identifies which coin a sheet or full-screen view is showing.
struct CoinRef: Identifiable, Hashable { let id: String }

/// The purse: the open coin at the top (swipe sideways to flip), and every
/// other coin as a strip below it. Scrolling up and down only ever scrolls.
struct PurseView: View {
    @Environment(AppModel.self) private var model

    /// The coin shown open at the top.
    @State private var frontId: String?
    @State private var viewing: CoinRef?
    @State private var addingNew = false
    @State private var recordingVoice = false
    @State private var showAccount = false
    @State private var showReorder = false
    @State private var pendingDelete: Coin?
    @State private var searching = false
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    /// Search shows up once a purse is big enough to need it.
    private let searchThreshold = 6
    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        Group {
            if model.coins.isEmpty {
                emptyState
            } else if searching && !trimmedQuery.isEmpty {
                searchResults
            } else {
                purse
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .safeAreaInset(edge: .bottom, spacing: 0) { addBar }
        .onAppear { syncFront(old: [], new: model.coins.map(\.id)) }
        .onChange(of: model.coins.map(\.id)) { old, new in syncFront(old: old, new: new) }
        .fullScreenCover(item: $viewing) { ref in
            ViewerView(coinId: ref.id)
        }
        .sheet(isPresented: $addingNew) {
            EditorView(coinId: nil)
        }
        .sheet(isPresented: $recordingVoice) {
            VoiceNoteView()
        }
        .sheet(isPresented: $showAccount) {
            AccountView()
        }
        .sheet(isPresented: $showReorder) {
            ReorderView()
        }
        .alert(
            "Are you sure you want to delete?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { coin in
            Button("Delete", role: .destructive) {
                Task { await model.deleteCoin(coin.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { coin in
            Text("“\(coin.title)” and all of its pictures will be deleted. This cannot be undone.")
        }
    }

    // MARK: Header

    /// "Coin Purse" on the same line as search and account, to save room.
    private var header: some View {
        HStack(spacing: 8) {
            if searching {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search titles and notes", text: $query)
                        .focused($searchFocused)
                        .submitLabel(.search)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("searchField")
                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 40)
                .background(Color.white.opacity(0.1), in: Capsule())
                Button("Cancel") { endSearch() }
                    .padding(.leading, 4)
            } else {
                Text("Coin Purse")
                    .font(.title.bold())
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if model.coins.count >= searchThreshold {
                    Button {
                        searching = true
                        searchFocused = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.title3)
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Search")
                }
                Button { showAccount = true } label: {
                    Image(systemName: "person.crop.circle")
                        .font(.title2)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Account")
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color.black)
    }

    // MARK: Purse

    private var purse: some View {
        let coins = model.coins
        let front = frontId.flatMap { model.coin($0) } ?? coins.first
        let position = (front.flatMap { f in coins.firstIndex { $0.id == f.id } } ?? 0) + 1
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 10) {
                    // Scroll target: the very top of the purse.
                    Color.clear.frame(height: 0).id("top")
                    // The open coin. Swiping sideways flips to the next or previous one.
                    TabView(selection: Binding(get: { front?.id ?? "" }, set: { frontId = $0 })) {
                        ForEach(coins) { coin in
                            openCard(coin, isFront: coin.id == front?.id)
                                .padding(.horizontal, 16)
                                .tag(coin.id)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .frame(height: OpenCard.height)
                    .sensoryFeedback(.selection, trigger: frontId)

                    if coins.count > 1 {
                        Text("\(position) of \(coins.count) · Swipe sideways to flip")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 4)
                    }

                    // Everything else, in your saved order. Tap one to open it at the top.
                    ForEach(coins.filter { $0.id != front?.id }) { coin in
                        strip(coin) {
                            frontId = coin.id
                            // Scroll up once the list has updated, so the coin you
                            // tapped is right there at the top.
                            DispatchQueue.main.async {
                                withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo("top", anchor: .top) }
                            }
                        }
                    }
                }
                .padding(.top, 4)
                .padding(.bottom, 16)
            }
            .refreshable { await model.refresh() }
        }
    }

    private func openCard(_ coin: Coin, isFront: Bool) -> some View {
        VStack(spacing: 0) {
            CoinCardHeader(coin: coin) { pendingDelete = coin }
            Group {
                if coin.pictures.isEmpty {
                    NoteFace(notes: coin.notes)
                } else {
                    CachedImage(picture: coin.pictures.first)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: OpenCard.pictureHeight)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 14)
            Text(coin.pictures.count > 1 ? "\(coin.pictures.count) pictures · Tap to open"
                 : coin.pictures.isEmpty ? "Tap to open" : "Tap to open full screen")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 12)
        }
        .cardBackground(coin.accentColor)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(isFront ? "frontCard" : "card")
        .onTapGesture { viewing = CoinRef(id: coin.id) }
        .onLongPressGesture { startReorder() }
    }

    private func strip(_ coin: Coin, onTap: @escaping () -> Void) -> some View {
        CoinCardHeader(coin: coin) { pendingDelete = coin }
            .cardBackground(coin.accentColor)
            .contentShape(Rectangle())
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("strip")
            .padding(.horizontal, 16)
            .onTapGesture(perform: onTap)
            .onLongPressGesture { startReorder() }
    }

    // MARK: Search

    private var searchResults: some View {
        let q = trimmedQuery
        let results = model.coins.filter {
            $0.title.localizedStandardContains(q) || $0.notes.localizedStandardContains(q)
        }
        return Group {
            if results.isEmpty {
                ContentUnavailableView.search(text: q)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(results) { coin in
                            strip(coin) {
                                frontId = coin.id
                                endSearch()
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
                .scrollDismissesKeyboard(.immediately)
            }
        }
    }

    private func endSearch() {
        searching = false
        searchFocused = false
        query = ""
    }

    // MARK: Order

    /// New coins open at the top. When the open coin is deleted, the next one
    /// in the purse takes its place.
    private func syncFront(old: [String], new: [String]) {
        let known = Set(old)
        if !old.isEmpty, let added = new.first(where: { !known.contains($0) }) {
            frontId = added
            return
        }
        if let current = frontId, new.contains(current) { return }
        if let current = frontId, let i = old.firstIndex(of: current) {
            // The coin after it in the old order, or the one before at the end.
            let after = old[(i + 1)...].first { new.contains($0) }
            let before = old[..<i].last { new.contains($0) }
            frontId = after ?? before ?? new.first
        } else {
            frontId = new.first
        }
    }

    private func startReorder() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        showReorder = true
    }

    // MARK: Add

    /// Two big buttons where your thumb is: a picture coin or a voice note.
    private var addBar: some View {
        HStack(spacing: 12) {
            Button { addingNew = true } label: {
                Label("Add Coin", systemImage: "plus")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("addCoin")
            Button { recordingVoice = true } label: {
                Label("Voice Note", systemImage: "mic.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.bordered)
            .tint(.white)
            .accessibilityIdentifier("voiceNote")
        }
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 6)
        .background {
            // Coins scroll under the bar and fade out instead of being cut off.
            LinearGradient(colors: [.black.opacity(0), .black.opacity(0.92), .black], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        }
    }

    // MARK: Empty

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image("Logo")
                .resizable()
                .scaledToFit()
                .frame(width: 80, height: 80)
                .opacity(0.85)
                .accessibilityHidden(true)
            Text("Purse is empty")
                .font(.title2.bold())
            Text("Snap or paste a QR code, a ticket or a gift card with Add Coin.  Or tap Voice Note and say a quick note or reminder.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(maxHeight: .infinity)
    }
}

enum OpenCard {
    static let pictureHeight: CGFloat = 380
    /// Header strip, picture and the "Tap to open" line.
    static let height: CGFloat = CardMetrics.peek + pictureHeight + 44
}

/// Long-press opens this: drag the handles to set the saved order.
struct ReorderView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var ids: [String] = []

    var body: some View {
        NavigationStack {
            List {
                ForEach(ids, id: \.self) { id in
                    if let coin = model.coin(id) {
                        HStack(spacing: 12) {
                            Circle().fill(coin.accentColor).frame(width: 10, height: 10)
                            Text(coin.title)
                        }
                    }
                }
                .onMove { from, to in ids.move(fromOffsets: from, toOffset: to) }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Rearrange")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        let newOrder = ids
                        dismiss()
                        if newOrder != model.coins.map(\.id) {
                            Task { await model.reorder(newOrder) }
                        }
                    }
                    .bold()
                }
            }
        }
        .onAppear { ids = model.coins.map(\.id) }
    }
}

/// The front of a coin with no picture: its text, like a note card.
struct NoteFace: View {
    let notes: String

    /// A code or a few words shows big; longer notes get smaller type.
    private var font: Font {
        switch notes.count {
        case ..<25: return .system(size: 40, weight: .bold)
        case ..<90: return .title.weight(.semibold)
        default: return .title3.weight(.medium)
        }
    }

    var body: some View {
        Text(notes)
            .font(font)
            .foregroundStyle(.white.opacity(0.92))
            .lineSpacing(4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(18)
            .background(Color.white.opacity(0.05))
            // Long notes fade out at the bottom; tap to read them all.
            .mask(LinearGradient(stops: [.init(color: .black, location: 0.8), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
    }
}
