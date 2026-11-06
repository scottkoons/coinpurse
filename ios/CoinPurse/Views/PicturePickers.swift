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
        guard let raw = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: raw) else { return nil }
        return await prepare(image)
    }

    static func prepare(_ image: UIImage) async -> Data? {
        await Task.detached(priority: .userInitiated) {
            ImageProcessing.uploadData(from: image)
        }.value
    }
}

/// Paste, Photo Library, Camera and Files in one row. Paste uses Apple's
/// PasteButton, so there is no "Allow Paste" prompt.
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

    // Apple's secure Paste control: one tap, no "Allow Paste" prompt. The UIKit
    // one can be any size, so it is a tile like the others (iOS dims it until
    // the clipboard holds a picture).
    private var paste: some View {
        PasteTile { providers in
            Task { await deliver(await PictureLoader.data(from: providers)) }
        }
        .frame(maxWidth: .infinity, minHeight: 58, maxHeight: 58)
    }

    /// A big colored tile: easy to see, easy to hit.
    private nonisolated static func tile(_ title: String, _ icon: String, color: Int) -> some View {
        let colors = AccentPalette.cardColors(color)
        return Label(title, systemImage: icon)
            .labelStyle(.titleAndIcon)
            .font(.body.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 58)
            .padding(.horizontal, 8)
            .background(LinearGradient(colors: [colors.top, colors.bottom], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// The camera: first and teal, like the camera button in the purse.
    private var camera: some View {
        Button { showCamera = true } label: { Self.tile("Camera", "camera.fill", color: 1) }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("Camera")
    }

    private var photos: some View {
        PhotosPicker(selection: $photoItem, matching: .images) { Self.tile("Photos", "photo.on.rectangle", color: 2) }
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
        } label: { Self.tile("Files", "folder.fill", color: 4) }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("Files")
            .accessibilityIdentifier("pickFile")
    }

    var body: some View {
        VStack(spacing: 10) {
            // Two by two, the camera first: Camera and Paste, then Photos and Files.
            // At the largest text sizes, one per line.
            if typeSize.isAccessibilitySize {
                VStack(spacing: 10) {
                    if Self.hasCamera { camera }
                    paste
                    photos
                    files
                }
            } else {
                Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                    GridRow {
                        if Self.hasCamera { camera }
                        paste
                    }
                    GridRow {
                        photos
                        files
                    }
                }
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
                            model.show("That video could not be read")
                            return
                        }
                        onPicked(still, url)
                    }
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
            let pages: [Data] = await Task.detached(priority: .userInitiated) {
                // Files from iCloud Drive or another app are lent only while read.
                let lent = url.startAccessingSecurityScopedResource()
                defer { if lent { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else { return [] }
                if UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) == true {
                    return ImageProcessing.pdfPages(data, limit: limit + 1)
                }
                return ImageProcessing.uploadData(fromFile: data).map { [$0] } ?? []
            }.value
            if pages.isEmpty {
                model.show("Could not read \(url.lastPathComponent)")
                continue
            }
            if pages.count > limit { leftOut = true }
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

/// Sheet used by the viewer's "+" button.
struct AddPictureSheet: View {
    var room = Config.maxExtraPictures + 1
    let onPicked: (Data, URL?) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Add picture").font(.headline)
            Text("Copy a screenshot or image, then tap Paste.  Or choose one from your photos, or a picture or PDF from Files.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            PictureSourceButtons(room: room, onPicked: onPicked)
        }
        .padding(24)
    }
}

/// What the camera took: a photo, or a video (its file, ours to keep).
enum CameraShot {
    case photo(UIImage)
    case video(URL)
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
                onDone(VideoClip.keepCopy(of: movie).map(CameraShot.video))
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
private struct PasteTile: UIViewRepresentable {
    let onPaste: ([NSItemProvider]) -> Void

    func makeUIView(context: Context) -> UIPasteControl {
        let look = UIPasteControl.Configuration()
        look.displayMode = .iconAndLabel
        look.cornerStyle = .fixed
        look.cornerRadius = 16
        look.baseBackgroundColor = UIColor(AccentPalette.cardColors(0).top)
        look.baseForegroundColor = .white
        let control = UIPasteControl(configuration: look)
        control.target = context.coordinator
        return control
    }

    func updateUIView(_ control: UIPasteControl, context: Context) {
        context.coordinator.onPaste = onPaste
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIPasteControl, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 160, height: proposal.height ?? 58)
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

        override func canPaste(_ itemProviders: [NSItemProvider]) -> Bool { true }
    }
}
