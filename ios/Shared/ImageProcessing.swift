import UIKit

nonisolated enum ImageProcessing {
    /// Upright, at most 1200 px wide, JPEG: the same as the web app uploads.
    static func uploadData(from image: UIImage) -> Data? {
        let upright = normalized(image)
        let width = upright.size.width * upright.scale
        let height = upright.size.height * upright.scale
        let scale = min(1, Config.maxImageWidth / max(width, 1))
        let target = CGSize(width: (width * scale).rounded(), height: (height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            upright.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: Config.jpegQuality)
    }

    static func normalized(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    /// Rotate a quarter turn. clockwise = true turns right.
    static func rotated(_ image: UIImage, clockwise: Bool) -> UIImage {
        let src = normalized(image)
        let size = CGSize(width: src.size.height, height: src.size.width)
        let format = UIGraphicsImageRendererFormat()
        format.scale = src.scale
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let c = ctx.cgContext
            c.translateBy(x: size.width / 2, y: size.height / 2)
            c.rotate(by: clockwise ? .pi / 2 : -.pi / 2)
            src.draw(in: CGRect(x: -src.size.width / 2, y: -src.size.height / 2,
                                width: src.size.width, height: src.size.height))
        }
    }

    /// Crop to a rectangle given in the image's own points (upright).
    static func cropped(_ image: UIImage, to rect: CGRect) -> UIImage {
        let src = normalized(image)
        let bounds = CGRect(origin: .zero, size: src.size)
        let r = rect.intersection(bounds)
        guard !r.isEmpty else { return src }
        let format = UIGraphicsImageRendererFormat()
        format.scale = src.scale
        return UIGraphicsImageRenderer(size: r.size, format: format).image { _ in
            src.draw(at: CGPoint(x: -r.origin.x, y: -r.origin.y))
        }
    }
}
