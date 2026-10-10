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
    let onPicked: (Data) -> Void

    @Environment(AppModel.self) private var model
    @State private var photoItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var showFiles = false
    @State private var loading = false

    private static var hasCamera: Bool {
        #if DEBUG
        // UI tests show the button in the Simulator to check the layout.
        if ProcessInfo.processInfo.arguments.contains("-uiTestShowCamera") { return true }
        #endif
        return UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    // Apple's secure Paste control: one tap, no "Allow Paste" prompt.
    // iOS dims it by itself until the clipboard holds a picture.
    private var paste: some View {
        PasteButton(supportedContentTypes: [.image]) { providers in
            Task { await deliver(await PictureLoader.data(from: providers)) }
        }
        .labelStyle(.titleAndIcon)
        .buttonBorderShape(.capsule)
        .tint(.accentColor)
    }

    @ViewBuilder private var others: some View {
        Group {
            PhotosPicker(selection: $photoItem, matching: .images) {
                Label("Photos", systemImage: "photo.on.rectangle")
                    .lineLimit(1)
            }
            if Self.hasCamera {
                Button { showCamera = true } label: {
                    Label("Camera", systemImage: "camera")
                        .lineLimit(1)
                }
            }
            // A PDF or picture from Files: iCloud Drive (where a Mac can put it),
            // or Downloads (where AirDrop leaves it).
            Button {
                #if DEBUG
                // UI tests: a ready-made two-page PDF instead of the Files screen.
                if ProcessInfo.processInfo.arguments.contains("-uiTestFileSample") {
                    Task { await deliverFiles([Self.samplePDF()]) }
                    return
                }
                #endif
                showFiles = true
            } label: {
                Label("Files", systemImage: "folder")
                    .lineLimit(1)
            }
            .accessibilityIdentifier("pickFile")
        }
        // Same compact pill shape as Paste, which iOS sizes itself.
        .labelStyle(.titleAndIcon)
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .fixedSize()
    }

    var body: some View {
        VStack(spacing: 10) {
            // All four on one line; on a small iPhone or with large text they wrap.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    paste
                    others
                }
                .font(.subheadline.weight(.semibold))
                VStack(spacing: 10) {
                    paste
                    HStack(spacing: 10) { others }
                }
                // The largest text sizes: one button per line.
                VStack(spacing: 10) {
                    paste
                    others
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
            CameraPicker { image in
                showCamera = false
                guard let image else { return }
                Task { await deliver(await PictureLoader.prepare(image)) }
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
                onPicked(page)
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
        onPicked(data)
    }
}

/// Sheet used by the viewer's "+" button.
struct AddPictureSheet: View {
    var room = Config.maxExtraPictures + 1
    let onPicked: (Data) -> Void

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

struct CameraPicker: UIViewControllerRepresentable {
    let onDone: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onDone: onDone) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onDone: (UIImage?) -> Void
        init(onDone: @escaping (UIImage?) -> Void) { self.onDone = onDone }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onDone(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onDone(nil)
        }
    }
}
