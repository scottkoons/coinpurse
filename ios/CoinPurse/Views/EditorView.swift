import SwiftUI

/// A picture chosen in the editor but not uploaded yet.
struct StagedPicture: Identifiable, Equatable {
    let id = UUID()
    var data: Data
    var image: UIImage
}

/// Add or edit a coin: title, notes, color, main picture and extras.
struct EditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// nil when adding a new coin.
    let coinId: String?

    @State private var draftId = UUID().uuidString.lowercased()
    @State private var title = ""
    @State private var notes = ""
    @State private var accent = 0
    @State private var stagedMain: StagedPicture?
    @State private var stagedExtras: [StagedPicture] = []
    @State private var addingExtra = false
    @State private var cropping: StagedCrop?
    @State private var removing: Picture?
    @State private var saving = false
    @State private var error: String?
    @State private var loaded = false
    @FocusState private var titleFocused: Bool

    private var id: String { coinId ?? draftId }
    private var existing: Coin? { model.coin(id) }
    private var existingExtras: [Picture] { existing?.pictures.filter { !$0.isPrimary } ?? [] }
    private var extrasCount: Int { existingExtras.count + stagedExtras.count }
    private var hasMain: Bool { stagedMain != nil || existing?.imageUrl != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title)
                        .accessibilityIdentifier("titleField")
                        .focused($titleFocused)
                        .submitLabel(.done)
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(2...6)
                }
                Section("Color") {
                    accentPicker
                }
                Section {
                    mainPicture
                } header: {
                    Text("Picture")
                } footer: {
                    Text("Copy a screenshot or image, then tap Paste.")
                }
                if hasMain {
                    Section {
                        extras
                    } header: {
                        Text("More pictures (\(extrasCount) of \(Config.maxExtraPictures))")
                    }
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .disabled(saving)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(coinId == nil ? "New coin" : "Edit coin")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("Save") { Task { await save() } }
                            .bold()
                            .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .sheet(isPresented: $addingExtra) {
                AddPictureSheet { data in
                    addingExtra = false
                    stage(data, asMain: false)
                }
                .presentationDetents([.height(260)])
            }
            .fullScreenCover(item: $cropping) { request in
                CropView(image: request.picture.image) { result in
                    cropping = nil
                    guard let result, let data = ImageProcessing.uploadData(from: result),
                          let img = UIImage(data: data) else { return }
                    let edited = StagedPicture(data: data, image: img)
                    if request.isMain {
                        stagedMain = edited
                    } else if let i = stagedExtras.firstIndex(where: { $0.id == request.picture.id }) {
                        stagedExtras[i] = edited
                    }
                }
            }
            .alert("Remove this picture?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
                Button("Remove", role: .destructive) {
                    if let picture = removing { Task { await model.deletePicture(picture, of: id) } }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
        .interactiveDismissDisabled(saving || stagedMain != nil || !stagedExtras.isEmpty)
        .onAppear(perform: load)
    }

    // MARK: Sections

    private var accentPicker: some View {
        HStack {
            ForEach(AccentPalette.hex.indices, id: \.self) { i in
                Button { accent = i } label: {
                    Circle()
                        .fill(AccentPalette.color(i))
                        .frame(width: 34, height: 34)
                        .overlay(Circle().strokeBorder(Color.white, lineWidth: accent == i ? 3 : 0))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Color \(i + 1)")
                .accessibilityAddTraits(accent == i ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }

    private var mainPicture: some View {
        VStack(spacing: 12) {
            Group {
                if let stagedMain {
                    Image(uiImage: stagedMain.image).resizable().scaledToFit()
                } else if let first = existing?.pictures.first, first.isPrimary {
                    CachedImage(picture: first)
                } else {
                    Image(systemName: "photo.badge.plus")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(maxHeight: 240)
            .frame(minHeight: 120)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            PictureSourceButtons { data in stage(data, asMain: true) }

            if let stagedMain {
                Button {
                    cropping = StagedCrop(picture: stagedMain, isMain: true)
                } label: {
                    Label("Crop or rotate", systemImage: "crop.rotate")
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var extras: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(existingExtras) { picture in
                    thumb { CachedImage(picture: picture, contentMode: .fill) } onRemove: { removing = picture }
                }
                ForEach(stagedExtras) { staged in
                    thumb {
                        Image(uiImage: staged.image).resizable().scaledToFill()
                    } onRemove: {
                        stagedExtras.removeAll { $0.id == staged.id }
                    }
                    .onTapGesture { cropping = StagedCrop(picture: staged, isMain: false) }
                }
                if extrasCount < Config.maxExtraPictures {
                    Button { addingExtra = true } label: {
                        Image(systemName: "plus")
                            .font(.title2)
                            .frame(width: 72, height: 72)
                            .background(Color.secondary.opacity(0.2), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add picture")
                }
            }
            .padding(.vertical, 6)
        }
    }

    private func thumb<Content: View>(@ViewBuilder _ content: () -> Content, onRemove: @escaping () -> Void) -> some View {
        content()
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .topTrailing) {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.6))
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .offset(x: 6, y: -6)
                .accessibilityLabel("Remove picture")
            }
    }

    // MARK: Actions

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let coin = existing {
            title = coin.title
            notes = coin.notes
            accent = coin.accent
        } else {
            accent = model.suggestedAccent()
            titleFocused = true
        }
    }

    private func stage(_ data: Data, asMain: Bool) {
        guard let image = UIImage(data: data) else { return }
        let picture = StagedPicture(data: data, image: image)
        if asMain || !hasMain {
            stagedMain = picture
        } else if extrasCount < Config.maxExtraPictures {
            stagedExtras.append(picture)
        } else {
            model.show("A coin holds at most \(Config.maxExtraPictures + 1) pictures")
        }
    }

    /// Each step clears what it finished, so tapping Save again after a
    /// failure continues where it stopped instead of duplicating anything.
    private func save() async {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        saving = true
        error = nil
        defer { saving = false }
        do {
            try await model.saveCoinDetails(id: id, title: name, notes: notes, accent: accent)
            if let main = stagedMain {
                try await model.uploadMainPicture(coinId: id, jpeg: main.data)
                stagedMain = nil
            }
            while let next = stagedExtras.first {
                try await model.uploadExtraPicture(coinId: id, jpeg: next.data)
                stagedExtras.removeFirst()
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription + " Tap Save to try again."
        }
    }
}

struct StagedCrop: Identifiable {
    var id: UUID { picture.id }
    let picture: StagedPicture
    let isMain: Bool
}
