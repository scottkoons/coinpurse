import SwiftUI

/// A picture chosen in the editor but not uploaded yet.
struct StagedPicture: Identifiable, Equatable {
    let id = UUID()
    var data: Data
    var image: UIImage
}

/// Add or edit a coin: title, notes, color, map pin, main picture and extras.
struct EditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// nil when adding a new coin.
    let coinId: String?
    /// Opened from Pin: find where you are right away, map first.
    var startsWithPin = false

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
    @State private var pin: Pin?
    @State private var pinChanged = false
    @State private var locating = false
    @State private var pinError: String?
    @State private var finder = LocationFinder()
    @Environment(\.openURL) private var openURL
    @FocusState private var titleFocused: Bool

    private var id: String { coinId ?? draftId }
    private var existing: Coin? { model.coin(id) }
    private var existingExtras: [Picture] { existing?.pictures.filter { !$0.isPrimary } ?? [] }
    private var extrasCount: Int { existingExtras.count + stagedExtras.count }
    private var hasMain: Bool { stagedMain != nil || existing?.imageUrl != nil }
    /// A quick coin needs only a picture; a title or notes alone (like a
    /// pasted gift card code) is fine too.
    private var canSave: Bool {
        existing != nil || stagedMain != nil || pin != nil
            || !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                if startsWithPin { pinSection }
                Section {
                    mainPicture
                } header: {
                    Text(startsWithPin ? "Photo of the spot (optional)" : "Picture")
                } footer: {
                    Text("Copy a picture in any app and Paste lights up. Not for credit cards, IDs or passwords.")
                }
                Section {
                    TextField("Title (optional)", text: $title)
                        .accessibilityIdentifier("titleField")
                        .focused($titleFocused)
                        .submitLabel(.done)
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(2...6)
                } footer: {
                    if coinId == nil && title.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text("Leave the title blank and it is saved as \(model.nextDefaultTitle()).")
                    }
                }
                Section("Color") {
                    AccentPicker(accent: $accent)
                }
                if hasMain {
                    Section {
                        extras
                    } header: {
                        Text("More pictures (\(extrasCount) of \(Config.maxExtraPictures))")
                    }
                }
                if !startsWithPin { pinSection }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .disabled(saving)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(coinId != nil ? "Edit coin" : startsWithPin ? "Pin your spot" : "New coin")
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
                            .disabled(!canSave)
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

    /// Where you are now, saved on the coin. Tap it later for walking directions.
    private var pinSection: some View {
        Section {
            if let pin {
                PinMapView(pin: pin, tint: AccentPalette.color(accent))
                    .frame(height: 190)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                HStack {
                    Text(pin.pinnedLabel)
                    Spacer()
                    if let acc = pin.acc {
                        Text("Within " + Measurement(value: acc.rounded(), unit: UnitLength.meters)
                            .formatted(.measurement(width: .abbreviated, usage: .road)))
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                Button { Task { await locate() } } label: {
                    Label(locating ? "Finding where you are…" : "Move Pin Here", systemImage: "location.fill")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .disabled(locating)
                Button("Remove Pin", role: .destructive) {
                    withAnimation { self.pin = nil }
                    pinChanged = true
                }
            } else if locating {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Finding where you are…").foregroundStyle(.secondary)
                }
            } else {
                Button { Task { await locate() } } label: {
                    Label("Pin where I am now", systemImage: "mappin.and.ellipse")
                }
                .accessibilityIdentifier("pinHere")
            }
            if let pinError {
                Text(pinError).font(.footnote).foregroundStyle(.red)
                if finder.isDenied {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                }
            }
        } header: {
            Text("Map pin")
        } footer: {
            Text("Tap the pin later for walking directions in Apple Maps.  Your location is only used when you tap.")
        }
    }

    private func locate() async {
        locating = true
        pinError = nil
        defer { locating = false }
        do {
            let found = try await finder.currentPin()
            withAnimation { pin = found }
            pinChanged = true
        } catch is CancellationError {
        } catch {
            pinError = error.localizedDescription
        }
    }

    private var mainPicture: some View {
        VStack(spacing: 12) {
            Group {
                if let stagedMain {
                    Image(uiImage: stagedMain.image).resizable().scaledToFit()
                } else if let first = existing?.pictures.first, first.isPrimary {
                    CachedImage(picture: first)
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "photo.badge.plus")
                            .font(.title)
                            .accessibilityHidden(true)
                        Text("No picture yet")
                            .font(.subheadline)
                    }
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 90)
                }
            }
            .frame(maxHeight: 240)
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
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    private var extras: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Array(existingExtras.enumerated()), id: \.element.id) { i, picture in
                    thumb(number: i + 2) { CachedImage(picture: picture, contentMode: .fill) } onRemove: { removing = picture }
                }
                ForEach(Array(stagedExtras.enumerated()), id: \.element.id) { i, staged in
                    thumb(number: existingExtras.count + i + 2) {
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

    private func thumb<Content: View>(number: Int, @ViewBuilder _ content: () -> Content, onRemove: @escaping () -> Void) -> some View {
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
                .accessibilityLabel("Remove picture \(number)")
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
            pin = coin.pin
        } else {
            // No keyboard yet: the Paste button is the first thing to see.
            accent = model.suggestedAccent()
            // From Pin: start finding you straight away.
            if startsWithPin { Task { await locate() } }
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
        guard canSave else { return }
        saving = true
        error = nil
        defer { saving = false }
        do {
            let isNew = existing == nil
            try await model.saveCoinDetails(id: id, title: name, notes: notes, accent: accent, pin: isNew ? pin : nil)
            if !isNew && pinChanged {
                try await model.setPin(pin, on: id)
            }
            pinChanged = false
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
