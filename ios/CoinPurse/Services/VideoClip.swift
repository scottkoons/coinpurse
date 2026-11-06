import AVFoundation
import UIKit

/// A video from the camera: a still from it (shown wherever a picture shows,
/// with a play button) and its file, kept until the coin is saved.
enum VideoClip {
    /// The camera removes its file soon after: taken over (moved, or copied if
    /// it cannot be moved) for as long as it is needed.
    nonisolated static func keep(_ url: URL) -> URL? {
        let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension
        let kept = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        if (try? FileManager.default.moveItem(at: url, to: kept)) != nil { return kept }
        return (try? FileManager.default.copyItem(at: url, to: kept)) != nil ? kept : nil
    }

    /// A video that will not be saved after all, removed (only a file of ours
    /// waiting in the temporary folder; a saved one has already moved away).
    nonisolated static func discard(_ url: URL?) {
        guard let url else { return }
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        guard url.resolvingSymlinksInPath().path.hasPrefix(temporary) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// A still from near the start, upright, saved like any picture.
    static func poster(for url: URL) async -> Data? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1600, height: 1600)
        guard let still = try? await generator.image(at: CMTime(seconds: 0.1, preferredTimescale: 600)) else { return nil }
        return await PictureLoader.prepare(UIImage(cgImage: still.image))
    }

    #if DEBUG
    /// UI tests (the simulator has no camera): a one-second teal video.
    static func sample() async -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return nil }
        let size = CGSize(width: 480, height: 640)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: size.width, AVVideoHeightKey: size.height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: size.width, kCVPixelBufferHeightKey as String: size.height,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let frame = UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            ("Video" as NSString).draw(at: CGPoint(x: 120, y: 280), withAttributes: [
                .font: UIFont.boldSystemFont(ofSize: 72), .foregroundColor: UIColor.white,
            ])
        }
        for n in 0..<30 {
            while !input.isReadyForMoreMediaData { try? await Task.sleep(for: .milliseconds(10)) }
            guard let pool = adaptor.pixelBufferPool else { return nil }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer, let cg = frame.cgImage else { return nil }
            CVPixelBufferLockBaseAddress(buffer, [])
            let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: Int(size.width), height: Int(size.height),
                                    bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
            context?.draw(cg, in: CGRect(origin: .zero, size: size))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(n), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        return writer.status == .completed ? url : nil
    }
    #endif
}
