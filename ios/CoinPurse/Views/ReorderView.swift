import SwiftUI

/// The purse as a list with handles: the easy way to put many coins in order.
/// (In the purse itself, touch and hold a card and drag it.)
struct ReorderView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var ids: [String] = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(ids, id: \.self) { id in
                        if let coin = model.coin(id) {
                            HStack(spacing: 12) {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(LinearGradient(colors: [AccentPalette.cardColors(coin.accent).top,
                                                                  AccentPalette.cardColors(coin.accent).bottom],
                                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .frame(width: 30, height: 20)
                                    .accessibilityHidden(true)
                                Text(coin.title.isEmpty ? "Untitled" : coin.title)
                                    .lineLimit(2)
                                Spacer(minLength: 8)
                                // Every row keeps the arrow's room, so the rows line up;
                                // the last coin is already the front card.
                                let isFront = id == ids.last
                                Button { withAnimation { moveToFront(id) } } label: {
                                    Image(systemName: "arrow.down.to.line")
                                        .font(.body.weight(.semibold))
                                        .frame(width: 44, height: 44)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.borderless)
                                .opacity(isFront ? 0 : 1)
                                .disabled(isFront)
                                .accessibilityHidden(isFront)
                                .accessibilityLabel("Move \(coin.title.isEmpty ? "Untitled" : coin.title) to the front")
                            }
                        }
                    }
                    .onMove { from, to in ids.move(fromOffsets: from, toOffset: to) }
                } footer: {
                    // In the purse's own order, top to bottom: the last coin is the front card.
                    Text("Drag the handles to change the order, or tap the arrow to bring a coin to the front, at the bottom of your purse.")
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Rearrange")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        let newOrder = ids
                        dismiss()
                        if newOrder != model.purse.map(\.id) {
                            MoveCardsTip().invalidate(reason: .actionPerformed)
                            Task { await model.reorder(newOrder) }
                        }
                    }
                    .bold()
                }
            }
        }
        .onAppear { ids = model.purse.map(\.id) }
        // A coin deleted or archived while this is open leaves the list
        // (rather than staying as a blank row with a handle).
        .onChange(of: model.purse.map(\.id)) { _, now in
            let still = Set(now)
            ids.removeAll { !still.contains($0) }
        }
    }

    private func moveToFront(_ id: String) {
        guard let i = ids.firstIndex(of: id) else { return }
        ids.append(ids.remove(at: i))
    }
}
