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
        enqueue {
            let index = CSSearchableIndex.default()
            try? await index.deleteSearchableItems(withDomainIdentifiers: [domain])
            try? await index.indexSearchableItems(items)
        }
    }

    static func clear() {
        enqueue { try? await CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domain]) }
    }

    /// Changes to the index run one after another, in the order they were
    /// asked for, so a clear on sign out always comes after (and wins over) an
    /// update that was still going.
    private static var last: Task<Void, Never>?

    // Async calls, not completion handlers: those arrive on a background
    // thread, which this main-thread code must never run on.
    private static func enqueue(_ work: @escaping () async -> Void) {
        let previous = last
        last = Task {
            await previous?.value
            await work()
        }
    }
}
