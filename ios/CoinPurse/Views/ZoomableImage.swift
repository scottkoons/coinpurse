import SwiftUI
import UIKit
import VisionKit

/// Pinch to zoom, double-tap to zoom in or out, pan while zoomed.
/// A single tap on the empty space around the picture calls `onTapOutside`.
struct ZoomableImage: UIViewRepresentable {
    let image: UIImage
    var onTapOutside: () -> Void = {}

    func makeUIView(context: Context) -> ZoomScrollView {
        ZoomScrollView()
    }

    func updateUIView(_ view: ZoomScrollView, context: Context) {
        view.onTapOutside = onTapOutside
        view.display(image)
    }
}

final class ZoomScrollView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()
    private var shown: UIImage?
    var onTapOutside: () -> Void = {}

    /// Apple's Live Text, on the phone and free: links, email addresses,
    /// phone numbers and QR codes in the picture become tappable, and any
    /// text can be selected and copied.
    private let liveText = ImageAnalysisInteraction()
    private static let analyzer = ImageAnalyzer()
    private var analysisTask: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 5
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        decelerationRate = .fast
        contentInsetAdjustmentBehavior = .never
        backgroundColor = .clear
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        addSubview(imageView)
        if ImageAnalyzer.isSupported {
            liveText.preferredInteractionTypes = .automatic
            // Keep the Live Text button clear of the viewer's bottom bar.
            liveText.supplementaryInterfaceContentInsets = UIEdgeInsets(top: 0, left: 0, bottom: 170, right: 12)
            imageView.addInteraction(liveText)
        }
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(singleTapped(_:)))
        singleTap.require(toFail: doubleTap)
        addGestureRecognizer(singleTap)
    }

    /// Where the picture actually shows inside the image view (aspect fit).
    private var pictureFrame: CGRect {
        guard let size = imageView.image?.size, size.width > 0, size.height > 0 else { return .zero }
        let box = imageView.bounds
        let scale = min(box.width / size.width, box.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return CGRect(x: (box.width - w) / 2, y: (box.height - h) / 2, width: w, height: h)
    }

    @objc private func singleTapped(_ g: UITapGestureRecognizer) {
        // Only when not zoomed: a tap on the black space closes the coin.
        guard zoomScale <= 1.01, !pictureFrame.contains(g.location(in: imageView)) else { return }
        onTapOutside()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func display(_ image: UIImage) {
        guard image !== shown else { return }
        shown = image
        imageView.image = image
        zoomScale = 1
        setNeedsLayout()
        analyze(image)
    }

    private func analyze(_ image: UIImage) {
        guard ImageAnalyzer.isSupported else { return }
        analysisTask?.cancel()
        liveText.analysis = nil
        analysisTask = Task { [weak self] in
            let config = ImageAnalyzer.Configuration([.text, .machineReadableCode])
            guard let analysis = try? await Self.analyzer.analyze(image, configuration: config),
                  !Task.isCancelled, let self, self.shown === image else { return }
            self.liveText.analysis = analysis
            self.liveText.preferredInteractionTypes = .automatic
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if zoomScale == 1 {
            imageView.frame = CGRect(origin: .zero, size: bounds.size)
            contentSize = bounds.size
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    @objc private func doubleTapped(_ g: UITapGestureRecognizer) {
        if zoomScale > 1 {
            setZoomScale(1, animated: true)
        } else {
            let p = g.location(in: imageView)
            let scale: CGFloat = 2.5
            let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
            zoom(to: CGRect(x: p.x - size.width / 2, y: p.y - size.height / 2, width: size.width, height: size.height), animated: true)
        }
    }
}

/// Presents the iOS share sheet for one picture (no text).
struct ShareSheet: UIViewControllerRepresentable {
    let image: UIImage

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [image], applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

struct ShareImage: Identifiable {
    let id = UUID()
    let image: UIImage
}
