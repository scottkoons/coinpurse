import Foundation

/// Turns plain text into an AttributedString whose web links, email
/// addresses and phone numbers are tappable (on the phone, no service).
nonisolated enum LinkedText {
    private static let detector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue | NSTextCheckingResult.CheckingType.phoneNumber.rawValue
    )

    static func make(_ text: String) -> AttributedString {
        var out = AttributedString(text)
        guard let detector else { return out }
        let ns = text as NSString
        for match in detector.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let swiftRange = Range(match.range, in: text),
                  let range = Range(swiftRange, in: out) else { continue }
            if let url = match.url {
                out[range].link = url
            } else if let phone = match.phoneNumber {
                let digits = phone.filter { $0.isNumber || $0 == "+" }
                if let url = URL(string: "tel:\(digits)") { out[range].link = url }
            }
            out[range].underlineStyle = .single
        }
        return out
    }
}
