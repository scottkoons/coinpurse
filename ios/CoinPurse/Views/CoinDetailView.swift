import SwiftUI

/// One page inside an open coin: a picture, its map pin, or its note.
enum CoinPage: Hashable {
    case picture(Picture, index: Int)
    case map(Pin)
    case note(String)
}

extension Coin {
    /// The map comes first (where you parked matters most), then pictures.
    /// A coin with neither shows its note.
    var pages: [CoinPage] {
        var list: [CoinPage] = []
        if let pin { list.append(.map(pin)) }
        list += pictures.enumerated().map { .picture($1, index: $0) }
        // Only a title? The page shows it big, rather than an empty card.
        if list.isEmpty { list.append(.note(notes.isEmpty ? title : notes)) }
        return list
    }
}

/// An open coin. It slides out of the stack (the card grows into place), and
/// goes back with Done, a swipe down, or a tap on the coins at the bottom.
struct CoinDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .caption) private var actionSize: CGFloat = 56
    let coin: Coin
    let namespace: Namespace.ID
    /// The next few coins, peeking up from the bottom like the rest of a stack.
    let pile: [Coin]
    let onClose: () -> Void
    let onDelete: () -> Void

    @State private var page = 0
    @State private var drag: CGFloat = 0
    /// True while a finger is down; if the system cancels the drag, the card springs back.
    @GestureState private var dragging = false
    @State private var closing = false
    @State private var appeared = false
    @State private var fullScreen: FullScreenPicture?
    @State private var editing = false
    @State private var sharing: ShareItems?
    @State private var confirmDelete = false
    @State private var confirmMovePin = false
    @State private var locating = false
    @State private var locationOff = false
    @State private var finder = LocationFinder()
    @Environment(\.openURL) private var openURL

    private var pages: [CoinPage] { coin.pages }
    /// A note long enough to need scrolling: there, dragging down scrolls the
    /// note, and the coin closes from its title bar (or Done) instead.
    private var isScrollingNote: Bool {
        if case .note(let text) = currentPage { return Self.noteScrolls(text) }
        return false
    }

    private static func noteScrolls(_ text: String) -> Bool {
        text.count > 220 || text.filter { $0 == "\n" }.count > 5
    }
    private var currentPage: CoinPage? { pages.indices.contains(page) ? pages[page] : pages.first }
    /// Typed notes show under the card when the card is busy showing pictures or a map.
    private var notesBelow: String? {
        let n = coin.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty || !coin.hasContent ? nil : n
    }

    var body: some View {
        GeometryReader { geo in
            let reserved: CGFloat = 52 + 6 + 36 + actionSize + 44 + 58 + (notesBelow == nil ? 0 : 86)
            let cardHeight = max(300, min(geo.size.height - reserved, 620))
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
                        pageDots
                        if let notesBelow { notesPanel(notesBelow) }
                        actions
                    }
                    .padding(.top, 12)
                    // Clear of the coins peeking up at the bottom.
                    .padding(.bottom, 64)
                }
                .scrollBounceBehavior(.basedOnSize)
                .opacity(appeared ? max(0, 1 - drag / 140) : 0)
                .offset(y: appeared || reduceMotion ? 0 : 28)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .overlay(alignment: .bottom) {
                pileView
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 60)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.9).delay(0.1)) { appeared = true }
        }
        .onChange(of: pages.count) { _, count in
            if page >= count { page = max(0, count - 1) }
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
        .confirmationDialog("Move this pin to where you are now?", isPresented: $confirmMovePin, titleVisibility: .visible) {
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
                    .frame(height: 40)
                    .glassCapsule()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .accessibilityIdentifier("Done")
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    private var card: some View {
        VStack(spacing: 0) {
            CoinCardHeader(coin: coin, isOpen: true)
                // The title bar always drags the coin down, even over a long note.
                .contentShape(Rectangle())
                .gesture(isScrollingNote ? dragToClose : nil)
            TabView(selection: $page) {
                ForEach(Array(pages.enumerated()), id: \.offset) { i, p in
                    pageView(p)
                        .overlay(alignment: .bottom) { tapHint(for: p) }
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
        .cardSurface(coin.accent)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("openCoin")
    }

    @ViewBuilder private func pageView(_ p: CoinPage) -> some View {
        switch p {
        case .picture(let picture, let index):
            CachedImage(picture: picture, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.22))
                .contentShape(Rectangle())
                .onTapGesture { fullScreen = FullScreenPicture(index: index) }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Picture \(index + 1)")
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

    /// What a tap does, on the page itself: a small glass chip.
    @ViewBuilder private func tapHint(for p: CoinPage) -> some View {
        switch p {
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

    /// Dots for the pages (a pin for the map).
    private var pageDots: some View {
        VStack(spacing: 10) {
            if pages.count > 1 {
                HStack(spacing: 0) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { i, p in
                        Group {
                            if case .map = p {
                                Image(systemName: "mappin")
                                    .font(.system(size: 10, weight: .bold))
                            } else {
                                Circle().frame(width: 7, height: 7)
                            }
                        }
                        .foregroundStyle(.primary.opacity(i == page ? 1 : 0.3))
                        // A full-size touch target around each small dot.
                        .frame(width: 28, height: 44)
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation { page = i } }
                    }
                }
                .accessibilityElement()
                .accessibilityLabel("Page \(page + 1) of \(pages.count)")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: if page < pages.count - 1 { withAnimation { page += 1 } }
                    case .decrement: if page > 0 { withAnimation { page -= 1 } }
                    @unknown default: break
                    }
                }
            }
        }
        .frame(minHeight: 12)
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
        HStack(spacing: 0) {
            actionButton("Share", "square.and.arrow.up") { Task { await share() } }
            actionButton(coin.pin == nil ? "Add Pin" : "Move Pin", "mappin.and.ellipse", busy: locating) {
                if coin.pin == nil { Task { await dropPin() } } else { confirmMovePin = true }
            }
            actionButton("Edit", "pencil") { editing = true }
            actionButton("Delete", "trash", tint: .red) { confirmDelete = true }
        }
        .padding(.horizontal, 20)
    }

    private func actionButton(_ title: String, _ icon: String, tint: Color = .primary, busy: Bool = false,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
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
        .buttonStyle(PressableStyle())
        .disabled(busy)
        .accessibilityLabel(title)
    }

    /// The coins behind this one, peeking up at the bottom. Tap to go back.
    private var pileView: some View {
        ZStack(alignment: .top) {
            ForEach(Array(pile.prefix(3).enumerated()).reversed(), id: \.element.id) { i, c in
                CoinCardHeader(coin: c)
                    .frame(maxWidth: .infinity)
                    .cardSurface(c.accent)
                    .scaleEffect(1 - CGFloat(i) * 0.05, anchor: .top)
                    .offset(y: CGFloat(i) * 9)
                    .opacity(1 - Double(i) * 0.18)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 56, alignment: .top)
        .offset(y: 34)
        .contentShape(Rectangle())
        .onTapGesture(perform: onClose)
        .accessibilityElement()
        .accessibilityLabel("Back to purse")
        .accessibilityAddTraits(.isButton)
    }

    private var dragToClose: some Gesture {
        DragGesture(minimumDistance: 14)
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
        switch currentPage {
        case .picture(let picture, _):
            guard let url = model.url(for: picture),
                  let image = await ImageCache.shared.image(key: picture.key, url: url) else { return }
            sharing = ShareItems(items: [image])
        case .map(let pin):
            var items: [Any] = [coin.title]
            if let link = MapsLink.shareURL(for: pin, name: coin.title) { items.append(link) }
            sharing = ShareItems(items: items)
        case .note(let text):
            sharing = ShareItems(items: [text])
        case nil:
            break
        }
    }

    private func dropPin() async {
        locating = true
        defer { locating = false }
        do {
            let pin = try await finder.currentPin()
            try await model.setPin(pin, on: coin.id)
            withAnimation { page = 0 }
            model.show(coin.pin == nil ? "Pinned" : "Pin moved")
        } catch is CancellationError {
        } catch LocationFinder.Failure.denied {
            locationOff = true
        } catch {
            model.show(error.localizedDescription)
        }
    }

    private func removePin() async {
        do {
            try await model.setPin(nil, on: coin.id)
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
