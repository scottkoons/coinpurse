import Foundation

nonisolated enum Config {
    /// The website, for the privacy policy and support pages.
    static let website = URL(string: "https://coinpurse.yetignome.com")!

    static let maxExtraPictures = 5
    /// The longest title and notes a coin keeps, counted in UTF-16 units (so
    /// most emoji count as two).
    static let maxTitle = 200
    static let maxNotes = 5000
    /// Pictures are kept at most this wide.
    static let maxImageWidth: CGFloat = 1200
    static let jpegQuality: CGFloat = 0.82
}

nonisolated extension String {
    /// Length as a coin counts it (see Config.maxNotes).
    var textLength: Int { utf16.count }

    /// At most `limit` of those units, never cutting a character
    /// (an emoji or an accented letter) in half.
    func limited(to limit: Int) -> String {
        guard textLength > limit else { return self }
        var out = ""
        var used = 0
        for character in self {
            let size = String(character).utf16.count
            if used + size > limit { break }
            out.append(character)
            used += size
        }
        return out
    }
}
