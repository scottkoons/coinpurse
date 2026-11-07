import SwiftUI

enum CardMetrics {
    static let corner: CGFloat = 22
    /// The colored top of a card: all you see of it in the stack.
    static let header: CGFloat = 68
    /// A whole card in the stack (the last one shows all of it).
    static let stackHeight: CGFloat = 250
    /// How much of each card shows above the next one in the stack.
    static let peek: CGFloat = 62
}

/// One coin as a card, colored like a pass: its name on top and a window
/// below showing what is inside (a picture, a map pin or a note).
struct CoinCardView: View {
    let coin: Coin
    /// False when the next card covers this one's window (all but the last in the stack).
    var faceShowing = true
    /// Set to draw only the top of the card (its bar), as a card of its own.
    var height: CGFloat?
    /// Hidden with Face ID and not shown yet: the note line and window are covered.
    var veiled = false

    var body: some View {
        VStack(spacing: 0) {
            CoinCardHeader(coin: coin, veiled: veiled)
            CoinFace(coin: coin, veiled: veiled)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
                // VoiceOver skips what is tucked behind the next card.
                .accessibilityHidden(!faceShowing)
        }
        .frame(height: height, alignment: .top)
        .cardSurface(coin.accent)
    }
}

/// The top of a card: a glass symbol for what the coin holds, its title and
/// a short line under it, and how many pictures it has. (Delete is a swipe,
/// a VoiceOver action, or the button inside the coin.)
struct CoinCardHeader: View {
    let coin: Coin
    /// Hidden with Face ID and not shown yet: the second line says so instead
    /// of showing the start of the note.
    var veiled = false
    /// Open, the note shows in full below, so the second line gives details
    /// (pin time, pictures, date) instead of repeating it.
    var isOpen = false
    @ScaledMetric(relativeTo: .headline) private var height: CGFloat = CardMetrics.header
    @ScaledMetric(relativeTo: .headline) private var glyph: CGFloat = 36
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(spacing: 10) {
            // At the largest text sizes the title gets this room instead.
            if !typeSize.isAccessibilitySize {
                CoinGlyph(coin: coin, size: min(glyph, 44), veiled: veiled)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(coin.title.isEmpty ? "Untitled" : coin.title)
                    .font(.system(.headline, design: .rounded).weight(.semibold))
                    // Open, the whole name shows, even at the largest text sizes.
                    .lineLimit(isOpen ? (typeSize.isAccessibilitySize ? 2 : 3) : 1)
                    .fixedSize(horizontal: false, vertical: isOpen)
                    .accessibilityIdentifier("coinTitle")
                Text(veiled ? lockedSubtitle : subtitle)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(isOpen ? nil : 1)
                    .fixedSize(horizontal: false, vertical: isOpen)
            }
            Spacer(minLength: 4)
            // Open, the line under the title says this instead.
            if !typeSize.isAccessibilitySize && !isOpen { contents }
            // This coin asks for Face ID to open.
            if coin.hidden {
                Image(systemName: "faceid")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
                    .accessibilityLabel("Needs Face ID")
            }
        }
        .foregroundStyle(.white)
        .padding(.leading, 14)
        .padding(.trailing, 16)
        .padding(.vertical, isOpen ? 8 : 0)
        // In the stack every top is the same height; open, it grows with its text
        // and claims all of that height (the picture or map takes what is left).
        .frame(minHeight: height, maxHeight: isOpen ? nil : height)
        .fixedSize(horizontal: false, vertical: isOpen)
    }

    /// Small glass chips: how many pictures, and a map pin when the symbol
    /// on the left is about something else.
    @ViewBuilder private var contents: some View {
        HStack(spacing: 6) {
            if coin.pictures.count > 1 {
                Label("\(coin.pictures.count)", systemImage: "photo.on.rectangle")
                    .accessibilityLabel("\(coin.pictures.count) pictures")
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .cardGlass(Capsule())
            }
            if coin.pin != nil && !coin.pictures.isEmpty {
                Image(systemName: "mappin")
                    .font(.system(size: 12, weight: .heavy))
                    .accessibilityLabel("Has a map pin")
                    .frame(width: 24, height: 24)
                    .cardGlass(Circle())
            }
        }
        .font(.caption.weight(.bold))
        .labelStyle(.titleAndIcon)
        .foregroundStyle(.white)
    }

    /// The start of the note, else when it was pinned, else the date.
    private var subtitle: String {
        if isOpen { return details }
        let firstLine = coin.notes.split(separator: "\n").first.map(String.init) ?? ""
        if !firstLine.isEmpty { return firstLine }
        if let pin = coin.pin { return pin.pinnedLabel }
        guard let ms = coin.updatedAt ?? coin.createdAt else { return "" }
        return Date(timeIntervalSince1970: ms / 1000).formatted(date: .abbreviated, time: .omitted)
    }

    /// Hidden and not opened yet: when it was pinned, else the date (never the note).
    private var lockedSubtitle: String {
        if let pin = coin.pin { return pin.pinnedLabel }
        guard let ms = coin.updatedAt ?? coin.createdAt else { return "" }
        return Date(timeIntervalSince1970: ms / 1000).formatted(date: .abbreviated, time: .omitted)
    }

    /// "Pinned at 2:14 PM · 2 pictures", or the date for a plain note.
    private var details: String {
        var parts: [String] = []
        if let pin = coin.pin { parts.append(pin.pinnedLabel) }
        if coin.pictures.count > 1 { parts.append("\(coin.pictures.count) pictures") }
        if parts.isEmpty, let ms = coin.updatedAt ?? coin.createdAt {
            parts.append(Date(timeIntervalSince1970: ms / 1000).formatted(date: .abbreviated, time: .omitted))
        }
        return parts.joined(separator: " · ")
    }
}

/// A coin waiting in the stack under an open coin: its title along the top
/// and its window below, ready to be pulled up for a look.
struct PileCard: View {
    let coin: Coin
    /// How much of the card shows above the next one: just its title.
    let stripe: CGFloat
    let height: CGFloat
    var veiled = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                CoinGlyph(coin: coin, size: 28, veiled: veiled)
                Text(coin.title.isEmpty ? "Untitled" : coin.title)
                    .font(.system(.headline, design: .rounded).weight(.semibold))
                    .lineLimit(1)
                    .accessibilityIdentifier("pileTitle")
                Spacer(minLength: 0)
                if coin.hidden {
                    Image(systemName: "faceid")
                        .font(.caption.weight(.bold))
                        .accessibilityLabel("Hidden")
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: stripe)
            CoinFace(coin: coin, veiled: veiled)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
        }
        .frame(height: height, alignment: .top)
        .cardSurface(coin.accent)
    }
}

/// What a coin holds, on a small pane of glass: a tiny copy of its first
/// picture, else a symbol for a map pin, a list or a note.
struct CoinGlyph: View {
    let coin: Coin
    let size: CGFloat
    /// Hidden with Face ID and not shown yet: a symbol, never the picture.
    var veiled = false

    private var symbol: String {
        if let first = coin.pictures.first { return first.isVideo ? "video.fill" : "photo" }
        if coin.pin != nil { return "mappin.and.ellipse" }
        return coin.notes.contains("\n") ? "list.bullet" : "text.alignleft"
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
        Group {
            if let first = coin.pictures.first, !veiled {
                CachedImage(picture: first, contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(shape)
                    // The same glass edge as the symbols.
                    .overlay {
                        shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.6), .white.opacity(0.15)],
                                                          startPoint: .top, endPoint: .bottom), lineWidth: 1)
                    }
            } else {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.44, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .cardGlass(shape)
            }
        }
        .accessibilityHidden(true)
    }
}

extension View {
    /// Glass on a card: a clear tint of white with a bright edge on top, light
    /// enough to draw on every card in a big purse (real Liquid Glass is kept
    /// for the buttons that float over the purse).
    func cardGlass<S: InsettableShape>(_ shape: S) -> some View {
        background {
            shape.fill(.white.opacity(0.17))
                .overlay {
                    shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0.06)],
                                                      startPoint: .top, endPoint: .bottom), lineWidth: 0.8)
                }
        }
    }
}

/// The window in a card: the map pin, else the first picture, else the note.
struct CoinFace: View {
    let coin: Coin
    /// Hidden with Face ID and not opened: the window is blurred, so you can
    /// tell something is there but not read it (the card itself shows as usual).
    var veiled = false

    var body: some View {
        // Always exactly the room it is given (a tucked-in card gives it very
        // little), so what is inside can never push the card out of shape.
        Color.clear.overlay(alignment: .top) {
            if veiled {
                face
                    // Blurred enough that no word or code can be read, not so much that
                    // you cannot tell a picture or a note is there.
                    .blur(radius: 14, opaque: true)
                    // A live map does not take the blur: it is frosted instead.
                    .overlay { if coin.pictures.isEmpty && coin.pin != nil { Rectangle().fill(.regularMaterial) } }
                    .accessibilityHidden(true)
            } else {
                face
            }
        }
        .clipped()
    }

    private var face: some View {
        Group {
            if let first = coin.pictures.first {
                // The window keeps the card's size; the picture fills it from the top.
                Color.clear
                    .overlay(alignment: .top) {
                        CachedImage(picture: first, contentMode: .fill)
                    }
                    // A video: a play button where the window shows it.
                    .overlay(alignment: .top) { if first.isVideo { PlayBadge().padding(.top, 54) } }
                    .clipped()
                    .background(Color.black.opacity(0.2))
            } else if let pin = coin.pin {
                PinMapView(pin: pin, tint: coin.accentColor)
            } else {
                // Only a title? Show it big, rather than an empty card.
                NoteFace(notes: coin.notes.isEmpty ? coin.title : coin.notes)
            }
        }
        // Never drawn smaller than a full window: a tucked card shows the top of
        // it, and as the card opens (or the purse fans) more is simply revealed,
        // instead of the map or picture being redrawn at every size.
        .frame(maxWidth: .infinity, minHeight: 170, maxHeight: .infinity)
    }
}

/// A coin with only words: its text, like a note card.
struct NoteFace: View {
    let notes: String

    /// A code or a few words shows big; longer notes get smaller type.
    private var font: Font {
        switch notes.count {
        case ..<25: return .system(.largeTitle, design: .rounded).weight(.bold)
        case ..<90: return .system(.title, design: .rounded).weight(.semibold)
        default: return .system(.title3, design: .rounded).weight(.medium)
        }
    }

    var body: some View {
        Text(notes)
            .font(font)
            .foregroundStyle(.white)
            .lineSpacing(4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(18)
            .background(Color.black.opacity(0.18))
            // Long notes fade out at the bottom; open the coin to read them all.
            .mask(LinearGradient(stops: [.init(color: .black, location: 0.82), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
    }
}

/// The card itself: the coin's color as a rich gradient with a soft shine
/// on top, a glass edge and a shadow, like a pass in Wallet.
struct CardSurface: ViewModifier {
    let accent: Int
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .background {
                ZStack(alignment: .top) {
                    // Deep enough everywhere for white text.
                    LinearGradient(colors: [AccentPalette.cardColors(accent).top, AccentPalette.cardColors(accent).bottom],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    // A soft shine along the top, like light on glass. Faint enough
                    // that the title stays easy to read.
                    LinearGradient(colors: [.white.opacity(0.14), .white.opacity(0)], startPoint: .top, endPoint: .bottom)
                        .frame(height: CardMetrics.header)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: CardMetrics.corner, style: .continuous))
            .overlay {
                // A glass edge: bright along the top, fading down the sides.
                RoundedRectangle(cornerRadius: CardMetrics.corner, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.38), .white.opacity(0.1)],
                                                 startPoint: .top, endPoint: .bottom), lineWidth: 1)
            }
            .shadow(color: .black.opacity(scheme == .dark ? 0.4 : 0.18), radius: 14, y: 8)
    }
}

extension View {
    func cardSurface(_ accent: Int) -> some View { modifier(CardSurface(accent: accent)) }
}

/// On a picture that is a video: a play button.
struct PlayBadge: View {
    var small = false

    var body: some View {
        Image(systemName: "play.fill")
            .font(small ? .caption.weight(.bold) : .title2.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: small ? 28 : 56, height: small ? 28 : 56)
            .background(.black.opacity(0.5), in: Circle())
            .accessibilityHidden(true)
    }
}
