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
                                // the first coin is already at the top.
                                let isFirst = id == ids.first
                                Button { withAnimation { moveToTop(id) } } label: {
                                    Image(systemName: "arrow.up.to.line")
                                        .font(.body.weight(.semibold))
                                        .frame(width: 44, height: 44)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.borderless)
                                .opacity(isFirst ? 0 : 1)
                                .disabled(isFirst)
                                .accessibilityHidden(isFirst)
                                .accessibilityLabel("Move \(coin.title) to the top")
                            }
                        }
                    }
                    .onMove { from, to in ids.move(fromOffsets: from, toOffset: to) }
                } footer: {
                    Text("Drag the handles to change the order, or tap the arrow to move a coin to the top.")
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
    }

    private func moveToTop(_ id: String) {
        guard let i = ids.firstIndex(of: id) else { return }
        ids.insert(ids.remove(at: i), at: 0)
    }
}
