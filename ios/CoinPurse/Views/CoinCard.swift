import SwiftUI

/// The title strip every card shows (a "peek" in the stack).
struct CoinCardHeader: View {
    let coin: Coin
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .topTrailing) {
                if coin.pictures.count > 1 {
                    // A second card edge behind the thumbnail says "more than one".
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.12))
                        .frame(width: 40, height: 40)
                        .offset(x: 4, y: -4)
                }
                Group {
                    if coin.pictures.isEmpty {
                        // A text coin: lines instead of a photo.
                        Image(systemName: "text.alignleft")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(coin.accentColor)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        CachedImage(picture: coin.pictures.first, contentMode: .fill)
                    }
                }
                    .frame(width: 40, height: 40)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                if coin.pictures.count > 1 {
                    Text("\(coin.pictures.count)")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(coin.accentColor, in: Circle())
                        .offset(x: 8, y: -8)
                        .accessibilityLabel("\(coin.pictures.count) pictures")
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(coin.title.isEmpty ? "Untitled" : coin.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete \(coin.title)")
        }
        .padding(.leading, 14)
        .padding(.trailing, 4)
        .frame(height: CardMetrics.peek)
    }

    private var subtitle: String {
        // A list coin says how many items instead of repeating the first one.
        if coin.pictures.isEmpty, VoiceCapture.isList(coin.notes) {
            let count = coin.notes.split(separator: "\n").count
            return count == 1 ? "1 item" : "\(count) items"
        }
        if let first = coin.notes.split(separator: "\n").first, !first.isEmpty { return String(first) }
        guard let ms = coin.updatedAt ?? coin.createdAt else { return "" }
        return Date(timeIntervalSince1970: ms / 1000).formatted(date: .abbreviated, time: .omitted)
    }
}

enum CardMetrics {
    static let peek: CGFloat = 64
    static let corner: CGFloat = 18
}

/// Card chrome: dark surface, accent stripe on top, soft shadow.
struct CardBackground: ViewModifier {
    let accent: Color
    func body(content: Content) -> some View {
        content
            .background(Color(red: 0.10, green: 0.10, blue: 0.13))
            .overlay(alignment: .top) {
                Rectangle().fill(accent).frame(height: 4)
            }
            .clipShape(RoundedRectangle(cornerRadius: CardMetrics.corner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CardMetrics.corner, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08))
            )
            .shadow(color: .black.opacity(0.5), radius: 14, y: 8)
    }
}

extension View {
    func cardBackground(_ accent: Color) -> some View { modifier(CardBackground(accent: accent)) }
}
