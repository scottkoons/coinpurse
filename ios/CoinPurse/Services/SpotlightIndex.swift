@preconcurrency import CoreSpotlight
import UniformTypeIdentifiers

/// Your coins in iPhone Search: swipe down on the Home Screen, type
/// "parking", and the Parking spot coin is there. The index lives only on this
/// iPhone and is cleared when you sign out.
enum SpotlightIndex {
    private static let domain = "coins"

    /// Replaces the whole index with the purse as it is now.
    static func update(_ coins: [Coin]) {
        let items = coins.map { coin -> CSSearchableItem in
            let attributes = CSSearchableItemAttributeSet(contentType: .content)
            attributes.title = coin.title
            // Titles only, never notes (they can hold a gate code), just as
            // Apple Notes shows only the title of a locked note.
            var details: [String] = []
            if coin.pin != nil { details.append("Map pin") }
            if !coin.pictures.isEmpty { details.append(coin.pictures.count == 1 ? "1 picture" : "\(coin.pictures.count) pictures") }
            attributes.contentDescription = details.joined(separator: " · ")
            attributes.keywords = ["Coin Purse", "coin"]
            return CSSearchableItem(uniqueIdentifier: coin.id, domainIdentifier: domain, attributeSet: attributes)
        }
        // Async calls, not completion handlers: those arrive on a background
        // thread, which this main-thread code must never run on.
        Task {
            let index = CSSearchableIndex.default()
            try? await index.deleteSearchableItems(withDomainIdentifiers: [domain])
            try? await index.indexSearchableItems(items)
        }
    }

    static func clear() {
        Task { try? await CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domain]) }
    }
}
