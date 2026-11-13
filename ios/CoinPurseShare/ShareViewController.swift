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
                guard room > 0 else { continue }
                var pages = await fromFile(provider, type: .pdf) { ImageProcessing.pdfPages(fileAt: $0, limit: room) } ?? []
                if pages.isEmpty, let data = await data(provider, type: .pdf) {
                    pages = await Task.detached(priority: .userInitiated, operation: {
                        ImageProcessing.pdfPages(data, limit: room)
                    }).value
                }
                for jpeg in pages {
                    guard let preview = UIImage(data: jpeg) else { continue }
                    input.images.append(jpeg)
                    input.previews.append(preview)
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                guard input.images.count < Config.maxExtraPictures + 1 else { continue }
                // Shrunk straight from its file, off the main thread, one picture at
                // a time: a 48 MP photo loaded whole could take more memory than iOS
                // allows a Share extension. Some apps share only the bytes.
                var jpeg = await fromFile(provider, type: .image) { ImageProcessing.uploadData(fromFileAt: $0) } ?? nil
                if jpeg == nil, let data = await data(provider, type: .image) {
                    jpeg = await Task.detached(priority: .userInitiated, operation: {
                        ImageProcessing.uploadData(fromFile: data)
                    }).value
                }
                guard let jpeg, let preview = UIImage(data: jpeg) else { continue }
                input.images.append(jpeg)
                input.previews.append(preview)
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                      let url = await url(provider) {
                texts.append(url.absoluteString)
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                      let data = await data(provider, type: .plainText),
                      let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) {
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

    /// Reads the shared file where it is: `read` runs on a background thread
    /// while the file is there (iOS removes it afterwards). Nil when there is
    /// no file to read.
    private static func fromFile<T: Sendable>(_ provider: NSItemProvider, type: UTType,
                                              _ read: @escaping @Sendable (URL) -> T) async -> T? {
        await withCheckedContinuation { (done: CheckedContinuation<T?, Never>) in
            _ = provider.loadFileRepresentation(for: type, openInPlace: false) { @Sendable url, _, _ in
                done.resume(returning: url.map(read))
            }
        }
    }

    private static func url(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { (done: CheckedContinuation<URL?, Never>) in
            _ = provider.loadObject(ofClass: URL.self) { @Sendable url, _ in done.resume(returning: url) }
        }
    }
}
