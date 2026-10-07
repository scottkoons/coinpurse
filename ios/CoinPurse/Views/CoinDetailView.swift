import SwiftUI

/// One page inside an open coin: a picture, its map pin, or its note.
enum CoinPage: Hashable {
    case picture(Picture, index: Int)
    case map(Pin)
    case note(String)
}

extension Coin {
    /// What the open card shows: the map first (where you parked matters
    /// most), else the first picture, else the note. Every picture is also
    /// under the card as a thumbnail.
    var face: CoinPage {
        if let pin { return .map(pin) }
        if let first = pictures.first { return .picture(first, index: 0) }
        // Only a title? The card shows it big, rather than an empty window.
        return .note(notes.isEmpty ? title : notes)
    }
}

/// An open coin, like a pass open in Wallet. It slides out of the stack (the
/// card grows into place), and goes back with Done, a drag down, or a tap on
/// the stack of coins at the bottom.
struct CoinDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .caption) private var actionSize: CGFloat = 56
    let coin: Coin
    let namespace: Namespace.ID
    /// The other coins (the next ones first), stacked at the bottom like in Wallet.
    let pile: [Coin]
    let onClose: () -> Void
    let onDelete: () -> Void
    /// Brings another coin up from the stack at the bottom.
    let onSelect: (String) -> Void

    /// How much of each card in the bottom stack shows: its title.
    @ScaledMetric(relativeTo: .headline) private var stripe: CGFloat = 48
    /// A card in the bottom stack being pulled up for a look, and how far.
    @State private var peeking: String?
    @State private var peekLift: CGFloat = 0

    @State private var drag: CGFloat = 0
    /// True while a finger is down; if the system cancels the drag, the card springs back.
    @GestureState private var dragging = false
    @State private var closing = false
    @State private var appeared = false
    /// False while the card is still flying open: a quick second tap on the
    /// card must not land on a picture or the map and open something else.
    @State private var settled = false
    @State private var fullScreen: FullScreenPicture?
    @State private var editing = false
    @State private var sharing: ShareItems?
    @State private var confirmDelete = false
    @State private var confirmMovePin = false
    @State private var locating = false
    @State private var locationOff = false
    @State private var finder = LocationFinder()
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var typeSize

    /// A note long enough to need scrolling: there, dragging down scrolls the
    /// note, and the coin closes from its title bar (or Done) instead.
    private var isScrollingNote: Bool {
        if case .note(let text) = coin.face { return Self.noteScrolls(text) }
        return false
    }

    private static func noteScrolls(_ text: String) -> Bool {
        text.count > 220 || text.filter { $0 == "\n" }.count > 5
    }
    /// Typed notes show under the card when the card is busy showing pictures or a map.
    private var notesBelow: String? {
        let n = coin.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty || !coin.hasContent ? nil : n
    }
    /// Pictures beyond what the card face shows, as thumbnails under the card.
    private var showsThumbnails: Bool { coin.pictures.count > 1 || (coin.pin != nil && !coin.pictures.isEmpty) }

    var body: some View {
        GeometryReader { geo in
            let pileCount = min(pile.count, geo.size.height < 700 ? 2 : 3)
            let pileHeight = CGFloat(pileCount) * stripe + 6
            let reserved: CGFloat = 52 + 6 + 36 + min(actionSize, 80) + 44 + pileHeight
                + (notesBelow == nil ? 0 : 86) + (showsThumbnails ? 72 : 0)
            let cardHeight = max(geo.size.height < 640 ? 230 : 300, min(geo.size.height - reserved, 620))
            VStack(spacing: 0) {
                topBar
                    .opacity(appeared ? 1 : 0)
                card
                    .matchedCard(id: coin.id, in: namespace, enabled: !reduceMotion)
                    .frame(height: cardHeight)
                    .padding(.horizontal, 16)
                    .padding(.top, 6 + drag)
                    .simultaneousGesture(dragToClose, including: isScrollingNote ? .subviews : .all)
                // Under the card: scrolls only if large text makes it too tall.
                ScrollView {
                    VStack(spacing: 14) {
                        if showsThumbnails { thumbnails }
                        if let notesBelow { notesPanel(notesBelow) }
                        actions
                    }
                    .padding(.top, 16)
                    .padding(.bottom, 16)
                }
                .scrollBounceBehavior(.basedOnSize)
                .opacity(appeared ? max(0, 1 - drag / 140) : 0)
                .offset(y: appeared || reduceMotion ? 0 : 28)
                // The next coins, below everything else (never on top of a button).
                pileView(count: pileCount, cardHeight: cardHeight)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.9).delay(0.1)) { appeared = true }
        }
        .task {
            try? await Task.sleep(for: .milliseconds(450))
            settled = true
        }
        .onChange(of: dragging) { _, isDragging in
            if !isDragging && !closing && drag != 0 {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { drag = 0 }
            }
        }
        .fullScreenCover(item: $fullScreen) { ref in
            ViewerView(coinId: coin.id, startIndex: ref.index)
        }
        .sheet(isPresented: $editing) { EditorView(coinId: coin.id) }
        .sheet(item: $sharing) { item in
            ActivitySheet(items: item.items).presentationDetents([.medium, .large])
        }
        .alert("Are you sure you want to delete?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("“\(coin.title)” and everything in it will be deleted. This cannot be undone.")
        }
        .alert("Location is off", isPresented: $locationOff) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Turn on Location for Coin Purse in Settings to drop a pin.")
        }
        // An alert, so Cancel is always a button you can see.
        .alert("Move this pin to where you are now?", isPresented: $confirmMovePin) {
            Button("Move Pin Here") { Task { await dropPin() } }
            Button("Remove Pin", role: .destructive) { Task { await removePin() } }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: Pieces

    private var topBar: some View {
        HStack {
            Spacer()
            Button(action: onClose) {
                Text("Done")
                    .font(.headline)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .frame(minHeight: 40)
                    .glassCapsule()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .accessibilityIdentifier("Done")
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
    }

    private var card: some View {
        VStack(spacing: 0) {
            CoinCardHeader(coin: coin, isOpen: true)
                // The title bar always drags the coin down, even over a long note.
                .contentShape(Rectangle())
                .gesture(isScrollingNote ? dragToClose : nil)
            faceView
                .overlay(alignment: .bottom) { tapHint }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
                .allowsHitTesting(settled)
        }
        .cardSurface(coin.accent)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("openCoin")
    }

    /// The card's window: the map pin, else the first picture, else the note.
    @ViewBuilder private var faceView: some View {
        switch coin.face {
        case .picture(let picture, let index):
            CachedImage(picture: picture, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.22))
                .contentShape(Rectangle())
                .onTapGesture { fullScreen = FullScreenPicture(index: index) }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Picture 1")
                .accessibilityHint("Shows it full screen")
        case .map(let pin):
            LivePinMap(pin: pin, name: coin.title, tint: coin.accentColor)
                .contentShape(Rectangle())
                .onTapGesture { MapsLink.openDirections(to: pin, name: coin.title) }
                .accessibilityAddTraits(.isButton)
        case .note(let text):
            let words = Text(LinkedText.make(text))
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .lineSpacing(5)
                .foregroundStyle(.white)
                .tint(.white)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .accessibilityIdentifier("noteText")
            Group {
                if Self.noteScrolls(text) {
                    ScrollView { words }
                } else {
                    // Short: no scrolling, so a drag down always puts the coin back.
                    words.frame(maxHeight: .infinity, alignment: .top)
                }
            }
            .background(Color.black.opacity(0.18))
        }
    }

    /// What a tap does, on the card itself: a small glass chip.
    @ViewBuilder private var tapHint: some View {
        switch coin.face {
        case .map:
            hintChip(Label("Directions", systemImage: "figure.walk"))
        case .picture:
            hintChip(Label("Full size", systemImage: "arrow.up.left.and.arrow.down.right"))
        case .note:
            EmptyView()
        }
    }

    private func hintChip(_ label: some View) -> some View {
        label
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.black.opacity(0.55), in: Capsule())
        .padding(.bottom, 10)
        .allowsHitTesting(false)
    }

    /// Every picture in the coin; tap one to see it full size.
    private var thumbnails: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Array(coin.pictures.enumerated()), id: \.element) { i, picture in
                    Button { fullScreen = FullScreenPicture(index: i) } label: {
                        CachedImage(picture: picture, contentMode: .fill)
                            .frame(width: 60, height: 60)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.12)))
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel("Picture \(i + 1)")
                    .accessibilityHint("Shows it full screen")
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }

    private func notesPanel(_ text: String) -> some View {
        let words = Text(LinkedText.make(text))
            .font(.subheadline)
            .foregroundStyle(.primary)
            .tint(Color.accentColor)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        // Shown in full at any text size (the area under the card scrolls).
        return words
            .fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: 44)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 16)
    }

    private var actions: some View {
        // Four across; at the largest text sizes, one full-width row each.
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 0))
        return layout {
            actionButton("Share", "square.and.arrow.up") { Task { await share() } }
            actionButton(coin.pin == nil ? "Add Pin" : "Move Pin", "mappin.and.ellipse", busy: locating) {
                if coin.pin == nil { Task { await dropPin() } } else { confirmMovePin = true }
            }
            actionButton("Edit", "pencil") { editing = true }
            actionButton("Delete", "trash", tint: .red) { confirmDelete = true }
        }
        .padding(.horizontal, typeSize.isAccessibilitySize ? 16 : 20)
    }

    private func actionButton(_ title: String, _ icon: String, tint: Color = .primary, busy: Bool = false,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if typeSize.isAccessibilitySize {
                HStack(spacing: 14) {
                    Group {
                        if busy { ProgressView() } else { Image(systemName: icon).foregroundStyle(tint) }
                    }
                    .font(.title3.weight(.semibold))
                    Text(title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(tint == .red ? .red : .primary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, minHeight: 56)
                .glassPanel()
                .contentShape(Rectangle())
            } else {
                VStack(spacing: 7) {
                    ZStack {
                        if busy {
                            ProgressView()
                        } else {
                            Image(systemName: icon)
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(tint)
                        }
                    }
                    .frame(width: actionSize, height: actionSize)
                    .glassCircle()
                    Text(title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                }
                .frame(maxWidth: .infinity)
                // The whole column takes the tap, not just the symbol.
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(PressableStyle())
        .disabled(busy)
        .accessibilityLabel(title)
    }

    /// The next coins, stacked at the bottom like passes in Wallet, each
    /// showing its title. Pull one up to see what is on it (let go and it drops
    /// back); pull it most of the way, or tap it, and it takes this coin's place.
    @ViewBuilder private func pileView(count: Int, cardHeight: CGFloat) -> some View {
        let cards = Array(pile.prefix(count))
        if !cards.isEmpty {
            ZStack(alignment: .top) {
                ForEach(Array(cards.enumerated()), id: \.element.id) { i, c in
                    let lifted = peeking == c.id
                    PileCard(coin: c, stripe: stripe, height: cardHeight)
                        // The same card as in the purse: it rises into place when chosen.
                        .matchedCard(id: c.id, in: namespace, enabled: !reduceMotion)
                        // Touch areas before the card moves into its place, so they move with it.
                        .contentShape(Rectangle())
                        .onTapGesture { onSelect(c.id) }
                        .gesture(pullUp(c))
                        // To VoiceOver, each is one button the size of its title strip.
                        .accessibilityHidden(true)
                        .overlay(alignment: .top) {
                            Color.clear
                                .frame(height: stripe)
                                .accessibilityElement()
                                .accessibilityLabel(c.title)
                                .accessibilityHint("Opens this coin instead")
                                .accessibilityAddTraits(.isButton)
                                .accessibilityAction { onSelect(c.id) }
                                .accessibilityIdentifier("pileCard")
                        }
                        .offset(y: CGFloat(i) * stripe + (lifted ? peekLift : 0))
                        .shadow(color: .black.opacity(lifted ? 0.35 : 0), radius: 16, y: -4)
                        .zIndex(lifted ? 100 : Double(i))
                }
            }
            .padding(.horizontal, 16)
            // Only the titles take room; the cards run on past the bottom of the screen.
            .frame(height: CGFloat(cards.count) * stripe + 6, alignment: .top)
            .frame(maxWidth: .infinity)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 80)
        }
    }

    private func pullUp(_ c: Coin) -> some Gesture {
        // Measured on the screen, not on the card that is itself moving (that
        // made it jitter as each step undid the last).
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { value in
                if peeking != c.id { peeking = c.id }
                // Up follows the finger; down barely moves.
                let dy = value.translation.height
                peekLift = dy < 0 ? dy : dy * 0.15
            }
            .onEnded { value in
                let far = value.translation.height < -170 || value.predictedEndTranslation.height < -320
                if far {
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                    peeking = nil
                    peekLift = 0
                    onSelect(c.id)
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        peeking = nil
                        peekLift = 0
                    }
                }
            }
    }

    private var dragToClose: some Gesture {
        DragGesture(minimumDistance: 14, coordinateSpace: .global)
            .updating($dragging) { _, active, _ in active = true }
            .onChanged { value in
                let dy = value.translation.height
                guard dy > 0, abs(dy) > abs(value.translation.width) else { return }
                // Follows the finger, a little heavier the further it goes.
                drag = dy < 200 ? dy : 200 + (dy - 200) * 0.4
            }
            .onEnded { value in
                if drag > 110 || (drag > 0 && value.predictedEndTranslation.height > 320) {
                    closing = true
                    onClose()
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { drag = 0 }
                }
            }
    }

    // MARK: Actions

    private func share() async {
        let c = coin
        switch c.face {
        case .map(let pin):
            var items: [Any] = [c.title]
            if let link = MapsLink.shareURL(for: pin, name: c.title) { items.append(link) }
            sharing = ShareItems(items: items)
        case .picture:
            var images: [Any] = []
            for picture in c.pictures {
                if let url = model.url(for: picture),
                   let image = await ImageCache.shared.image(key: picture.key, url: url) {
                    images.append(image)
                }
            }
            guard !images.isEmpty else { return }
            sharing = ShareItems(items: images)
        case .note(let text):
            sharing = ShareItems(items: [text])
        }
    }

    private func dropPin() async {
        // The coin showing when Pin was tapped.
        let id = coin.id
        let hadPin = coin.pin != nil
        locating = true
        defer { locating = false }
        do {
            let pin = try await finder.currentPin()
            try await model.setPin(pin, on: id)
            model.show(hadPin ? "Pin moved" : "Pinned")
        } catch is CancellationError {
        } catch LocationFinder.Failure.denied {
            locationOff = true
        } catch {
            model.show(error.localizedDescription)
        }
    }

    private func removePin() async {
        let id = coin.id
        do {
            try await model.setPin(nil, on: id)
        } catch {
            model.show(error.localizedDescription)
        }
    }
}

/// A button that shrinks a little under your finger.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct FullScreenPicture: Identifiable {
    let index: Int
    var id: Int { index }
}

struct ShareItems: Identifiable {
    let id = UUID()
    let items: [Any]
}

/// The system share sheet for any mix of pictures, text and links.
struct ActivitySheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
