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
    /// The archive: open, and (from a search) the coin to open in it.
    @State private var showArchive = false
    @State private var archiveStart: String?
    /// The camera is open (from the camera button).
    @State private var snapping = false
    /// A picture from the camera that could not be saved at once: the editor opens with it.
    @State private var snappedFallback: SnappedPicture?
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
    /// Swiping a card's bar to the left, as in Mail: which card, how far it
    /// is pulled (negative), where it started, and whether letting go now
    /// deletes it (pulled most of the way across).
    @State private var swipeId: String?
    @State private var swipeX: CGFloat = 0
    @State private var swipeStart: CGFloat = 0
    @State private var swipeArmed = false
    @State private var stackWidth: CGFloat = 360
    /// Swipe to Delete can be turned off in Account (it is on to start).
    @AppStorage("swipeToDelete") private var swipeToDelete = true
    /// Pulled down to refresh: the spinner at the top shows until it is done.
    @State private var refreshingFromPull = false
    /// How far a swiped card stays open to show its Archive and Delete buttons.
    private let revealWidth: CGFloat = 176
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
        guard searching, !q.isEmpty else { return model.purse }
        return model.purse.filter { $0.matches(q) }
    }

    /// Archived coins that match the search, shown under the purse's own.
    private var archiveMatches: [Coin] {
        let q = trimmedQuery
        guard searching, !q.isEmpty else { return [] }
        return model.archive.filter { $0.matches(q) }
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
                            guard let next = model.coin(other) else { return }
                            Task {
                                // A hidden coin asks for Face ID before it comes up.
                                guard await model.reveal(next) else { return }
                                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                                withAnimation(cardAnimation) { openId = other }
                            }
                        },
                        onArchive: { archiveOpenCoin(id) }
                    )
                    .transition(reduceMotion ? .opacity : .identity)
                    .zIndex(10)
                }
            }
        }
        // Leaving the app covers hidden coins again, including one left open.
        .onChange(of: model.revealed) { _, _ in
            if let id = openId, let coin = model.coin(id), model.isVeiled(coin) { openId = nil }
        }
        .onChange(of: model.purse.map(\.id)) { _, ids in
            if let id = openId, !ids.contains(id) { openId = nil }
            // Once the cards have slid into their new places, layer them again.
            Task {
                try? await Task.sleep(for: .milliseconds(500))
                if moving == nil && model.purse.map(\.id) == ids { stackVersion += 1 }
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
        .fullScreenCover(isPresented: $snapping) {
            CameraPicker { image in
                snapping = false
                Task { await saveSnapped(image) }
            }
            .ignoresSafeArea()
        }
        .sheet(item: $snappedFallback) { snap in
            EditorView(coinId: snap.existing ? snap.id : nil, startingPicture: snap.data)
        }
        .sheet(isPresented: $showArchive, onDismiss: { archiveStart = nil }) { ArchiveView(startWith: archiveStart) }
        .task(id: model.purse.count) { MoveCardsTip.coinCount = model.purse.count }
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
                withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) { model.deleteWithUndo(coin.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { coin in
            Text("“\(coin.title)” and everything in it will be deleted.")
        }
    }

    // MARK: The stack

    private func stackLayer(screenHeight: CGFloat) -> some View {
        let isOpen = openId != nil
        return ScrollViewReader { scroller in
        ScrollView {
            Color.clear.frame(height: 0).id("purseTop")
            // Like Mail: pulled down, a spinner shows the purse is being brought up to date.
            if refreshingFromPull {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityLabel("Refreshing")
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if model.purse.isEmpty && !model.coinsLoaded {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, minHeight: screenHeight - 220)
            } else if model.purse.isEmpty {
                emptyState
                    .frame(minHeight: screenHeight - 220)
            } else if visibleCoins.isEmpty {
                if archiveMatches.isEmpty {
                    ContentUnavailableView.search(text: trimmedQuery)
                        .padding(.top, 60)
                }
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
            if !archiveMatches.isEmpty {
                inArchive
            }
        }
        .modifier(PullTracker(pull: $pull))
        // Scrolling the purse closes a card swiped open, as in Mail.
        .modifier(ScrollStarted { if swipeId != nil { closeSwipe() } })
        // Pulled down far enough, the purse also refreshes (once per pull).
        .onChange(of: pull) { _, amount in
            if amount > 90, !pulledToRefresh, !refreshingFromPull {
                pulledToRefresh = true
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                Task {
                    withAnimation(.snappy) { refreshingFromPull = true }
                    let started = Date()
                    await model.refresh()
                    // Long enough to see, even when the refresh is instant, and still
                    // there after the finger lets go (as in Mail).
                    let shown = Date().timeIntervalSince(started)
                    if shown < 0.8 { try? await Task.sleep(for: .seconds(0.8 - shown)) }
                    for _ in 0..<100 where pull > 4 { try? await Task.sleep(for: .milliseconds(100)) }
                    try? await Task.sleep(for: .milliseconds(600))
                    withAnimation(.snappy) { refreshingFromPull = false }
                }
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
        .onChange(of: model.purse.first?.id) { old, new in
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
            VStack(spacing: 10) {
                savedBar
                undoBar
                if !searching {
                    addBar
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .opacity(isOpen ? 0 : 1)
            .offset(y: isOpen ? 110 : 0)
            .animation(.spring(response: 0.35, dampingFraction: 0.86), value: model.undoable?.id)
            .animation(.spring(response: 0.35, dampingFraction: 0.86), value: model.justSaved?.id)
        }
        .onChange(of: model.undoable?.id) { _, id in
            if id != nil, let coin = model.undoable {
                AccessibilityNotification.Announcement("Deleted \(coin.title).  Undo is at the bottom of the screen.").post()
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
                        if swipeId == coin.id {
                            swipeAction(coin, height: isLast ? lastCardHeight : peek + 20)
                        }
                        // Swiped sideways, a tucked card is only its bar (a rounded strip),
                        // so none of the rest of it peeks out beside the card after it.
                        CoinCardView(coin: coin, faceShowing: isLast,
                                     height: swipeId == coin.id && !isLast ? peek : nil,
                                     veiled: model.isVeiled(coin)) { pendingDelete = coin }
                            // While it is lifted, the lifted copy above the stack is the card.
                            // While a coin is open, the cards under it at the bottom are these
                            // coins; the purse's own copies step aside until it closes.
                            .matchedCard(id: moving == coin.id ? "held-" + coin.id : openId == nil ? coin.id : "purse-" + coin.id,
                                         in: cards, enabled: !reduceMotion)
                            .contentShape(RoundedRectangle(cornerRadius: CardMetrics.corner, style: .continuous))
                            // With a card swiped open, a tap anywhere just closes it (as in Mail).
                            .onTapGesture {
                                if swipeId != nil { closeSwipe() } else { openCoin(coin.id) }
                            }
                            // Swipe the bar to the left to archive or delete it, as in Mail (search
                            // results too). Not switched off when a card lifts: that rebuilt the card
                            // and cancelled the lift; a lifted card simply ignores it (see beginSwipe).
                            .modifier(SwipeToDelete(enabled: swipeToDelete,
                                                    began: { beginSwipe(coin.id) },
                                                    changed: { dx in dragSwipe(coin.id, by: dx) },
                                                    ended: { velocity in endSwipe(coin.id, velocity: velocity) }))
                            // Touch and hold to lift it, then drag to move it, as in Wallet.
                            // iOS's own touch-and-hold works alongside the purse's scrolling: a
                            // finger that moves before the hold completes just scrolls.
                            .modifier(HoldToMove(enabled: !searching,
                                                 began: { y in liftCard(coin, at: i, fingerY: y) },
                                                 changed: { y in dragCard(coin.id, at: i, count: coins.count, fingerY: y) },
                                                 ended: { finishMove(coin.id, at: i) }))
                            .offset(x: swipeId == coin.id ? swipeX : 0)
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
                .overlay(alignment: .top) { cardForVoiceOver(coin, at: i, height: isLast ? lastCardHeight : peek) }
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
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { stackWidth = $0 }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        // Room for the last card, which hangs below its row.
        .padding(.bottom, 20 + lastCardHeight - peek)
    }

    /// To VoiceOver, one button per card, exactly the size of what shows, with
    /// actions for everything a finger can do to it.
    private func cardForVoiceOver(_ coin: Coin, at i: Int, height: CGFloat) -> some View {
        Color.clear
            .frame(height: height)
            .accessibilityElement()
            .accessibilityLabel(coin.title)
            .accessibilityValue(model.isVeiled(coin) ? "Hidden" : "")
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("stackCard")
            .accessibilityAction { openCoin(coin.id) }
            .accessibilityAction(named: "Move to top") { model.move(coin.id, to: 0) }
            .accessibilityAction(named: "Move up") { model.move(coin.id, to: max(0, i - 1)) }
            .accessibilityAction(named: "Move down") { model.move(coin.id, to: i + 1) }
            .accessibilityAction(named: "Archive") {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) { model.archive(coin.id) }
            }
            .accessibilityAction(named: "Delete") { pendingDelete = coin }
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
        return CoinCardView(coin: coin, faceShowing: true, veiled: model.isVeiled(coin)) { pendingDelete = coin }
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

    // MARK: Swipe to delete

    /// Behind the card, as in Mail: Archive and Delete show in the part the
    /// card has uncovered. Pulled far enough to delete on letting go, Delete
    /// takes it all and follows the card.
    private func swipeAction(_ coin: Coin, height: CGFloat) -> some View {
        let uncovered = max(-swipeX, 0)
        let each = max(uncovered, revealWidth) / 2
        return HStack(spacing: 0) {
            Spacer(minLength: 0)
            swipeButton("Archive", "archivebox.fill", color: Color(.systemGray), width: swipeArmed ? 0 : each,
                        height: height, id: "swipeArchive") { swipeArchive(coin.id) }
            swipeButton("Delete", "trash.fill", color: .red, width: swipeArmed ? max(uncovered, revealWidth) : each,
                        height: height, id: "swipeDelete", leading: swipeArmed) { swipeDelete(coin.id) }
        }
        .frame(height: height)
        .background(Color.red)
        .clipShape(RoundedRectangle(cornerRadius: CardMetrics.corner, style: .continuous))
        // VoiceOver archives and deletes with the card's own actions.
        .accessibilityHidden(true)
    }

    private func swipeButton(_ title: String, _ icon: String, color: Color, width: CGFloat, height: CGFloat,
                             id: String, leading: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.title3)
                Text(title).font(.caption.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(width: width, height: min(height, peek), alignment: leading ? .leading : .center)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(color)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: width)
        .clipped()
        .accessibilityIdentifier(id)
    }

    /// Past this far across, letting go deletes it (Mail's full swipe).
    private var fullSwipe: CGFloat { stackWidth * 0.55 }

    private func beginSwipe(_ id: String) {
        guard moving == nil else { return }
        if swipeId != id {
            // Another card was open: it closes, this one starts from closed.
            swipeId = id
            swipeX = 0
            swipeArmed = false
        }
        swipeStart = swipeX
    }

    private func dragSwipe(_ id: String, by dx: CGFloat) {
        guard swipeId == id else { return }
        // Never to the right of where it rests.
        swipeX = min(0, swipeStart + dx)
        let armed = -swipeX > fullSwipe
        if armed != swipeArmed {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            withAnimation(.snappy(duration: 0.2)) { swipeArmed = armed }
        }
    }

    private func endSwipe(_ id: String, velocity: CGFloat) {
        guard swipeId == id else { return }
        if swipeArmed || (velocity < -1200 && -swipeX > revealWidth) {
            swipeDelete(id)
        } else if (-swipeX > revealWidth / 2 && velocity < 300) || velocity < -400 {
            // Stays open, showing Delete.
            withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { swipeX = -revealWidth }
        } else {
            closeSwipe()
        }
    }

    private func closeSwipe() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
            swipeX = 0
            swipeArmed = false
        } completion: {
            if swipeX == 0 { swipeId = nil }
        }
    }

    /// The card slides off to the left, the cards after it close the gap, and
    /// the Undo bar comes up.
    private func swipeDelete(_ id: String) {
        if !swipeArmed { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
        withAnimation(.easeIn(duration: 0.18)) { swipeX = -(stackWidth + 40) } completion: {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) { model.deleteWithUndo(id) }
            var now = Transaction()
            now.disablesAnimations = true
            withTransaction(now) {
                swipeId = nil
                swipeX = 0
                swipeArmed = false
            }
        }
    }

    /// The card slides off to the left into the archive; the Undo bar comes up.
    private func swipeArchive(_ id: String) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(.easeIn(duration: 0.18)) { swipeX = -(stackWidth + 40) } completion: {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) { model.archive(id) }
            var now = Transaction()
            now.disablesAnimations = true
            withTransaction(now) {
                swipeId = nil
                swipeX = 0
                swipeArmed = false
            }
        }
    }

    /// Archived coins that match a search, under the purse's own results:
    /// tap one to see it in the archive.
    private var inArchive: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("In Archive")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 4)
            ForEach(archiveMatches) { coin in
                Button {
                    archiveStart = coin.id
                    showArchive = true
                } label: {
                    ArchiveRow(coin: coin, veiled: model.isVeiled(coin))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("archiveMatch")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, visibleCoins.isEmpty ? 24 : 0)
        .padding(.bottom, 24)
    }

    /// For a few seconds after a delete or an archive: what went, and Undo.
    private var undoBar: some View { UndoBar() }

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
        if swipeId != nil { closeSwipe() }
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
    private func coins(beforeMoving id: String) -> Int? { model.purse.firstIndex { $0.id == id } }

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
        guard let coin = model.coin(id) else { return }
        // A hidden coin opens only after Face ID.
        if model.isVeiled(coin) {
            Task { if await model.reveal(coin) { openCoin(id) } }
            return
        }
        searchFocused = false
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        withAnimation(cardAnimation) { openId = id }
    }

    private func closeCoin() {
        withAnimation(cardAnimation) { openId = nil }
    }

    private var cardAnimation: Animation { reduceMotion ? .easeInOut(duration: 0.25) : Self.cardSpring }

    /// The card goes back into the stack first, then leaves it.
    /// The card goes back into the stack first, then into the archive.
    private func archiveOpenCoin(_ id: String) {
        closeCoin()
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) { model.archive(id) }
        }
    }

    private func deleteOpenCoin(_ id: String) {
        closeCoin()
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) { model.deleteWithUndo(id) }
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
                    // With four buttons on a small iPhone, it shrinks a little rather than crowd them.
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                    .minimumScaleFactor(0.7)
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
                // Counting the archive too, so archived coins can be found.
                if model.coins.count >= searchThreshold {
                    circleButton("magnifyingglass", label: "Search") {
                        withAnimation(.snappy) { searching = true }
                        searchFocused = true
                    }
                }
                if model.purse.count >= 2 {
                    circleButton("arrow.up.arrow.down", label: "Rearrange") { showReorder = true }
                }
                // The archive, once anything is archived.
                if !model.archive.isEmpty {
                    circleButton("archivebox", label: "Archive") { showArchive = true }
                        .accessibilityValue(model.archive.count == 1 ? "1 coin" : "\(model.archive.count) coins")
                        .accessibilityIdentifier("archive")
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

    /// Three ways to add a coin, where your thumb is: the microphone starts a
    /// voice note at once, New Coin starts one from scratch (type, paste,
    /// Photos, camera, voice, a pin), and the camera takes a picture at once.
    private var addBar: some View {
        // At the largest text sizes, where one row does not fit: New Coin on top.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 18) {
                voiceButton
                newCoinButton
                cameraButton
            }
            VStack(spacing: 10) {
                newCoinButton
                HStack(spacing: 24) {
                    voiceButton
                    cameraButton
                }
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity)
        .background {
            LinearGradient(colors: [Color(.systemBackground).opacity(0), Color(.systemBackground).opacity(0.85)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        }
    }

    /// A voice note: listening starts the moment it opens; Done saves it.
    private var voiceButton: some View {
        quickButton("mic.fill", label: "Voice Note", id: "newVoice", color: 5) { recordingVoice = true }
    }

    /// A picture: the camera opens at once and the picture is saved as a coin.
    private var cameraButton: some View {
        quickButton("camera.fill", label: "Take a Picture", id: "newPhoto", color: 1) { startCamera() }
    }

    /// In a card color (deep enough for a white symbol), as easy to spot as New Coin.
    private func quickButton(_ icon: String, label: String, id: String, color: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(
                    LinearGradient(colors: [AccentPalette.cardColors(color).top, AccentPalette.cardColors(color).bottom],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: Circle()
                )
                .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    /// A coin from scratch: type, paste, choose from Photos, take a picture,
    /// say a voice note into it, or pin where you are.
    private var newCoinButton: some View {
        Button { typingNote = true } label: {
            Label("New Coin", systemImage: "plus")
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, 24)
                .frame(minHeight: 56)
                // The deep indigo of the cards: white text reads clearly in light and dark.
                .background(AccentPalette.cardColors(0).top, in: Capsule())
                .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .accessibilityIdentifier("newCoin")
        .accessibilityHint("Type, paste, add pictures, a voice note or a pin")
    }

    // MARK: Camera

    private func startCamera() {
        #if DEBUG
        // UI tests (the simulator has no camera): a ready-made picture.
        if ProcessInfo.processInfo.arguments.contains("-uiTestCameraSample") {
            Task { await saveSnapped(Self.sampleSnap()) }
            return
        }
        #endif
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            snapping = true
        } else {
            // No camera (some iPads, the simulator): the coin editor, to pick one.
            addingPicture = true
        }
    }

    /// The picture becomes a coin straight away; if that cannot be saved (no
    /// signal), the editor opens with it so it is not lost.
    private func saveSnapped(_ image: UIImage?) async {
        guard let image, let jpeg = await PictureLoader.prepare(image) else { return }
        let id = UUID().uuidString.lowercased()
        do {
            try await model.quickSave(picture: jpeg, id: id)
            // Opened right away, to name it, add to it, or leave it as it is.
            openCoin(id)
        } catch {
            snappedFallback = SnappedPicture(id: id, data: jpeg, existing: model.coin(id) != nil)
        }
    }

    #if DEBUG
    private static func sampleSnap() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 600, height: 800)).image { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 600, height: 800))
            ("Dog food" as NSString).draw(at: CGPoint(x: 60, y: 360), withAttributes: [
                .font: UIFont.boldSystemFont(ofSize: 72), .foregroundColor: UIColor.white,
            ])
        }
    }
    #endif

    /// Just after a coin was made in one go: Saved, with Add details and Undo.
    @ViewBuilder private var savedBar: some View {
        if let coin = model.justSaved {
            HStack(spacing: 14) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
                Text("Saved “\(coin.title)”")
                    .font(.subheadline)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Button("Add details") {
                    model.dismissSaved()
                    editing = CoinRef(id: coin.id)
                }
                .font(.subheadline.weight(.semibold))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityIdentifier("addDetails")
                Button("Undo") {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) { model.discardNew(coin.id) }
                }
                .font(.subheadline.weight(.semibold))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityIdentifier("undoSaved")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 2)
            .background(.thinMaterial, in: Capsule())
            .padding(.horizontal, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
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
            Text("Tap the camera for a picture, the microphone for a voice note, or New Coin to type or paste one.")
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

/// How far the purse is pulled down past its top.
private struct PullTracker: ViewModifier {
    @Binding var pull: CGFloat

    func body(content: Content) -> some View {
        content.onScrollGeometryChange(for: CGFloat.self) { geo in
            -(geo.contentOffset.y + geo.contentInsets.top)
        } action: { _, past in
            pull = max(0, past)
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
        if enabled {
            content.gesture(HoldRecognizer(began: began, changed: changed, ended: ended))
        } else {
            content
        }
    }
}

/// A sideways swipe on a card, for Swipe to Delete. iOS's own pan that only
/// starts when the finger moves more sideways than up or down, so scrolling
/// the purse and touch and hold work as before.
private struct SwipeToDelete: ViewModifier {
    let enabled: Bool
    let began: () -> Void
    let changed: (CGFloat) -> Void
    let ended: (CGFloat) -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.gesture(SwipeRecognizer(began: began, changed: changed, ended: ended))
        } else {
            content
        }
    }
}

private struct SwipeRecognizer: UIGestureRecognizerRepresentable {
    let began: () -> Void
    let changed: (CGFloat) -> Void
    let ended: (CGFloat) -> Void

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            let v = pan.velocity(in: pan.view)
            return abs(v.x) > abs(v.y) * 1.5
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        // Measured on the screen, so the card moving under the finger does not shake it.
        switch recognizer.state {
        case .began: began()
        case .changed: changed(context.converter.translation(in: .global)?.x ?? 0)
        case .ended, .cancelled, .failed: ended(context.converter.velocity(in: .global)?.x ?? 0)
        default: break
        }
    }
}

/// Runs `action` when a finger starts scrolling the purse.
private struct ScrollStarted: ViewModifier {
    let action: () -> Void

    func body(content: Content) -> some View {
        content.onScrollPhaseChange { _, phase in
            if phase == .interacting { action() }
        }
    }
}

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

/// A picture from the camera waiting in the editor because it could not be
/// saved straight away (`existing`: the coin was made, the picture was not).
struct SnappedPicture: Identifiable {
    let id: String
    let data: Data
    let existing: Bool
}
