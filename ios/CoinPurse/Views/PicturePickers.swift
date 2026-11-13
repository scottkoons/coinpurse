import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Turns whatever the user pasted or picked into upload-ready JPEG data.
enum PictureLoader {
    static func data(from providers: [NSItemProvider]) async -> Data? {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: UIImage.self) }) else { return nil }
        let image: UIImage? = await withCheckedContinuation { cont in
            _ = provider.loadObject(ofClass: UIImage.self) { @Sendable object, _ in
                cont.resume(returning: object as? UIImage)
            }
        }
        guard let image else { return nil }
        return await prepare(image)
    }

    static func data(from item: PhotosPickerItem) async -> Data? {
        guard let raw = try? await item.loadTransferable(type: Data.self) else { return nil }
        // Straight from the file's bytes, never decoding the full 12 to 48 MP photo.
        return await Task.detached(priority: .userInitiated) {
            ImageProcessing.uploadData(fromFile: raw)
        }.value
    }

    static func prepare(_ image: UIImage) async -> Data? {
        await Task.detached(priority: .userInitiated) {
            ImageProcessing.uploadData(from: image)
        }.value
    }
}

/// Camera, Paste, Photos and Files as round buttons in a row, like the buttons
/// under an open coin. Paste is Apple's secure paste control, so there is no
/// "Allow Paste" prompt.
struct PictureSourceButtons: View {
    /// How many more pictures fit (a PDF gives one per page, up to this).
    var room = Config.maxExtraPictures + 1
    /// A picture as upload-ready JPEG; for a video from the camera, a still
    /// from it and the video's file.
    let onPicked: (Data, URL?) -> Void

    @Environment(AppModel.self) private var model
    @State private var photoItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var showFiles = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var loading = false

    private static var hasCamera: Bool {
        #if DEBUG
        // UI tests show the button in the Simulator to check the layout.
        if ProcessInfo.processInfo.arguments.contains("-uiTestShowCamera") { return true }
        #endif
        return UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    /// A round button with its name under it (beside it at the largest text
    /// sizes, where the circle is 44 points instead of 52). Nonisolated: the
    /// Photos picker builds its label off the main actor.
    private nonisolated static func source<Round: View>(_ title: String, large: Bool,
                                                         @ViewBuilder _ round: () -> Round) -> some View {
        let layout = large ? AnyLayout(HStackLayout(spacing: 14)) : AnyLayout(VStackLayout(spacing: 6))
        let circle: CGFloat = large ? 44 : 52
        return layout {
            round()
                // The circle keeps its size at every text size, so its symbol
                // does too (larger, it would spill out of the circle).
                .dynamicTypeSize(...DynamicTypeSize.large)
                .frame(width: circle, height: circle)
            Text(title)
                .font(large ? .body.weight(.semibold) : .caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                // Each button already says its name.
                .accessibilityHidden(true)
            if large { Spacer(minLength: 0) }
        }
        .frame(maxWidth: .infinity)
        // The whole column takes the tap, not just the circle.
        .contentShape(Rectangle())
    }

    /// A symbol in a circle: gray, or dark for the camera (like New Coin).
    private nonisolated static func icon(_ name: String, dark: Bool = false) -> some View {
        Image(systemName: name)
            .font(.title3.weight(.medium))
            .foregroundStyle(dark ? Color(.systemBackground) : Color.primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(dark ? Color.primary : Color(uiColor: .sourceFill), in: Circle())
            .accessibilityHidden(true)
    }

    // Apple's secure Paste control: one tap, no "Allow Paste" prompt. It is a
    // round UIKit button, the name under it like the others (iOS dims it until
    // the clipboard holds a picture).
    private var paste: some View {
        Self.source("Paste", large: typeSize.isAccessibilitySize) {
            PasteCircle { providers in
                Task { await deliver(await PictureLoader.data(from: providers)) }
            }
            .clipShape(Circle())
        }
    }

    /// The camera: first and dark, like New Coin in the purse.
    private var camera: some View {
        Button { showCamera = true } label: { Self.source("Camera", large: typeSize.isAccessibilitySize) { Self.icon("camera.fill", dark: true) } }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("Camera")
    }

    private var photos: some View {
        let large = typeSize.isAccessibilitySize
        return PhotosPicker(selection: $photoItem, matching: .images) {
            Self.source("Photos", large: large) { Self.icon("photo.on.rectangle") }
        }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("Photos")
    }

    // A PDF or picture from Files: iCloud Drive (where a Mac can put it),
    // or Downloads (where AirDrop leaves it).
    private var files: some View {
        Button {
            #if DEBUG
            // UI tests: a ready-made two-page PDF instead of the Files screen.
            if ProcessInfo.processInfo.arguments.contains("-uiTestFileSample") {
                Task { await deliverFiles([Self.samplePDF()]) }
                return
            }
            #endif
            showFiles = true
        } label: { Self.source("Files", large: typeSize.isAccessibilitySize) { Self.icon("folder.fill") } }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("Files")
            .accessibilityIdentifier("pickFile")
    }

    var body: some View {
        VStack(spacing: 10) {
            // In a row, the camera first. At the largest text sizes, one per line.
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(alignment: .top, spacing: 0))
            layout {
                if Self.hasCamera { camera }
                paste
                photos
                files
            }

            if loading { ProgressView() }
        }
        .frame(maxWidth: .infinity)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            photoItem = nil
            Task { await deliver(await PictureLoader.data(from: item)) }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { shot in
                showCamera = false
                switch shot {
                case .photo(let image):
                    Task { await deliver(await PictureLoader.prepare(image)) }
                case .video(let url):
                    Task {
                        guard let still = await VideoClip.poster(for: url) else {
                            VideoClip.discard(url)
                            model.show("That video could not be read")
                            return
                        }
                        onPicked(still, url)
                    }
                case .unkept:
                    model.show(CameraShot.unkeptMessage)
                case nil:
                    break
                }
            }
            .ignoresSafeArea()
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.image, .pdf], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task { await deliverFiles(urls) }
        }
    }

    #if DEBUG
    private static func samplePDF() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Tickets.pdf")
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        try? UIGraphicsPDFRenderer(bounds: page).writePDF(to: url) { context in
            for n in 1...2 {
                context.beginPage()
                ("Ticket \(n)" as NSString).draw(at: CGPoint(x: 72, y: 340), withAttributes: [
                    .font: UIFont.boldSystemFont(ofSize: 64), .foregroundColor: UIColor.black,
                ])
            }
        }
        return url
    }
    #endif

    /// Pictures as they are; a PDF as one picture per page, as many as fit.
    private func deliverFiles(_ urls: [URL]) async {
        loading = true
        defer { loading = false }
        var added = 0
        var leftOut = false
        for url in urls {
            guard added < room else { leftOut = true; break }
            let limit = room - added
            let (pages, total): ([Data], Int) = await Task.detached(priority: .userInitiated) {
                // Files from iCloud Drive or another app are lent only while read.
                let lent = url.startAccessingSecurityScopedResource()
                defer { if lent { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else { return ([], 0) }
                if UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) == true {
                    return (ImageProcessing.pdfPages(data, limit: limit), ImageProcessing.pdfPageCount(data))
                }
                let picture = ImageProcessing.uploadData(fromFile: data).map { [$0] } ?? []
                return (picture, picture.count)
            }.value
            if pages.isEmpty {
                model.show("Could not read \(url.lastPathComponent)")
                continue
            }
            if total > limit { leftOut = true }
            for page in pages.prefix(limit) {
                onPicked(page, nil)
                added += 1
            }
        }
        if leftOut { model.show("A coin holds at most \(Config.maxExtraPictures + 1) pictures, so not every page was added") }
    }

    private func deliver(_ data: Data?) async {
        guard let data else {
            model.show("That is not a picture. Copy a screenshot or image first.")
            return
        }
        onPicked(data, nil)
    }
}

/// Sheet used by the "+" and Replace buttons in the editor and the viewer.
struct AddPictureSheet: View {
    var room = Config.maxExtraPictures + 1
    let onPicked: (Data, URL?) -> Void

    var body: some View {
        // Scrolls at the largest text sizes, where the tiles stack one per line.
        ScrollView {
            VStack(spacing: 16) {
                Text("Add picture").font(.headline)
                Text("Take one with the camera, or copy a screenshot or image and tap Paste.  Or choose one from your photos, or a picture or PDF from Files.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                PictureSourceButtons(room: room, onPicked: onPicked)
            }
            .padding(24)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

/// What the camera took: a photo, or a video (its file, ours to keep), or a
/// video that could not be kept.
enum CameraShot {
    case photo(UIImage)
    case video(URL)
    case unkept

    static let unkeptMessage = "The video could not be kept. Is the iPhone's storage full?"
}

/// The iPhone camera, with Photo and Video, as in the Camera app.
struct CameraPicker: UIViewControllerRepresentable {
    let onDone: (CameraShot?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        let offered = UIImagePickerController.availableMediaTypes(for: .camera) ?? []
        picker.mediaTypes = [UTType.image.identifier, UTType.movie.identifier].filter(offered.contains)
        picker.videoQuality = .typeHigh
        // Long enough for a quick look around, short enough to keep the phone's storage free.
        picker.videoMaximumDuration = 120
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onDone: onDone) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onDone: (CameraShot?) -> Void
        init(onDone: @escaping (CameraShot?) -> Void) { self.onDone = onDone }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let movie = info[.mediaURL] as? URL {
                onDone(VideoClip.keep(movie).map(CameraShot.video) ?? .unkept)
            } else {
                onDone((info[.originalImage] as? UIImage).map(CameraShot.photo))
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onDone(nil)
        }
    }
}

/// Apple's secure Paste control (UIPasteControl) as a big indigo tile: a paste
/// with one tap and no "Allow Paste" prompt, sized like the tiles beside it.
private struct PasteCircle: UIViewRepresentable {
    let onPaste: ([NSItemProvider]) -> Void

    func makeUIView(context: Context) -> UIPasteControl {
        let look = UIPasteControl.Configuration()
        look.displayMode = .iconOnly
        look.cornerStyle = .capsule
        // Opaque, like the other circles (iOS will not paste from a faint control).
        look.baseBackgroundColor = .sourceFill
        look.baseForegroundColor = .label
        let control = UIPasteControl(configuration: look)
        // Its circle keeps its size at every text size. A larger symbol would
        // not fit, and iOS neither draws nor runs a Paste control it cannot
        // show whole (Paste would do nothing at the largest text sizes).
        control.maximumContentSizeCategory = .large
        control.target = context.coordinator
        return control
    }

    func updateUIView(_ control: UIPasteControl, context: Context) {
        context.coordinator.onPaste = onPaste
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIPasteControl, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 52, height: proposal.height ?? 52)
    }

    func makeCoordinator() -> Coordinator { Coordinator(onPaste: onPaste) }

    final class Coordinator: UIResponder {
        var onPaste: ([NSItemProvider]) -> Void

        init(onPaste: @escaping ([NSItemProvider]) -> Void) {
            self.onPaste = onPaste
            super.init()
            pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: [UTType.image.identifier])
        }

        override func paste(itemProviders: [NSItemProvider]) {
            onPaste(itemProviders)
        }
    }
}


extension UIColor {
    /// The gray of the round picture buttons: opaque, and lighter than a form
    /// row in light mode, darker in dark mode.
    nonisolated static let sourceFill = UIColor { $0.userInterfaceStyle == .dark ? .systemGray4 : .systemGray5 }
}
