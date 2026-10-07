import SwiftUI
import TipKit

/// Identifies which coin a sheet or full-screen view is showing.
struct CoinRef: Identifiable, Hashable { let id: String }

/// The purse: coins stacked like cards in Wallet, each showing its colored
/// top. Scroll to browse, tap one and it slides out of the stack. Up and down
/// only ever scrolls; sideways only happens inside an open coin.
struct PurseView: View {
    @Environment(AppModel.self) private var model
    @Environment(QuickActions.self) private var quick
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var cards
    /// How much of each tucked-in card shows; grows with larger text.
    @ScaledMetric(relativeTo: .headline) private var peek: CGFloat = CardMetrics.peek
    @Environment(\.dynamicTypeSize) private var typeSize

    @State private var openId: String?
    @State private var editing: CoinRef?
    @State private var addingPicture = false
    @State private var addingPin = false
    @State private var recordingVoice = false
    @State private var typingNote = false
    @State private var showAccount = false
    /// The card being moved (touch and hold, then drag), how far it has
    /// gone, and the place it would land.
    @State private var moving: String?
    @State private var showReorder = false
    private let moveTip = MoveCardsTip()
    @State private var moveOffset: CGFloat = 0
    @State private var moveTarget: Int?
    /// Where the finger was when the card lifted, on the screen.
    @State private var moveStartY: CGFloat = 0
    /// A lifted card pulled up to the top of the screen opens when let go.
    @State private var openReady = false
    /// The lifted card is raised off the stack (bigger, with a shadow).
    @State private var raised = false
    /// Let go: the lifted card is sliding into its place and under the cards after it.
    @State private var settling = false
    /// How far the purse is pulled down past its top; the cards fan apart.
    @State private var pull: CGFloat = 0
    @State private var pulledToRefresh = false
    @State private var headerBottom: CGFloat = 120
    /// Bumped after the order of the purse changes, so every card is layered
    /// again for its new place (the lazy stack keeps a card's old layering).
    @State private var stackVersion = 0
    @State private var pendingDelete: Coin?
    @State private var searching = false
    @State private var testShare = false
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    /// One spring for opening and closing, so the card and the stack move together.
    static let cardSpring = Animation.spring(response: 0.5, dampingFraction: 0.86)
    /// Search shows up once a purse is big enough to need it.
    private let searchThreshold = 6

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }
    private var visibleCoins: [Coin] {
        let q = trimmedQuery
        guard searching, !q.isEmpty else { return model.coins }
        return model.coins.filter { $0.title.localizedStandardContains(q) || $0.notes.localizedStandardContains(q) }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color(.systemBackground).ignoresSafeArea()
                stackLayer(screenHeight: geo.size.height)
                    // With Reduce Motion, the purse fades instead of sliding away.
                    .opacity(reduceMotion && openId != nil ? 0 : 1)
                if let id = openId, let coin = model.coin(id) {
                    CoinDetailView(
                        coin: coin,
                        namespace: cards,
                        pile: pile(after: id),
                        onClose: closeCoin,
                        onDelete: { deleteOpenCoin(id) },
                        onSelect: { other in
                            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                            withAnimation(cardAnimation) { openId = other }
                        }
                    )
                    .transition(reduceMotion ? .opacity : .identity)
                    .zIndex(10)
                }
            }
        }
        .onChange(of: model.coins.map(\.id)) { _, ids in
            if let id = openId, !ids.contains(id) { openId = nil }
            // Once the cards have slid into their new places, layer them again.
            Task {
                try? await Task.sleep(for: .milliseconds(500))
                if moving == nil && model.coins.map(\.id) == ids { stackVersion += 1 }
            }
            runQuickAction()
        }
        // From the icon menu, Siri, Shortcuts or the Action Button.
        .onChange(of: quick.pending, initial: true) { _, _ in runQuickAction() }
        .onAppear {
            #if DEBUG
            if let test = UserDefaults.standard.string(forKey: "uiTestQuickAction") {
                quick.pending = QuickAction(shortcutType: test)
            }
            if ProcessInfo.processInfo.arguments.contains("-uiTestShare") {
                Task {
                    try? await Task.sleep(for: .seconds(1))
                    testShare = true
                }
            }
            #endif
        }
        .sheet(isPresented: $addingPicture) { EditorView(coinId: nil) }
        .sheet(isPresented: $addingPin) { EditorView(coinId: nil, startsWithPin: true) }
        .sheet(isPresented: $recordingVoice) { VoiceNoteView() }
        .sheet(isPresented: $typingNote) { EditorView(coinId: nil, startsWithText: true) }
        .sheet(item: $editing) { ref in EditorView(coinId: ref.id) }
        .sheet(isPresented: $showAccount) { AccountView() }
        .sheet(isPresented: $showReorder) { ReorderView() }
        .task(id: model.coins.count) { MoveCardsTip.coinCount = model.coins.count }
        #if DEBUG
        // UI tests open the Share to Coin Purse screen with two sample pictures.
        .sheet(isPresented: $testShare) {
            ShareView(load: { ShareSamples.input() }, onDone: {
                testShare = false
                Task { await model.refresh() }
            }, onCancel: { testShare = false })
        }
        #endif
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
            Text("“\(coin.title)” and everything in it will be deleted. This cannot be undone.")
        }
    }

    // MARK: The stack

    private func stackLayer(screenHeight: CGFloat) -> some View {
        let isOpen = openId != nil
        return ScrollViewReader { scroller in
        ScrollView {
            Color.clear.frame(height: 0).id("purseTop")
            if model.coins.isEmpty && !model.coinsLoaded {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, minHeight: screenHeight - 220)
            } else if model.coins.isEmpty {
                emptyState
                    .frame(minHeight: screenHeight - 220)
            } else if visibleCoins.isEmpty {
                ContentUnavailableView.search(text: trimmedQuery)
                    .padding(.top, 60)
            } else {
                // Once, when the purse has a few coins: how to move them.
                if !searching {
                    TipView(moveTip) { action in
                        if action.id == "rearrange" { showReorder = true }
                    }
                    .tipBackground(Color(.secondarySystemBackground))
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }
                stack(screenHeight: screenHeight)
            }
        }
        .modifier(PullTracker(pull: $pull))
        // Pulled down far enough, the purse also refreshes (once per pull).
        .onChange(of: pull) { _, amount in
            if amount > 90, !pulledToRefresh {
                pulledToRefresh = true
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                Task { await model.refresh() }
            } else if amount < 4 {
                pulledToRefresh = false
            }
        }
        // Offline: try again every 15 seconds; the Offline note goes away by itself.
        .task(id: model.isOffline) {
            while model.isOffline, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled, model.isOffline else { break }
                await model.refresh()
            }
        }
        .scrollDisabled(isOpen || moving != nil)
        // A new coin goes on top of the purse: bring the top into view so it shows.
        .onChange(of: model.coins.first?.id) { old, new in
            guard let new, new != old, openId == nil, moving == nil else { return }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) { scroller.scrollTo("purseTop", anchor: .top) }
        }
        .allowsHitTesting(!isOpen)
        .accessibilityHidden(isOpen)
        .scrollDismissesKeyboard(.immediately)
        .safeAreaInset(edge: .top, spacing: 0) {
            header
                // Where the title area ends: a lifted card pulled above it opens.
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { headerBottom = $0 }
                .opacity(isOpen ? 0 : 1)
                .offset(y: isOpen ? -16 : 0)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !searching {
                addBar
                    .opacity(isOpen ? 0 : 1)
                    .offset(y: isOpen ? 110 : 0)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        }
    }

    private func stack(screenHeight: CGFloat) -> some View {
        let coins = visibleCoins
        // Lazy: only cards near the screen are drawn, so a big purse does not
        // load every picture at once (data, memory and battery).
        return LazyVStack(spacing: 0) {
            ForEach(Array(coins.enumerated()), id: \.element.id) { i, coin in
                let isLast = i == coins.count - 1
                ZStack(alignment: .top) {
                    if openId == coin.id {
                        // Holds the card's place while it is out of the stack.
                        Color.clear
                    } else {
                        CoinCardView(coin: coin, faceShowing: isLast) { pendingDelete = coin }
                            // While it is lifted, the lifted copy above the stack is the card.
                            // While a coin is open, the cards under it at the bottom are these
                            // coins; the purse's own copies step aside until it closes.
                            .matchedCard(id: moving == coin.id ? "held-" + coin.id : openId == nil ? coin.id : "purse-" + coin.id,
                                         in: cards, enabled: !reduceMotion)
                            .contentShape(RoundedRectangle(cornerRadius: CardMetrics.corner, style: .continuous))
                            .onTapGesture { openCoin(coin.id) }
                            // Touch and hold to lift it, then drag to move it, as in Wallet.
                            // iOS's own touch-and-hold works alongside the purse's scrolling: a
                            // finger that moves before the hold completes just scrolls.
                            .modifier(HoldToMove(enabled: !searching,
                                                 began: { y in liftCard(coin, at: i, fingerY: y) },
                                                 changed: { y in dragCard(coin.id, at: i, count: coins.count, fingerY: y) },
                                                 ended: { finishMove(coin.id, at: i) }))
                            .opacity(moving == coin.id ? 0 : 1)
                    }
                }
                // A tucked-in card is drawn only as far as you can see it (its top,
                // plus a little behind the next card's rounded corners), so it grows
                // straight from that when it opens.
                // Pulled down, each card grows by as much as it moves apart, so the
                // stack opens up like real cards and shows more of each one.
                .frame(height: isLast ? lastCardHeight : peek + 30 + fanStep)
                // Every row is exactly one card top tall, so the lazy stack always
                // knows the full height (the last card hangs below its row, into
                // the room left under the stack).
                .frame(height: peek, alignment: .top)
                // To VoiceOver, each card is one button exactly the size of what
                // you can see (the card itself reaches down behind the next one).
                .accessibilityHidden(true)
                .overlay(alignment: .top) {
                    Color.clear
                        .frame(height: isLast ? lastCardHeight : peek)
                        .accessibilityElement()
                        .accessibilityLabel(coin.title)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityIdentifier("stackCard")
                        .accessibilityAction { openCoin(coin.id) }
                        .accessibilityAction(named: "Move to top") { model.move(coin.id, to: 0) }
                        .accessibilityAction(named: "Move up") { model.move(coin.id, to: max(0, i - 1)) }
                        .accessibilityAction(named: "Move down") { model.move(coin.id, to: i + 1) }
                        .accessibilityAction(named: "Delete") { pendingDelete = coin }
                }
                .zIndex(Double(i))
                // Moving a card: the others make room for it.
                .offset(y: moving == coin.id ? 0 : makeRoom(at: i, in: coins))
                // Pulled down past the top, the cards fan apart, like a stretched stack.
                .offset(y: fanStep * CGFloat(min(i, 12)))
                // While a coin is out, the rest of the stack drops out of sight.
                .offset(y: openId == nil || openId == coin.id || reduceMotion ? 0 : screenHeight + CGFloat(i) * 8)
            }
        }
        // The lifted card, above every other card: all of it shows, so you can
        // see what is on it, and it follows your finger.
        .overlay(alignment: .top) {
            if let id = moving, let i = coins.firstIndex(where: { $0.id == id }) {
                liftedCard(coins[i], at: i)
            }
        }
        .id(stackVersion)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        // Room for the last card, which hangs below its row.
        .padding(.bottom, 20 + lastCardHeight - peek)
    }

    /// The last card shows whole.
    private var lastCardHeight: CGFloat { CardMetrics.stackHeight + peek - CardMetrics.peek }

    /// One solid card: it shows whole the moment it lifts, follows the finger,
    /// and when let go slides into its place and under the cards after it.
    /// It only takes the coin's place in the open-and-close animation once it
    /// is pulled up far enough to open (sharing it earlier made a half drawn
    /// copy grow out of the stack).
    private func liftedCard(_ coin: Coin, at i: Int) -> some View {
        let last = (moveTarget ?? i) == visibleCoins.count - 1
        // Drawn exactly like the card in the stack (trash can included), so
        // nothing changes when one takes over from the other.
        return CoinCardView(coin: coin, faceShowing: true) { pendingDelete = coin }
            .matchedCard(id: openReady ? coin.id : "lift-" + coin.id, in: cards, enabled: !reduceMotion)
            .frame(height: lastCardHeight)
            // Settling, only what shows in the stack stays drawn: its top, or
            // all of it in the last place.
            .mask(alignment: .top) {
                Rectangle().frame(height: settling && !last ? peek : lastCardHeight)
            }
            .overlay(alignment: .top) {
                if openReady {
                    Label("Release to open", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(.black.opacity(0.6), in: Capsule())
                        .offset(y: -40)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .scaleEffect(raised ? 1.04 : 1)
            .shadow(color: .black.opacity(raised ? 0.3 : 0), radius: raised ? 18 : 4, y: raised ? 10 : 2)
            .offset(y: CGFloat(i) * peek + moveOffset)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// How far a card shifts to make room for the one being moved.
    private func makeRoom(at i: Int, in coins: [Coin]) -> CGFloat {
        guard let id = moving, let from = coins.firstIndex(where: { $0.id == id }),
              let to = moveTarget else { return 0 }
        if from < to, i > from, i <= to { return -peek }
        if to < from, i >= to, i < from { return peek }
        return 0
    }

    private func liftCard(_ coin: Coin, at i: Int, fingerY: CGFloat) {
        // One card at a time (another finger, or the last one still settling).
        guard moving == nil else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        moveStartY = fingerY
        moveOffset = 0
        // The lifted copy replaces the card in the same frame, exactly where it
        // was, so nothing fades or grows; then it rises off the stack.
        var now = Transaction()
        now.disablesAnimations = true
        withTransaction(now) {
            moving = coin.id
            moveTarget = i
            raised = false
            settling = false
        }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { raised = true }
    }

    private func dragCard(_ id: String, at i: Int, count: Int, fingerY: CGFloat) {
        guard moving == id, !settling else { return }
        moveOffset = fingerY - moveStartY
        // Pulled all the way up, to the title: it will open when let go.
        let ready = fingerY < openLine
        if ready != openReady {
            if ready { UIImpactFeedbackGenerator(style: .rigid).impactOccurred() }
            withAnimation(.snappy(duration: 0.2)) { openReady = ready }
        }
        let target = min(max(i + Int((moveOffset / peek).rounded()), 0), count - 1)
        if target != moveTarget {
            UISelectionFeedbackGenerator().selectionChanged()
            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) { moveTarget = target }
        }
    }

    /// How far apart each card moves when the purse is pulled down: up to a
    /// whole card, so a long pull shows every card in full, like Wallet.
    private var fanStep: CGFloat { min(pull * 0.35, lastCardHeight - peek - 30) }

    /// Where a coin sits in the purse right now.
    private func coins(beforeMoving id: String) -> Int? { model.coins.firstIndex { $0.id == id } }

    /// How high a lifted card has to be pulled to open: into the title area,
    /// above the first card (dropping it on the first card just moves it there).
    private var openLine: CGFloat { headerBottom - 14 }

    /// Puts the lifted card down where it is, and saves the new order; pulled
    /// all the way up, it opens instead.
    private func finishMove(_ id: String, at i: Int) {
        guard moving == id, !settling else { return }
        if openReady {
            openReady = false
            moving = nil
            moveTarget = nil
            moveOffset = 0
            raised = false
            openCoin(id)
            return
        }
        let target = moveTarget ?? i
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        if coins(beforeMoving: id) != target { moveTip.invalidate(reason: .actionPerformed) }
        // The card slides to its place and down onto the stack, tucking in
        // under the cards after it.
        withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) {
            settling = true
            raised = false
            moveOffset = CGFloat(target - i) * peek
        } completion: {
            // In place: the order changes and the stack is layered again for it
            // while the lifted card still covers its spot; a moment later the
            // stack's own card takes over (showing it in the same frame as the
            // new layering briefly drew it over the card after it).
            var now = Transaction()
            now.disablesAnimations = true
            withTransaction(now) {
                model.move(id, to: target)
                moveTarget = target
                moveOffset = 0
                stackVersion += 1
            }
            Task {
                try? await Task.sleep(for: .milliseconds(120))
                withTransaction(now) {
                    moving = nil
                    moveTarget = nil
                    settling = false
                }
            }
        }
    }


    /// The coins after the open one (then around to the top), for the stack
    /// at the bottom of an open coin.
    private func pile(after id: String) -> [Coin] {
        let list = visibleCoins
        guard let i = list.firstIndex(where: { $0.id == id }) else { return list }
        return Array(list[(i + 1)...] + list[..<i])
    }

    private func openCoin(_ id: String) {
        searchFocused = false
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        withAnimation(cardAnimation) { openId = id }
    }

    private func closeCoin() {
        withAnimation(cardAnimation) { openId = nil }
    }

    private var cardAnimation: Animation { reduceMotion ? .easeInOut(duration: 0.25) : Self.cardSpring }

    /// The card goes back into the stack first, then leaves it.
    private func deleteOpenCoin(_ id: String) {
        closeCoin()
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            await model.deleteCoin(id)
        }
    }

    private func runQuickAction() {
        guard let action = quick.pending else { return }
        if case .openCoin(let id) = action {
            // Wait for the purse to load; a coin that no longer exists is dropped.
            guard model.coinsLoaded || model.coin(id) != nil else { return }
            quick.pending = nil
            guard model.coin(id) != nil else { return }
            endSearch()
            openCoin(id)
            return
        }
        quick.pending = nil
        // Start from the purse itself, whatever was open.
        openId = nil
        endSearch()
        editing = nil
        showAccount = false
        switch action {
        case .addPicture: addingPicture = true
        case .voiceNote: recordingVoice = true
        case .pinSpot: addingPin = true
        case .openCoin: break
        }
    }

    // MARK: Header

    /// "Coin Purse" on the same line as search and account, to save room.
    private var header: some View {
        HStack(spacing: 10) {
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
                .padding(.horizontal, 14)
                .frame(height: 42)
                .glassCapsule()
                Button("Cancel") { endSearch() }
                    .foregroundStyle(.primary)
            } else {
                Text("Coin Purse")
                    .font(.system(.title, design: .rounded).weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                    .layoutPriority(1)
                if model.isOffline {
                    // At the largest text sizes, just the symbol: the words would
                    // break the title and themselves mid-word.
                    Label("Offline", systemImage: "wifi.slash")
                        .labelStyle(OfflineLabelStyle(compact: typeSize.isAccessibilitySize))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(.secondarySystemBackground), in: Capsule())
                        .accessibilityLabel("Offline. Showing coins saved on this iPhone.")
                }
                Spacer()
                if model.coins.count >= searchThreshold {
                    circleButton("magnifyingglass", label: "Search") {
                        withAnimation(.snappy) { searching = true }
                        searchFocused = true
                    }
                }
                if model.coins.count >= 2 {
                    circleButton("arrow.up.arrow.down", label: "Rearrange") { showReorder = true }
                }
                circleButton("person.fill", label: "Account") { showAccount = true }
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(alignment: .top) {
            VStack(spacing: 0) {
                Color(.systemBackground)
                LinearGradient(colors: [Color(.systemBackground), Color(.systemBackground).opacity(0)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 18)
                    .padding(.bottom, -18)
            }
            .ignoresSafeArea(edges: .top)
        }
    }

    private func circleButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 42, height: 42)
                .glassCircle()
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(label)
    }

    private func endSearch() {
        withAnimation(.snappy) { searching = false }
        searchFocused = false
        query = ""
    }

    // MARK: Add

    /// One clear way to add a coin, where your thumb is: New Coin, then how
    /// to start it (a picture, your voice, or typing).
    private var addBar: some View {
        Menu {
            Section("New Coin") {
                Button { addingPicture = true } label: {
                    Label("Picture", systemImage: "camera")
                    Text("Paste, Photos or Camera")
                }
                Button { recordingVoice = true } label: {
                    Label("Voice Note", systemImage: "mic")
                    Text("Say it, saved as text")
                }
                Button { typingNote = true } label: {
                    Label("Typed Note", systemImage: "square.and.pencil")
                    Text("A code, a list, a reminder")
                }
            }
        } label: {
            Label("New Coin", systemImage: "plus")
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, 26)
                .frame(minHeight: 54)
                // The deep indigo of the cards: white text reads clearly in light and dark.
                .background(AccentPalette.cardColors(0).top, in: Capsule())
                .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
                .contentShape(Capsule())
        }
        .menuOrder(.fixed)
        .accessibilityIdentifier("newCoin")
        .accessibilityHint("Choose a picture, a voice note or a typed note")
        .padding(.top, 10)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity)
        .background {
            LinearGradient(colors: [Color(.systemBackground).opacity(0), Color(.systemBackground).opacity(0.85)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        }
    }

    // MARK: Empty

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image("Logo")
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
                .shadow(color: .primary.opacity(0.15), radius: 20)
                .accessibilityHidden(true)
            Text("Your purse is empty")
                .font(.system(.title2, design: .rounded).weight(.bold))
            Text("Tap New Coin to add a picture of a ticket or a code, a voice note, or a typed note.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity)
    }
}

extension View {
    /// Apple's Liquid Glass on iOS 26, frosted glass before that. Not the
    /// "interactive" kind: inside a button, that one takes the tap for itself.
    @ViewBuilder func glassCapsule() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: .capsule)
        } else {
            self.background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.primary.opacity(0.12)))
        }
    }

    /// A rounded glass panel, for full-width buttons.
    @ViewBuilder func glassPanel(cornerRadius: CGFloat = 20) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(.primary.opacity(0.12)))
        }
    }

    /// The card's shared move between the stack and the open coin; off with Reduce Motion.
    @ViewBuilder func matchedCard(id: String, in namespace: Namespace.ID, enabled: Bool) -> some View {
        if enabled {
            self.matchedGeometryEffect(id: id, in: namespace)
        } else {
            self
        }
    }

    @ViewBuilder func glassCircle() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: .circle)
        } else {
            self.background(.ultraThinMaterial, in: Circle())
        }
    }
}

/// Long-press opens this: drag the handles to set the saved order.
#if DEBUG
/// Two pictures, as if shared from Photos (UI tests only): big camera-size
/// photos stored sideways, read through the same code the Share extension uses.
enum ShareSamples {
    static func input() -> ShareInput {
        var input = ShareInput()
        for (n, color) in [(1, UIColor.systemBlue), (2, UIColor.systemOrange)] {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let raw = UIGraphicsImageRenderer(size: CGSize(width: 4000, height: 3000), format: format).image { ctx in
                color.setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: 4000, height: 3000))
                ("Shared \(n)" as NSString).draw(at: CGPoint(x: 200, y: 200), withAttributes: [
                    .font: UIFont.boldSystemFont(ofSize: 360), .foregroundColor: UIColor.white,
                ])
            }
            // Like a portrait camera photo: pixels sideways, turned upright by its orientation tag.
            guard let cg = raw.cgImage,
                  let file = UIImage(cgImage: cg, scale: 1, orientation: .right).jpegData(compressionQuality: 0.9),
                  let jpeg = ImageProcessing.uploadData(fromFile: file),
                  let preview = UIImage(data: jpeg) else { continue }
            // Upright portrait, shrunk: 1200 x 1600.
            assert(preview.size.width < preview.size.height && max(preview.size.width, preview.size.height) <= 1600)
            input.images.append(jpeg)
            input.previews.append(preview)
        }
        return input
    }
}
#endif

/// The Offline badge: symbol and word, or just the symbol when space is short.
private struct OfflineLabelStyle: LabelStyle {
    let compact: Bool

    func makeBody(configuration: Configuration) -> some View {
        if compact {
            configuration.icon
        } else {
            Label(configuration)
        }
    }
}

/// How far the purse is pulled down past its top (iOS 18 and later; on
/// iOS 17 the cards simply do not fan).
private struct PullTracker: ViewModifier {
    @Binding var pull: CGFloat

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { geo in
                -(geo.contentOffset.y + geo.contentInsets.top)
            } action: { _, past in
                pull = max(0, past)
            }
        } else {
            content
        }
    }
}

/// Touch and hold, then drag: iOS's own long press, which reports where the
/// finger goes after it is recognized and, unlike a SwiftUI drag, never stops
/// the purse from scrolling. Ends (or is cancelled) always call `ended`.
private struct HoldToMove: ViewModifier {
    let enabled: Bool
    let began: (CGFloat) -> Void
    let changed: (CGFloat) -> Void
    let ended: () -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *), enabled {
            content.gesture(HoldRecognizer(began: began, changed: changed, ended: ended))
        } else {
            content
        }
    }
}

@available(iOS 18.0, *)
private struct HoldRecognizer: UIGestureRecognizerRepresentable {
    let began: (CGFloat) -> Void
    let changed: (CGFloat) -> Void
    let ended: () -> Void

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let hold = UILongPressGestureRecognizer()
        hold.minimumPressDuration = 0.35
        return hold
    }

    func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        let y = context.converter.location(in: .global).y
        switch recognizer.state {
        case .began: began(y)
        case .changed: changed(y)
        case .ended, .cancelled, .failed: ended()
        default: break
        }
    }
}
