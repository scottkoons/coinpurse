import UIKit
import Vision

/// Turns the screen all the way up while a QR code or barcode is showing, like
/// Wallet does at a scanner, and puts it back afterwards.
final class ScanBrightness {
    private var original: CGFloat?

    private var screen: UIScreen? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .screen
    }

    func raise() {
        guard original == nil, let screen else { return }
        original = screen.brightness
        screen.brightness = 1
    }

    func restore() {
        guard let value = original, let screen else { original = nil; return }
        screen.brightness = value
        original = nil
    }
}

/// Whether a picture holds a QR code or barcode, found on the iPhone by Apple's Vision.
nonisolated enum CodeFinder {
    static func hasCode(_ image: UIImage) async -> Bool {
        guard let cgImage = image.cgImage else { return false }
        return await Task.detached(priority: .userInitiated) {
            let request = VNDetectBarcodesRequest()
            try? VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
            return !(request.results ?? []).isEmpty
        }.value
    }
}
