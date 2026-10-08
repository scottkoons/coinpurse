import SwiftUI
import UIKit

/// What was shared to Coin Purse: pictures (ready to upload) and/or text.
struct ShareInput {
    var images: [Data] = []
    var previews: [UIImage] = []
    /// A link or some text, saved as the coin's note.
    var text: String?
}

/// "Share to Coin Purse" from Messages, Photos, Safari or any app: save the
/// pictures (up to six) as a new coin, or add them to a coin you already have.
struct ShareView: View {
    let load: () async -> ShareInput
    let onDone: () -> Void
    let onCancel: () -> Void

    private enum Target: Hashable { case new, existing }

    @State private var input = ShareInput()
    @State private var loading = true
    @State private var coins: [Coin] = []
    @State private var target: Target = .new
    @State private var chosen: String?
    @State private var title = ""
    @State private var saving = false
    @State private var error: String?
    /// One id for the new coin and a count of pictures already sent, so
    /// tapping Save again after a failure never duplicates anything.
    @State private var draftId = UUID().uuidString.lowercased()
    @State private var uploaded = 0
    /// Set once the coin has a main picture from this share (survives a retry).
    @State private var sentMain = false

    private let token = Keychain.loadToken()
    private static let maxPictures = Config.maxExtraPictures + 1

    private var api: APIClient { APIClient(token: token) }
    private var chosenCoin: Coin? { coins.first { $0.id == chosen } }
    private func room(in coin: Coin) -> Int { max(0, Self.maxPictures - coin.pictures.count) }

    /// The shared text does not all fit in the coin's notes (the form says so).
    private var textOverflows: Bool {
        guard let text = input.text else { return false }
        switch target {
        case .new:
            return text.serverLength > Config.maxNotes
        case .existing:
            guard let coin = chosenCoin, !coin.notes.contains(text) else { return false }
            return coin.notes.serverLength + 1 + text.serverLength > Config.maxNotes
        }
    }

    private var canSave: Bool {
        guard !saving, !loading, token != nil, !input.images.isEmpty || input.text != nil else { return false }
        switch target {
        case .new: return true
        case .existing:
            guard let coin = chosenCoin else { return false }
            return input.images.isEmpty || room(in: coin) > 0
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView()
                } else if token == nil {
                    ContentUnavailableView(
                        "Sign In First",
                        systemImage: "person.crop.circle.badge.exclamationmark",
                        description: Text("Open Coin Purse and sign in, then share again.")
                    )
                } else if input.images.isEmpty && input.text == nil {
                    ContentUnavailableView(
                        "Nothing to Add",
                        systemImage: "photo.on.rectangle.angled",
                        description: Text("Coin Purse can save pictures, links and text.")
                    )
                } else {
                    form
                }
            }
            .navigationTitle("Coin Purse")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel).disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("Save") { Task { await save() } }
                            .bold()
                            .disabled(!canSave)
                            .accessibilityIdentifier("shareSave")
                    }
                }
            }
        }
        .task {
            input = await load()
            loading = false
            if token != nil, let list = try? await api.coins() {
                // Archived coins are put away; sharing adds to the purse.
                coins = list.coins.filter { !$0.archived }
            }
        }
    }

    private var form: some View {
        ScrollViewReader { scroller in
        Form {
            // At the top, where it is seen even with the keyboard up.
            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
                .id("shareError")
            }
            if !input.previews.isEmpty {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(Array(input.previews.enumerated()), id: \.offset) { i, image in
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 84, height: 84)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .accessibilityLabel("Picture \(i + 1)")
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } footer: {
                    Text(input.images.count == 1 ? "1 picture" : "\(input.images.count) pictures")
                }
            }
            if let text = input.text {
                Section {
                    Text(text).lineLimit(5).textSelection(.enabled)
                } header: {
                    Text("Note")
                } footer: {
                    if textOverflows {
                        Text("A coin's notes hold up to \(Config.maxNotes.formatted()) characters, so only the beginning of this text is saved.")
                    }
                }
            }
            Section {
                Picker("Save to", selection: $target) {
                    Text("New Coin").tag(Target.new)
                    Text("Add to a Coin").tag(Target.existing)
                }
                .pickerStyle(.segmented)
                .disabled(coins.isEmpty)
                .accessibilityIdentifier("shareTarget")
            }
            switch target {
            case .new:
                Section {
                    TextField("Title (optional)", text: $title)
                        .accessibilityIdentifier("shareTitle")
                        .onChange(of: title) { _, new in
                            if new.serverLength > Config.maxTitle { title = new.limited(to: Config.maxTitle) }
                        }
                } footer: {
                    Text("Leave the title blank and it gets the next Coin number.")
                }
            case .existing:
                Section {
                    ForEach(coins) { coin in
                        let full = !input.images.isEmpty && room(in: coin) == 0
                        Button {
                            chosen = coin.id
                        } label: {
                            HStack(spacing: 12) {
                                Circle().fill(coin.accentColor).frame(width: 12, height: 12)
                                Text(coin.title).foregroundStyle(full ? .secondary : .primary)
                                Spacer()
                                if full {
                                    Text("Full").font(.footnote).foregroundStyle(.secondary)
                                } else if chosen == coin.id {
                                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor).bold()
                                }
                            }
                        }
                        .disabled(full)
                        .accessibilityAddTraits(chosen == coin.id ? .isSelected : [])
                    }
                } header: {
                    Text("Your coins")
                } footer: {
                    if let coin = chosenCoin, !input.images.isEmpty, input.images.count > room(in: coin) {
                        Text("“\(coin.title)” has room for \(room(in: coin)) more. Only the first \(room(in: coin)) will be added.")
                    } else {
                        Text("A coin holds up to \(Self.maxPictures) pictures.")
                    }
                }
            }
        }
        .onChange(of: error) { _, message in
            guard let message else { return }
            withAnimation { scroller.scrollTo("shareError", anchor: .top) }
            AccessibilityNotification.Announcement(message).post()
        }
        }
    }

    private func save() async {
        saving = true
        error = nil
        defer { saving = false }
        do {
            switch target {
            case .new:
                _ = try await api.createCoin(
                    id: draftId,
                    title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                    notes: (input.text ?? "").limited(to: Config.maxNotes),
                    accent: Int.random(in: 0..<AccentPalette.hex.count)
                )
                for (i, jpeg) in input.images.prefix(Self.maxPictures).enumerated() where i >= uploaded {
                    if i == 0 {
                        _ = try await api.uploadMainPicture(coinId: draftId, jpeg: jpeg)
                    } else {
                        _ = try await api.addPicture(coinId: draftId, jpeg: jpeg)
                    }
                    uploaded = i + 1
                }
            case .existing:
                guard let coin = chosenCoin else { return }
                let fitting = Array(input.images.prefix(room(in: coin)))
                for (i, jpeg) in fitting.enumerated() where i >= uploaded {
                    if coin.imageUrl != nil || sentMain {
                        _ = try await api.addPicture(coinId: coin.id, jpeg: jpeg)
                    } else {
                        _ = try await api.uploadMainPicture(coinId: coin.id, jpeg: jpeg)
                        sentMain = true
                    }
                    uploaded = i + 1
                }
                if let text = input.text, !coin.notes.contains(text) {
                    let notes = (coin.notes.isEmpty ? text : coin.notes + "\n" + text).limited(to: Config.maxNotes)
                    _ = try await api.updateCoin(id: coin.id, title: coin.title, notes: notes, accent: coin.accent)
                }
            }
            onDone()
        } catch {
            self.error = error.localizedDescription + " Tap Save to try again."
        }
    }
}
