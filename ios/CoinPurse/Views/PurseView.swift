import SwiftUI

/// Identifies which coin a sheet or full-screen view is showing.
struct CoinRef: Identifiable, Hashable { let id: String }

/// The wallet: peeking title strips on top, the front card open below them.
struct PurseView: View {
    @Environment(AppModel.self) private var model

    /// Display order, front card first. Separate from the saved order so
    /// flipping through cards never rewrites the purse.
    @State private var order: [String] = []
    @State private var drag: CGFloat = 0
    @State private var viewing: CoinRef?
    @State private var editing: CoinRef?
    @State private var addingNew = false
    @State private var recordingVoice = false
    @State private var showAccount = false
    @State private var showReorder = false
    @State private var pendingDelete: Coin?

    private let flipDistance: CGFloat = 72

    var body: some View {
        NavigationStack {
            Group {
                if model.coins.isEmpty {
                    emptyState
                } else {
                    deck
                }
            }
            .navigationTitle("Coin Purse")
            .safeAreaInset(edge: .bottom, spacing: 0) { addBar }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAccount = true } label: {
                        Image(systemName: "person.crop.circle")
                    }
                    .accessibilityLabel("Account")
                }
            }
        }
        .onAppear(perform: syncOrder)
        .onChange(of: model.coins.map(\.id)) { _, _ in syncOrder() }
        .fullScreenCover(item: $viewing) { ref in
            ViewerView(coinId: ref.id)
        }
        .sheet(item: $editing) { ref in
            EditorView(coinId: ref.id)
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

    // MARK: Deck

    private var deck: some View {
        let coins = order.compactMap { model.coin($0) }
        let peeks = Array(coins.dropFirst())
        let peekHeight = CGFloat(peeks.count) * CardMetrics.peek
        return ScrollView {
            VStack(spacing: 12) {
                if coins.count > 1 {
                    Text("Swipe to flip · tap to open · long-press to rearrange")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ZStack(alignment: .top) {
                    ForEach(Array(peeks.enumerated()), id: \.element.id) { slot, coin in
                        CoinCardHeader(coin: coin) { pendingDelete = coin }
                            .frame(height: CardMetrics.peek + 24, alignment: .top)
                            .cardBackground(coin.accentColor)
                            .offset(y: CGFloat(slot) * CardMetrics.peek)
                            .zIndex(Double(slot))
                            .onTapGesture { bringForward(coin.id) }
                            .onLongPressGesture { startReorder() }
                    }
                    if let front = coins.first {
                        frontCard(front, total: coins.count)
                            .offset(y: peekHeight + drag)
                            .zIndex(1000)
                    }
                }
                .frame(height: peekHeight + 520, alignment: .top)
                .padding(.horizontal, 16)
            }
            .padding(.top, 8)
        }
        .refreshable { await model.refresh() }
    }

    private func frontCard(_ coin: Coin, total: Int) -> some View {
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
            .frame(height: 380)
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
        .accessibilityIdentifier("frontCard")
        .onTapGesture { viewing = CoinRef(id: coin.id) }
        .onLongPressGesture { startReorder() }
        .highPriorityGesture(
            DragGesture(minimumDistance: 12)
                .onChanged { value in
                    guard total > 1 else { return }
                    drag = value.translation.height
                }
                .onEnded { value in
                    let dy = value.translation.height
                    let predicted = value.predictedEndTranslation.height
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
                        if total > 1 && (dy > flipDistance || predicted > 240) {
                            flip(by: 1)
                        } else if total > 1 && (dy < -flipDistance || predicted < -240) {
                            flip(by: -1)
                        }
                        drag = 0
                    }
                }
        )
        .sensoryFeedback(.selection, trigger: order.first)
    }

    // MARK: Order

    /// Keep the display order in step with the purse: new coins go to the
    /// front, deleted ones drop out.
    private func syncOrder() {
        let ids = model.coins.map(\.id)
        let known = Set(order)
        let newOnes = ids.filter { !known.contains($0) }
        let present = Set(ids)
        order = newOnes + order.filter { present.contains($0) }
    }

    /// Move to the next (+1) or previous (-1) card in saved order. The old
    /// front card becomes the top peek, like the web app.
    private func flip(by direction: Int) {
        let ring = model.coins.map(\.id)
        guard ring.count > 1, let current = order.first, let i = ring.firstIndex(of: current) else { return }
        let next = ring[(i + direction + ring.count) % ring.count]
        bringForward(next)
    }

    private func bringForward(_ id: String) {
        guard let current = order.first, id != current else { return }
        let ring = model.coins.map(\.id)
        guard let start = ring.firstIndex(of: current) else { return }
        var rest: [String] = []
        for step in 1..<ring.count {
            let other = ring[(start + step) % ring.count]
            if other != id && other != current { rest.append(other) }
        }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
            order = [id, current] + rest
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
            // Cards scroll under the bar and fade out instead of being cut off.
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
            Text("Snap or paste a QR code, a ticket or a gift card with Add Coin.  Or tap Voice Note and say a quick list or reminder.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(maxHeight: .infinity)
    }
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

    var body: some View {
        Text(notes)
            .font(.title3.weight(.medium))
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
