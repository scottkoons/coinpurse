import SwiftUI

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
    @ScaledMetric(relativeTo: .caption) private var barHeight: CGFloat = 66
    @Environment(\.dynamicTypeSize) private var typeSize

    @State private var openId: String?
    @State private var editing: CoinRef?
    @State private var addingPicture = false
    @State private var addingPin = false
    @State private var recordingVoice = false
    @State private var showAccount = false
    /// The card being moved (touch and hold, then drag), how far it has
    /// gone, and the place it would land.
    @State private var moving: String?
    @State private var moveOffset: CGFloat = 0
    @State private var moveTarget: Int?
    /// Down while a card is held; iOS resets it if the touch is taken away
    /// (a call, a system gesture), so a lifted card is always put down.
    @GestureState private var holding = false
    /// A lifted card pulled up to the top of the screen opens when let go.
    @State private var openReady = false
    /// How far the purse is pulled down past its top; the cards fan apart.
    @State private var pull: CGFloat = 0
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
                        pile: visibleCoins.filter { $0.id != id },
                        onClose: closeCoin,
                        onDelete: { deleteOpenCoin(id) }
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
        .sheet(item: $editing) { ref in EditorView(coinId: ref.id) }
        .sheet(isPresented: $showAccount) { AccountView() }
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
        return ScrollView {
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
                stack(screenHeight: screenHeight)
            }
        }
        .modifier(PullTracker(pull: $pull))
        .scrollDisabled(isOpen || moving != nil)
        .onChange(of: holding) { _, down in
            if !down { finishMove() }
        }
        .allowsHitTesting(!isOpen)
        .accessibilityHidden(isOpen)
        .scrollDismissesKeyboard(.immediately)
        .refreshable { await model.refresh() }
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
                        CoinCardView(coin: coin, faceShowing: isLast || moving == coin.id) { pendingDelete = coin }
                            .matchedCard(id: coin.id, in: cards, enabled: !reduceMotion)
                            .contentShape(RoundedRectangle(cornerRadius: CardMetrics.corner, style: .continuous))
                            .onTapGesture { openCoin(coin.id) }
                            // Touch and hold to lift it, then drag to move it, as in Wallet.
                            .gesture(searching ? nil : moveGesture(for: coin, at: i, count: coins.count))
                            .overlay(alignment: .top) {
                                if moving == coin.id && openReady {
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
                            .scaleEffect(moving == coin.id ? 1.04 : 1)
                            .shadow(color: .black.opacity(moving == coin.id ? 0.3 : 0), radius: 18, y: 10)
                    }
                }
                // A tucked-in card is drawn only as far as you can see it (its top,
                // plus a little behind the next card's rounded corners), so it grows
                // straight from that when it opens. A lifted card shows all of
                // itself, so you can see what is on it.
                .frame(height: isLast || moving == coin.id ? lastCardHeight : peek + 30)
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
                .zIndex(moving == coin.id ? 1000 : Double(i))
                // Moving a card: it follows the finger and the others make room.
                .offset(y: moving == coin.id ? moveOffset : makeRoom(at: i, in: coins))
                // Pulled down past the top, the cards fan apart, like a stretched stack.
                .offset(y: pull * CGFloat(min(i, 12)) * 0.22)
                // While a coin is out, the rest of the stack drops out of sight.
                .offset(y: openId == nil || openId == coin.id || reduceMotion ? 0 : screenHeight + CGFloat(i) * 8)
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

    /// How far a card shifts to make room for the one being moved.
    private func makeRoom(at i: Int, in coins: [Coin]) -> CGFloat {
        guard let id = moving, let from = coins.firstIndex(where: { $0.id == id }),
              let to = moveTarget else { return 0 }
        if from < to, i > from, i <= to { return -peek }
        if to < from, i >= to, i < from { return peek }
        return 0
    }

    private func moveGesture(for coin: Coin, at i: Int, count: Int) -> some Gesture {
        LongPressGesture(minimumDuration: 0.35)
            // Measured on the screen, not on the card that is itself moving.
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
            .updating($holding) { value, state, _ in
                if case .second(true, _) = value { state = true }
            }
            .onChanged { value in
                guard case .second(true, let drag) = value else { return }
                if moving == nil {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        moving = coin.id
                        moveTarget = i
                    }
                }
                moveOffset = drag?.translation.height ?? 0
                // Pulled all the way up, to the title: it will open when let go.
                let ready = (drag?.location.y ?? .infinity) < openLine
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
            .onEnded { _ in finishMove() }
    }

    /// How high a lifted card has to be pulled to open: into the title area,
    /// above the first card (dropping it on the first card just moves it there).
    private var openLine: CGFloat { headerBottom - 14 }

    /// Puts the lifted card down where it is, and saves the new order; pulled
    /// all the way up, it opens instead.
    private func finishMove() {
        guard let id = moving else { return }
        if openReady {
            openReady = false
            moving = nil
            moveTarget = nil
            moveOffset = 0
            openCoin(id)
            return
        }
        let target = moveTarget
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
            if let target { model.move(id, to: target) }
            moving = nil
            moveTarget = nil
            moveOffset = 0
        }
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

    /// Three ways to add a coin, where your thumb is.
    private var addBar: some View {
        HStack(spacing: 0) {
            barButton("Picture", "camera.fill", id: "addPicture", hint: "Add a picture coin") { addingPicture = true }
            Divider().frame(height: 30)
            barButton("Voice", "mic.fill", id: "voiceNote", hint: "Add a voice note") { recordingVoice = true }
            Divider().frame(height: 30)
            barButton("Pin", "mappin.and.ellipse", id: "addPin", hint: "Pin where you are") { addingPin = true }
        }
        .padding(.horizontal, 8)
        // At the largest text sizes the bar shows symbols only, like a tab bar.
        .frame(height: typeSize.isAccessibilitySize ? 76 : barHeight)
        .glassCapsule()
        .padding(.horizontal, 22)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .background {
            LinearGradient(colors: [Color(.systemBackground).opacity(0), Color(.systemBackground).opacity(0.85)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        }
    }

    private func barButton(_ title: String, _ icon: String, id: String, hint: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: typeSize.isAccessibilitySize ? 28 : 20, weight: .semibold))
                if !typeSize.isAccessibilitySize {
                    Text(title)
                        .font(.caption.weight(.semibold))
                }
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        // Touch and hold shows the name big, as in Apple's tab bars.
        .accessibilityShowsLargeContentViewer { Label(title, systemImage: icon) }
        .accessibilityLabel(hint)
        .accessibilityIdentifier(id)
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
            Text("Snap a ticket or a QR code, say a quick note, or pin where you parked.")
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
