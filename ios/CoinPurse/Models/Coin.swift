import SwiftUI

struct Attachment: Codable, Hashable, Identifiable {
    let id: String
    var imageUrl: String?
    var imagePath: String?
}

struct Coin: Codable, Hashable, Identifiable {
    let id: String
    var title: String
    var notes: String
    var accent: Int
    var imageUrl: String?
    var imagePath: String?
    var attachments: [Attachment]
    var sortOrder: Double?
    var createdAt: Double?
    var updatedAt: Double?

    enum CodingKeys: String, CodingKey {
        case id, title, notes, accent, imageUrl, imagePath, attachments, sortOrder, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        notes = (try? c.decode(String.self, forKey: .notes)) ?? ""
        accent = (try? c.decode(Int.self, forKey: .accent)) ?? 0
        imageUrl = try? c.decode(String.self, forKey: .imageUrl)
        imagePath = try? c.decode(String.self, forKey: .imagePath)
        attachments = (try? c.decode([Attachment].self, forKey: .attachments)) ?? []
        sortOrder = try? c.decode(Double.self, forKey: .sortOrder)
        createdAt = try? c.decode(Double.self, forKey: .createdAt)
        updatedAt = try? c.decode(Double.self, forKey: .updatedAt)
    }

    /// Main picture first, then the extras, as the viewer shows them.
    var pictures: [Picture] {
        var list: [Picture] = []
        if let url = imageUrl { list.append(Picture(id: "primary", url: url, key: imagePath ?? url, attachmentId: nil)) }
        for a in attachments {
            if let url = a.imageUrl { list.append(Picture(id: a.id, url: url, key: a.imagePath ?? url, attachmentId: a.id)) }
        }
        return list
    }

    var accentColor: Color { AccentPalette.color(accent) }
}

/// One picture on a coin. `key` is stable across signed-link refreshes, so it
/// is what the image cache uses.
struct Picture: Hashable, Identifiable {
    let id: String
    let url: String
    let key: String
    let attachmentId: String?
    var isPrimary: Bool { attachmentId == nil }
}

/// The same six accent colors as the web app.
enum AccentPalette {
    static let hex: [UInt32] = [0x6366F1, 0x06B6D4, 0x22C55E, 0xEAB308, 0xF97316, 0xEC4899]

    static func color(_ index: Int) -> Color {
        let v = hex[(index % hex.count + hex.count) % hex.count]
        return Color(
            red: Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255
        )
    }
}
