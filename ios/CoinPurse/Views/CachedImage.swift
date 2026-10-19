import SwiftUI

/// Shows a coin picture, read from its file on this iPhone.
struct CachedImage: View {
    @Environment(AppModel.self) private var model
    let picture: Picture?
    var contentMode: ContentMode = .fit

    @State private var image: UIImage?
    @State private var failed = false

    init(picture: Picture?, contentMode: ContentMode = .fit) {
        self.picture = picture
        self.contentMode = contentMode
        _image = State(initialValue: picture.flatMap { ImageCache.shared.inMemory($0.key) })
    }

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
        if let hit = ImageCache.shared.inMemory(picture.key) {
            image = hit
            return
        }
        image = nil
        guard let url = model.url(for: picture) else { failed = true; return }
        image = await ImageCache.shared.image(key: picture.key, url: url)
        failed = image == nil
    }
}
