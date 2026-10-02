import SwiftUI

/// Shows a coin picture from the on-device cache, downloading it if needed.
struct CachedImage: View {
    @Environment(AppModel.self) private var model
    let picture: Picture?
    var contentMode: ContentMode = .fit

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if picture == nil || failed {
                Image(systemName: "photo")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: picture?.key) { await load() }
    }

    private func load() async {
        guard let picture else { image = nil; return }
        if let hit = await ImageCache.shared.cached(picture.key) {
            image = hit
            return
        }
        image = nil
        failed = false
        guard let url = model.url(for: picture) else { failed = true; return }
        image = await ImageCache.shared.image(key: picture.key, url: url)
        failed = image == nil
    }
}
