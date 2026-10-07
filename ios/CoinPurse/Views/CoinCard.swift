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
    var onDelete: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            CoinCardHeader(coin: coin, onDelete: onDelete)
            CoinFace(coin: coin)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
                // VoiceOver skips what is tucked behind the next card.
                .accessibilityHidden(!faceShowing)
        }
        .cardSurface(coin.accent)
    }
}

/// The top of a card: title and a short line under it, little symbols for
/// what the coin holds, and its trash can.
struct CoinCardHeader: View {
    let coin: Coin
    var onDelete: (() -> Void)?
    /// Open, the note shows in full below, so the second line gives details
    /// (pin time, pictures, date) instead of repeating it.
    var isOpen = false
    @ScaledMetric(relativeTo: .headline) private var height: CGFloat = CardMetrics.header
    @ScaledMetric(relativeTo: .headline) private var emblem: CGFloat = 26
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(spacing: 10) {
            // Every card carries a silver coin, like a pass carries its logo.
            // At the largest text sizes the title gets that room instead.
            if !typeSize.isAccessibilitySize {
                CoinEmblem(size: emblem)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(coin.title.isEmpty ? "Untitled" : coin.title)
                    .font(.system(.headline, design: .rounded).weight(.bold))
                    // Open, the whole name shows, even at the largest text sizes.
                    .lineLimit(isOpen ? (typeSize.isAccessibilitySize ? 2 : 3) : 1)
                    .fixedSize(horizontal: false, vertical: isOpen)
                    .accessibilityIdentifier("coinTitle")
                Text(subtitle)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(isOpen ? nil : 1)
                    .fixedSize(horizontal: false, vertical: isOpen)
            }
            Spacer(minLength: 4)
            if !typeSize.isAccessibilitySize { contents }
            if let onDelete {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 34, height: 34)
                        .background(.white.opacity(0.16), in: Circle())
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete \(coin.title)")
            }
        }
        .foregroundStyle(.white)
        .padding(.leading, 14)
        .padding(.trailing, onDelete == nil ? 16 : 6)
        .padding(.vertical, isOpen ? 8 : 0)
        // In the stack every top is the same height; open, it grows with its text
        // and claims all of that height (the picture or map takes what is left).
        .frame(minHeight: height, maxHeight: isOpen ? nil : height)
        .fixedSize(horizontal: false, vertical: isOpen)
    }

    /// Small symbols: more than one picture, a map pin, a note.
    @ViewBuilder private var contents: some View {
        HStack(spacing: 6) {
            if coin.pictures.count > 1 {
                Label("\(coin.pictures.count)", systemImage: "photo.on.rectangle")
                    .accessibilityLabel("\(coin.pictures.count) pictures")
            }
            if coin.pin != nil {
                Image(systemName: "mappin")
                    .font(.system(size: 13, weight: .heavy))
                    .accessibilityLabel("Has a map pin")
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

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                CoinEmblem(size: 22)
                Text(coin.title.isEmpty ? "Untitled" : coin.title)
                    .font(.system(.headline, design: .rounded).weight(.bold))
                    .lineLimit(1)
                    .accessibilityIdentifier("pileTitle")
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: stripe)
            CoinFace(coin: coin)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
        }
        .frame(height: height, alignment: .top)
        .cardSurface(coin.accent)
    }
}

/// A small silver ¢ coin, drawn crisply at any size.
struct CoinEmblem: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [Color(white: 0.97), Color(white: 0.72), Color(white: 0.88)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            Circle()
                .strokeBorder(LinearGradient(colors: [.white, Color(white: 0.55)], startPoint: .top, endPoint: .bottom),
                              lineWidth: max(1, size * 0.07))
            Circle()
                .strokeBorder(Color(white: 0.6).opacity(0.6), lineWidth: 0.6)
                .padding(size * 0.14)
            Text("¢")
                .font(.system(size: size * 0.56, weight: .heavy, design: .rounded))
                .foregroundStyle(Color(white: 0.3))
                .offset(y: -size * 0.02)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.28), radius: 1.5, y: 1)
        .accessibilityHidden(true)
    }
}

/// The window in a card: the map pin, else the first picture, else the note.
struct CoinFace: View {
    let coin: Coin

    var body: some View {
        // Always exactly the room it is given (a tucked-in card gives it very
        // little), so what is inside can never push the card out of shape.
        Color.clear.overlay(alignment: .top) { face }.clipped()
    }

    private var face: some View {
        Group {
            if let pin = coin.pin {
                PinMapView(pin: pin, tint: coin.accentColor)
            } else if let first = coin.pictures.first {
                // The window keeps the card's size; the picture fills it from the top.
                Color.clear
                    .overlay(alignment: .top) {
                        CachedImage(picture: first, contentMode: .fill)
                    }
                    .clipped()
                    .background(Color.black.opacity(0.2))
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

/// The card itself: the coin's color as a rich gradient with a soft sheen,
/// a hairline edge and a shadow, like a pass in Wallet.
struct CardSurface: ViewModifier {
    let accent: Int
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    // Deep enough everywhere for white text (no light sheen over the title).
                    LinearGradient(colors: [AccentPalette.cardColors(accent).top, AccentPalette.cardColors(accent).bottom],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: CardMetrics.corner, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: CardMetrics.corner, style: .continuous)
                    .strokeBorder(.white.opacity(0.16), lineWidth: 1)
            }
            .shadow(color: .black.opacity(scheme == .dark ? 0.4 : 0.18), radius: 14, y: 8)
    }
}

extension View {
    func cardSurface(_ accent: Int) -> some View { modifier(CardSurface(accent: accent)) }
}
