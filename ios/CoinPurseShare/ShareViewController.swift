import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The Share extension: shows ShareView for whatever was shared.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        let screen = ShareView(
            load: { await ShareLoader.input(from: providers) },
            onDone: { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil) },
            onCancel: { [weak self] in
                self?.extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
            }
        )
        let host = UIHostingController(rootView: screen)
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }
}

/// Reads the shared items: pictures (and PDF pages) become upload-ready JPEGs;
/// a link or text becomes the note.
enum ShareLoader {
    static func input(from providers: [NSItemProvider]) async -> ShareInput {
        var input = ShareInput()
        var texts: [String] = []
        for provider in providers {
            let room = Config.maxExtraPictures + 1 - input.images.count
            if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
                // A PDF (a ticket, a boarding pass): one picture per page, as many as fit.
                guard room > 0, let data = await data(provider, type: .pdf) else { continue }
                let pages = await Task.detached(priority: .userInitiated, operation: {
                    ImageProcessing.pdfPages(data, limit: room)
                }).value
                for jpeg in pages {
                    guard let preview = UIImage(data: jpeg) else { continue }
                    input.images.append(jpeg)
                    input.previews.append(preview)
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                guard input.images.count < Config.maxExtraPictures + 1,
                      let data = await data(provider, type: .image) else { continue }
                // Shrunk off the main thread while reading, one picture at a time.
                guard let jpeg = await Task.detached(priority: .userInitiated, operation: {
                    ImageProcessing.uploadData(fromFile: data)
                }).value, let preview = UIImage(data: jpeg) else { continue }
                input.images.append(jpeg)
                input.previews.append(preview)
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                      let url = await url(provider) {
                texts.append(url.absoluteString)
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                      let data = await data(provider, type: .plainText),
                      let text = String(data: data, encoding: .utf8) {
                texts.append(text)
            }
        }
        let joined = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        input.text = joined.isEmpty ? nil : joined
        return input
    }

    private static func data(_ provider: NSItemProvider, type: UTType) async -> Data? {
        await withCheckedContinuation { (done: CheckedContinuation<Data?, Never>) in
            // @Sendable: iOS calls this on a background thread.
            _ = provider.loadDataRepresentation(for: type) { @Sendable data, _ in done.resume(returning: data) }
        }
    }

    private static func url(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { (done: CheckedContinuation<URL?, Never>) in
            _ = provider.loadObject(ofClass: URL.self) { @Sendable url, _ in done.resume(returning: url) }
        }
    }
}
