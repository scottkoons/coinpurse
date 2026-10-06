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

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(coin.title.isEmpty ? "Untitled" : coin.title)
                    .font(.system(.headline, design: .rounded).weight(.bold))
                    .lineLimit(1)
                    .accessibilityIdentifier("coinTitle")
                Text(subtitle)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            contents
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
        .padding(.leading, 16)
        .padding(.trailing, onDelete == nil ? 16 : 6)
        .frame(height: CardMetrics.header)
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
        .foregroundStyle(.white.opacity(0.9))
    }

    /// The start of the note, else when it was pinned, else the date.
    private var subtitle: String {
        let firstLine = coin.notes.split(separator: "\n").first.map(String.init) ?? ""
        if !firstLine.isEmpty { return firstLine }
        if let pin = coin.pin { return pin.pinnedLabel }
        guard let ms = coin.updatedAt ?? coin.createdAt else { return "" }
        return Date(timeIntervalSince1970: ms / 1000).formatted(date: .abbreviated, time: .omitted)
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
                NoteFace(notes: coin.notes)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A coin with only words: its text, like a note card.
struct NoteFace: View {
    let notes: String

    /// A code or a few words shows big; longer notes get smaller type.
    private var font: Font {
        switch notes.count {
        case ..<25: return .system(size: 40, weight: .bold, design: .rounded)
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

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    LinearGradient(colors: [AccentPalette.color(accent), AccentPalette.deep(accent)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0)],
                                   startPoint: .top, endPoint: .center)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: CardMetrics.corner, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: CardMetrics.corner, style: .continuous)
                    .strokeBorder(.white.opacity(0.16), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.4), radius: 14, y: 8)
    }
}

extension View {
    func cardSurface(_ accent: Int) -> some View { modifier(CardSurface(accent: accent)) }
}
