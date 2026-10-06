import SwiftUI

/// Full-screen coin: swipe between pictures, pinch to zoom, share one picture.
struct ViewerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let coinId: String

    @State private var index: Int

    init(coinId: String, startIndex: Int = 0) {
        self.coinId = coinId
        _index = State(initialValue: startIndex)
    }
    @State private var images: [String: UIImage] = [:]
    @State private var share: ShareImage?
    @State private var editing = false
    @State private var adding = false
    @State private var cropping: CropRequest?
    @State private var confirmDeleteCoin = false
    @State private var confirmRemovePicture = false
    @State private var busy = false

    private var coin: Coin? { model.coin(coinId) }
    private var pictures: [Picture] { coin?.pictures ?? [] }
    private var current: Picture? { pictures.indices.contains(index) ? pictures[index] : nil }
    private var notes: String { coin?.notes.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if pictures.isEmpty, !notes.isEmpty {
                // A text coin (like a voice note): the words, big and easy to read.
                ScrollView {
                    Text(LinkedText.make(notes))
                        .font(.title2.weight(.medium))
                        .lineSpacing(6)
                        .foregroundStyle(.white)
                        .tint(Color.accentColor)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(24)
                        .accessibilityIdentifier("noteText")
                }
            } else if pictures.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary)
                    Text("No picture yet").foregroundStyle(.secondary)
                    Button("Add a picture") { adding = true }
                }
            } else {
                TabView(selection: $index) {
                    ForEach(Array(pictures.enumerated()), id: \.element.key) { i, picture in
                        Group {
                            if let img = images[picture.key] {
                                ZoomableImage(image: img) { dismiss() }
                            } else {
                                ProgressView().tint(.white)
                            }
                        }
                        .tag(i)
                        .task(id: picture.key) { await load(picture) }
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .ignoresSafeArea()
            }
            if busy {
                ProgressView().tint(.white).scaleEffect(1.4)
            }
        }
        .safeAreaInset(edge: .top) { topBar }
        .safeAreaInset(edge: .bottom) { bottomBar }
        .onChange(of: pictures.count) { _, count in
            if index >= count { index = max(0, count - 1) }
        }
        .onChange(of: coin == nil) { _, gone in if gone { dismiss() } }
        .sheet(item: $share) { item in
            ShareSheet(image: item.image).presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $editing) { EditorView(coinId: coinId) }
        .sheet(isPresented: $adding) {
            AddPictureSheet { data in
                adding = false
                Task {
                    busy = true
                    await model.addPicture(to: coinId, jpeg: data)
                    busy = false
                    index = max(0, pictures.count - 1)
                }
            }
            .presentationDetents([.height(260)])
        }
        .fullScreenCover(item: $cropping) { request in
            CropView(image: request.image) { result in
                cropping = nil
                guard let result, let data = ImageProcessing.uploadData(from: result) else { return }
                Task { await replace(request.picture, with: data) }
            }
        }
        .alert("Are you sure you want to delete?", isPresented: $confirmDeleteCoin) {
            Button("Delete", role: .destructive) {
                dismiss()
                Task { await model.deleteCoin(coinId) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This coin and all of its pictures will be deleted. This cannot be undone.")
        }
        .alert("Remove this picture?", isPresented: $confirmRemovePicture) {
            Button("Remove", role: .destructive) {
                guard let current else { return }
                Task { await model.deletePicture(current, of: coinId) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .preferredColorScheme(.dark)
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left").font(.title3.weight(.semibold)).frame(width: 44, height: 44)
            }
            .accessibilityLabel("Back")
            Spacer()
            VStack(spacing: 2) {
                Text(coin?.title ?? "").font(.headline).lineLimit(1)
                if pictures.count > 1 {
                    Text("\(index + 1) of \(pictures.count)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Menu {
                Button { editing = true } label: { Label("Edit", systemImage: "pencil") }
                Button(role: .destructive) { confirmDeleteCoin = true } label: { Label("Delete coin", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis.circle").font(.title3).frame(width: 44, height: 44)
            }
            .accessibilityLabel("More")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .background(.black.opacity(0.35))
        .safeAreaInset(edge: .bottom, spacing: 0) { notesView }
    }

    /// The coin's notes, with web links, email addresses and phone numbers tappable.
    @ViewBuilder private var notesView: some View {
        // A text coin shows its words full size instead.
        if !notes.isEmpty, !pictures.isEmpty {
            ScrollView {
                Text(LinkedText.make(notes))
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.9))
                    .tint(Color.accentColor)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
            .frame(maxHeight: 96)
            .fixedSize(horizontal: false, vertical: true)
            .background(.black.opacity(0.35))
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            thumbnails
            if pictures.isEmpty {
                // No picture yet: share the words, or edit them.
                HStack {
                    ShareLink(item: notes) {
                        VStack(spacing: 4) {
                            Image(systemName: "square.and.arrow.up").font(.title3)
                            Text("Share").font(.caption2)
                        }
                        .frame(minWidth: 60, minHeight: 44)
                    }
                    .foregroundStyle(.white)
                    .disabled(notes.isEmpty)
                    Spacer()
                    barButton("Edit", "pencil") { editing = true }
                }
                .padding(.horizontal, 28)
            } else {
            HStack {
                barButton("Share", "square.and.arrow.up") { Task { await shareCurrent() } }
                    .disabled(current == nil)
                Spacer()
                barButton("Crop", "crop.rotate") { Task { await cropCurrent() } }
                    .disabled(current == nil)
                Spacer()
                barButton("Remove", "minus.circle") { confirmRemovePicture = true }
                    .disabled(current?.isPrimary ?? true)
                    .opacity(current?.isPrimary ?? true ? 0.35 : 1)
            }
            .padding(.horizontal, 28)
            }
        }
        .padding(.vertical, 10)
        .background(.black.opacity(0.35))
    }

    private var thumbnails: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(pictures.enumerated()), id: \.element.key) { i, picture in
                    CachedImage(picture: picture, contentMode: .fill)
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(i == index ? Color.white : Color.clear, lineWidth: 2)
                        )
                        .onTapGesture { withAnimation { index = i } }
                }
                if pictures.count < Config.maxExtraPictures + 1 {
                    Button { adding = true } label: {
                        Image(systemName: "plus")
                            .font(.title3)
                            .frame(width: 48, height: 48)
                            .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .accessibilityLabel("Add picture")
                }
            }
            .padding(.horizontal, 16)
        }
        .foregroundStyle(.white)
    }

    private func barButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.title3)
                Text(title).font(.caption2)
            }
            .frame(minWidth: 60, minHeight: 44)
        }
        .foregroundStyle(.white)
        .accessibilityIdentifier("viewer" + title)
    }

    // MARK: Actions

    private func load(_ picture: Picture) async {
        if images[picture.key] != nil { return }
        guard let url = model.url(for: picture) else { return }
        if let img = await ImageCache.shared.image(key: picture.key, url: url) {
            images[picture.key] = img
        }
    }

    private func currentImage() async -> UIImage? {
        guard let current else { return nil }
        await load(current)
        return images[current.key]
    }

    private func shareCurrent() async {
        if let img = await currentImage() { share = ShareImage(image: img) }
    }

    private func cropCurrent() async {
        guard let current, let img = await currentImage() else { return }
        cropping = CropRequest(picture: current, image: img)
    }

    private func replace(_ picture: Picture, with data: Data) async {
        busy = true
        defer { busy = false }
        do {
            try await model.replacePicture(picture, of: coinId, jpeg: data)
        } catch {
            model.show(error.localizedDescription)
        }
    }
}

struct CropRequest: Identifiable {
    let id = UUID()
    let picture: Picture
    let image: UIImage
}
