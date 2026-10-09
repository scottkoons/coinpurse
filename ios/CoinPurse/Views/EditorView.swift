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
    /// New Coin, Typed Note: the title and notes first, ready to type; a picture is optional.
    var startsWithText = false
    /// A picture to start with (from the camera button, when saving it straight
    /// away did not work), so it is never lost.
    var startingPicture: Data?

    @State private var draftId = UUID().uuidString.lowercased()
    @State private var title = ""
    @State private var notes = ""
    @State private var accent = 0
    @State private var stagedMain: StagedPicture?
    @State private var stagedExtras: [StagedPicture] = []
    @State private var addingExtra = false
    /// The add sheet is open to replace the first picture rather than add one.
    @State private var replacingMain = false
    @State private var cropping: StagedCrop?
    /// Pictures already on the coin that were removed here; they are deleted
    /// when Save is tapped (Cancel keeps them), like every other change.
    @State private var removedExtras: Set<String> = []
    @State private var saving = false
    @State private var error: String?
    @State private var loaded = false
    @State private var pin: Pin?
    @State private var pinChanged = false
    @State private var locating = false
    @State private var pinError: String?
    @State private var finder = LocationFinder()
    /// The title, notes and color as they were when the editor opened, to tell
    /// whether anything would be lost by closing it.
    @State private var original: (title: String, notes: String, accent: Int, hidden: Bool) = ("", "", 0, false)
    /// Hide with Face ID: the coin's notes and pictures show only after Face ID.
    @State private var hidden = false
    @State private var confirmingDiscard = false
    /// Saying the notes instead of typing them.
    @State private var dictating = false
    /// The automatic name it has now (like Coin 3): the title box starts empty
    /// with this as its hint, ready to type a real name; left empty, it stays.
    @State private var automaticTitle: String?
    @Environment(\.openURL) private var openURL
    @FocusState private var titleFocused: Bool

    private var id: String { coinId ?? draftId }
    private var existing: Coin? { model.coin(id) }
    private var existingExtras: [Picture] {
        existing?.pictures.filter { !$0.isPrimary && !removedExtras.contains($0.id) } ?? []
    }
    private var extrasCount: Int { existingExtras.count + stagedExtras.count }
    private var hasMain: Bool { stagedMain != nil || existing?.imageUrl != nil }
    /// A quick coin needs only a picture; a title or notes alone (like a
    /// pasted gift card code) is fine too.
    private var canSave: Bool {
        guard notes.serverLength <= Config.maxNotes else { return false }
        return existing != nil || stagedMain != nil || pin != nil
            || !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Something typed, chosen or added that Save has not kept yet.
    private var hasChanges: Bool {
        title != original.title || notes != original.notes || accent != original.accent || hidden != original.hidden
            || pinChanged || (existing == nil && pin != nil)
            || stagedMain != nil || !stagedExtras.isEmpty || !removedExtras.isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroller in
            Form {
                // At the top, where it is seen even on a small iPhone with a long form.
                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                    .id("saveError")
                }
                // Pin your spot: the map, then its name, then an optional photo.
                if startsWithPin {
                    pinSection
                    detailsSection
                    pictureSection
                } else if startsWithText {
                    detailsSection
                    pictureSection
                } else {
                    pictureSection
                    detailsSection
                }
                Section("Color") {
                    AccentPicker(accent: $accent)
                }
                if !startsWithPin { pinSection }
                hideSection
            }
            .onChange(of: error) { _, message in
                guard let message else { return }
                withAnimation { scroller.scrollTo("saveError", anchor: .top) }
                AccessibilityNotification.Announcement(message).post()
            }
            }
            .disabled(saving)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(coinId != nil ? "Edit coin" : startsWithPin ? "Pin your spot" : startsWithText ? "New note" : "New coin")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // Like Notes and Mail: closing with unsaved changes asks first.
                    Button("Cancel") {
                        if hasChanges { confirmingDiscard = true } else { dismiss() }
                    }
                    .disabled(saving)
                    .confirmationDialog("Discard your changes?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
                        Button("Discard Changes", role: .destructive) { dismiss() }
                        Button("Keep Editing", role: .cancel) {}
                    }
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
                    stage(data, asMain: replacingMain)
                    replacingMain = false
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
        }
        // Swiping down never throws away unsaved changes; Cancel asks instead.
        .interactiveDismissDisabled(saving || hasChanges)
        .onAppear(perform: load)
        .sheet(isPresented: $dictating) {
            VoiceNoteView(onText: { words in
                guard !words.isEmpty else { return }
                notes = notes.isEmpty ? words : notes + "\n" + words
            })
        }
    }

    // MARK: Sections

    /// Where you are now, saved on the coin. Tap it later for walking directions.
    private var pictureSection: some View {
        Section {
            mainPicture
        } header: {
            Text(startsWithPin ? "Photo of the spot (optional)" : startsWithText && !hasMain ? "Picture (optional)" : hasMain ? "Pictures (\(pictureCount) of \(Config.maxExtraPictures + 1))" : "Picture")
        } footer: {
            Text("Copy a picture in any app and Paste lights up.  For everyday things, not credit cards, IDs or important passwords.")
        }
    }

    private var detailsSection: some View {
        Section {
            TextField(automaticTitle ?? "Title (optional)", text: $title)
                .accessibilityIdentifier("titleField")
                .focused($titleFocused)
                .submitLabel(.done)
                .onChange(of: title) { _, new in
                    if new.serverLength > Config.maxTitle { title = new.limited(to: Config.maxTitle) }
                }
            TextField("Notes", text: $notes, axis: .vertical)
                .lineLimit(2...6)
            // Say it instead: the words go into the notes.
            Button { dictating = true } label: {
                // Laid out by hand: in a Label the text takes the mic's height,
                // which is shorter than a line of text, and reads as clipped.
                HStack(spacing: 16) {
                    Image(systemName: "mic")
                        .frame(minWidth: 20)
                        .accessibilityHidden(true)
                    Text("Add a voice note")
                }
            }
            .accessibilityIdentifier("dictate")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if coinId == nil && title.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("Leave the title blank and it is saved as \(model.nextDefaultTitle()).")
                } else if let automaticTitle, title.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("Leave the title blank to keep the name \(automaticTitle).")
                }
                TextLimitNote(length: notes.serverLength, limit: Config.maxNotes)
            }
        }
    }

    /// For a code you would rather not have on show (a gate or a lockbox).
    private var hideSection: some View {
        Section {
            Toggle("Hide with Face ID", isOn: $hidden)
                .disabled(!model.canHide)
                .accessibilityIdentifier("hideToggle")
        } footer: {
            if model.canHide {
                Text("Covers this coin's notes and pictures until you look with \(AppLock.biometryName).  It keeps them from someone holding your unlocked iPhone; it is not encryption.")
            } else {
                Text("Set a passcode on this iPhone to hide coins with Face ID.")
            }
        }
    }

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
                    // Secondary, not tertiary: readable in dark mode too.
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 90)
                }
            }
            .frame(maxHeight: 240)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            if hasMain {
                // Every picture in one row, right under the first, with + to add one.
                extras
                HStack(spacing: 18) {
                    if let stagedMain {
                        Button {
                            cropping = StagedCrop(picture: stagedMain, isMain: true)
                        } label: {
                            Label("Crop or rotate", systemImage: "crop.rotate")
                        }
                    }
                    Button {
                        replacingMain = true
                        addingExtra = true
                    } label: {
                        Label("Replace", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .accessibilityLabel("Replace the first picture")
                }
                .buttonStyle(.borderless)
                .font(.subheadline)
            }

            if pictureCount < Config.maxExtraPictures + 1 {
                // A second Paste, Photos or Camera adds another picture; it never
                // replaces the first one.
                if hasMain {
                    Text("Add another picture")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                PictureSourceButtons { data in stage(data, asMain: false) }
            } else {
                Text("A coin holds up to \(Config.maxExtraPictures + 1) pictures.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    /// Pictures in the coin, counting ones not saved yet.
    private var pictureCount: Int { (hasMain ? 1 : 0) + extrasCount }

    private var extras: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Array(existingExtras.enumerated()), id: \.element.id) { i, picture in
                    thumb(number: i + 2) { CachedImage(picture: picture, contentMode: .fill) } onRemove: {
                        withAnimation(.snappy) { _ = removedExtras.insert(picture.id) }
                    }
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
        defer { original = (title, notes, accent, hidden) }
        if let coin = existing {
            if coin.title.range(of: #"^Coin \d{1,9}$"#, options: .regularExpression) != nil {
                automaticTitle = coin.title
                title = ""
                // Ready to type its real name.
                Task {
                    try? await Task.sleep(for: .milliseconds(450))
                    titleFocused = true
                }
            } else {
                title = coin.title
            }
            notes = coin.notes
            accent = coin.accent
            hidden = coin.hidden
            pin = coin.pin
        } else {
            // No keyboard yet: the Paste button is the first thing to see.
            accent = model.suggestedAccent()
            // From Pin: start finding you straight away.
            if startsWithPin { Task { await locate() } }
            // Typed Note: the keyboard is up and ready.
            if startsWithText {
                Task {
                    try? await Task.sleep(for: .milliseconds(450))
                    titleFocused = true
                }
            }
        }
        // A picture from the camera that could not be saved straight away.
        if let startingPicture { stage(startingPicture, asMain: true) }
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
            try await model.saveCoinDetails(id: id, title: name, notes: notes, accent: accent, pin: isNew ? pin : nil,
                                            hidden: hidden)
            if !isNew && pinChanged {
                try await model.setPin(pin, on: id)
            }
            pinChanged = false
            // Removed first, so there is room for pictures added in their place.
            for pictureId in removedExtras {
                if let picture = existing?.pictures.first(where: { $0.id == pictureId }) {
                    try await model.removePicture(picture, of: id)
                }
                removedExtras.remove(pictureId)
            }
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

/// Shown under a note as it nears the most the server keeps: how much room is
/// left, or (in red) how much to remove before it can be saved. Never cut off
/// without saying so.
struct TextLimitNote: View {
    let length: Int
    let limit: Int

    var body: some View {
        if length > limit {
            Text("\((length - limit).formatted()) characters over the \(limit.formatted()) limit.  Shorten the note to save it.")
                .foregroundStyle(.red)
        } else if limit - length <= 200 {
            Text("\((limit - length).formatted()) characters left.")
        }
    }
}

struct StagedCrop: Identifiable {
    var id: UUID { picture.id }
    let picture: StagedPicture
    let isMain: Bool
}
