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

    private let token = Keychain.loadToken()
    private static let maxPictures = Config.maxExtraPictures + 1

    private var api: APIClient { APIClient(token: token) }
    private var chosenCoin: Coin? { coins.first { $0.id == chosen } }
    private func room(in coin: Coin) -> Int { max(0, Self.maxPictures - coin.pictures.count) }

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
                coins = list.coins
            }
        }
    }

    private var form: some View {
        Form {
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
                Section("Note") {
                    Text(text).lineLimit(5).textSelection(.enabled)
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
            if let error {
                Section { Text(error).foregroundStyle(.red) }
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
                    notes: input.text ?? "",
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
                var hasMain = coin.imageUrl != nil
                for (i, jpeg) in fitting.enumerated() where i >= uploaded {
                    if hasMain {
                        _ = try await api.addPicture(coinId: coin.id, jpeg: jpeg)
                    } else {
                        _ = try await api.uploadMainPicture(coinId: coin.id, jpeg: jpeg)
                        hasMain = true
                    }
                    uploaded = i + 1
                }
                if let text = input.text, !coin.notes.contains(text) {
                    let notes = coin.notes.isEmpty ? text : coin.notes + "\n" + text
                    _ = try await api.updateCoin(id: coin.id, title: coin.title, notes: notes, accent: coin.accent)
                }
            }
            onDone()
        } catch {
            self.error = error.localizedDescription + " Tap Save to try again."
        }
    }
}
