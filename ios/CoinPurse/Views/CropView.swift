import SwiftUI

/// Crop with corner handles and rotate in quarter turns. Returns the edited
/// picture, or nil when cancelled.
struct CropView: View {
    let onDone: (UIImage?) -> Void

    @State private var image: UIImage
    /// Crop box as fractions of the picture (0...1), so it survives layout changes.
    @State private var box = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var dragStart: CGRect?

    private let minBox: CGFloat = 0.08

    init(image: UIImage, onDone: @escaping (UIImage?) -> Void) {
        _image = State(initialValue: ImageProcessing.normalized(image))
        self.onDone = onDone
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") { onDone(nil) }
                Spacer()
                Button("Reset") { withAnimation { box = CGRect(x: 0, y: 0, width: 1, height: 1) } }
                Spacer()
                Button("Done") { onDone(result()) }.bold().accessibilityIdentifier("cropDone")
            }
            .padding()
            GeometryReader { geo in
                let frame = fitRect(for: image.size, in: geo.size.insetBy(24))
                ZStack(alignment: .topLeading) {
                    Image(uiImage: image)
                        .resizable()
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                    cropOverlay(frame: frame)
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            }
            HStack(spacing: 48) {
                Button { rotate(clockwise: false) } label: {
                    Label("Rotate left", systemImage: "rotate.left").labelStyle(.iconOnly).font(.title2)
                }
                Button { rotate(clockwise: true) } label: {
                    Label("Rotate right", systemImage: "rotate.right").labelStyle(.iconOnly).font(.title2)
                }
            }
            .padding(.vertical, 20)
        }
        .foregroundStyle(.white)
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    // MARK: Overlay

    private func cropOverlay(frame: CGRect) -> some View {
        let r = CGRect(
            x: frame.minX + box.minX * frame.width,
            y: frame.minY + box.minY * frame.height,
            width: box.width * frame.width,
            height: box.height * frame.height
        )
        return ZStack(alignment: .topLeading) {
            // Dim everything outside the box.
            Path { p in
                p.addRect(frame)
                p.addRect(r)
            }
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            Rectangle()
                .strokeBorder(Color.white, lineWidth: 2)
                .frame(width: r.width, height: r.height)
                .contentShape(Rectangle())
                .offset(x: r.minX, y: r.minY)
                .gesture(moveGesture(frame: frame))

            ForEach(Corner.allCases, id: \.self) { corner in
                let p = corner.point(in: r)
                Circle()
                    .fill(Color.white)
                    .frame(width: 22, height: 22)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .offset(x: p.x - 22, y: p.y - 22)
                    .gesture(resizeGesture(corner, frame: frame))
            }
        }
    }

    enum Corner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
        func point(in r: CGRect) -> CGPoint {
            switch self {
            case .topLeft: return CGPoint(x: r.minX, y: r.minY)
            case .topRight: return CGPoint(x: r.maxX, y: r.minY)
            case .bottomLeft: return CGPoint(x: r.minX, y: r.maxY)
            case .bottomRight: return CGPoint(x: r.maxX, y: r.maxY)
            }
        }
    }

    private func moveGesture(frame: CGRect) -> some Gesture {
        DragGesture(coordinateSpace: .global)
            .onChanged { v in
                let start = dragStart ?? box
                dragStart = start
                var x = start.minX + v.translation.width / frame.width
                var y = start.minY + v.translation.height / frame.height
                x = min(max(0, x), 1 - start.width)
                y = min(max(0, y), 1 - start.height)
                box = CGRect(x: x, y: y, width: start.width, height: start.height)
            }
            .onEnded { _ in dragStart = nil }
    }

    private func resizeGesture(_ corner: Corner, frame: CGRect) -> some Gesture {
        DragGesture(coordinateSpace: .global)
            .onChanged { v in
                let s = dragStart ?? box
                dragStart = s
                let dx = v.translation.width / frame.width
                let dy = v.translation.height / frame.height
                var minX = s.minX, minY = s.minY, maxX = s.maxX, maxY = s.maxY
                switch corner {
                case .topLeft: minX += dx; minY += dy
                case .topRight: maxX += dx; minY += dy
                case .bottomLeft: minX += dx; maxY += dy
                case .bottomRight: maxX += dx; maxY += dy
                }
                minX = min(max(0, minX), maxX - minBox)
                minY = min(max(0, minY), maxY - minBox)
                maxX = max(min(1, maxX), minX + minBox)
                maxY = max(min(1, maxY), minY + minBox)
                box = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            }
            .onEnded { _ in dragStart = nil }
    }

    // MARK: Actions

    private func rotate(clockwise: Bool) {
        image = ImageProcessing.rotated(image, clockwise: clockwise)
        // Turn the crop box with the picture.
        let b = box
        box = clockwise
            ? CGRect(x: 1 - b.maxY, y: b.minX, width: b.height, height: b.width)
            : CGRect(x: b.minY, y: 1 - b.maxX, width: b.height, height: b.width)
    }

    private func result() -> UIImage {
        let size = image.size
        let rect = CGRect(x: box.minX * size.width, y: box.minY * size.height,
                          width: box.width * size.width, height: box.height * size.height)
        if box == CGRect(x: 0, y: 0, width: 1, height: 1) { return image }
        return ImageProcessing.cropped(image, to: rect)
    }

    private func fitRect(for imageSize: CGSize, in area: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = min(area.width / imageSize.width, area.height / imageSize.height)
        let w = imageSize.width * scale, h = imageSize.height * scale
        return CGRect(x: 24 + (area.width - w) / 2, y: 24 + (area.height - h) / 2, width: w, height: h)
    }
}

private extension CGSize {
    func insetBy(_ d: CGFloat) -> CGSize { CGSize(width: max(0, width - 2 * d), height: max(0, height - 2 * d)) }
}
