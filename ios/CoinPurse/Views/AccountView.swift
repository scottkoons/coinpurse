import SwiftUI

/// Settings: how the purse behaves, and where to read more. There is no
/// account: everything is kept on this iPhone.
struct AccountView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppLock.self) private var lock
    @Environment(\.dismiss) private var dismiss
    @State private var rearranging = false
    @AppStorage("swipeToDelete") private var swipeToDelete = true

    var body: some View {
        @Bindable var lock = lock
        NavigationStack {
            Form {
                Section {
                    Button("Rearrange Coins") { rearranging = true }
                        .disabled(model.purse.count < 2)
                } footer: {
                    Text("Or touch and hold a card in the purse and drag it.")
                }
                Section {
                    Toggle("Swipe to Delete", isOn: $swipeToDelete)
                } footer: {
                    Text("Swipe a coin's bar to the left to delete it, as in Mail.  Undo shows for a few seconds after.")
                }
                if AppLock.canLock {
                    Section {
                        Toggle("Lock with \(AppLock.biometryName)", isOn: $lock.enabled)
                    } footer: {
                        Text("Asks for \(AppLock.biometryName) when you open Coin Purse after a minute away.")
                    }
                }
                Section {
                    Link("Privacy Policy", destination: Config.website.appendingPathComponent("privacy"))
                    Link("Support", destination: Config.website.appendingPathComponent("support"))
                } footer: {
                    Text("Your coins and pictures are kept only on this iPhone, and work with no internet.  They are included in your iPhone's iCloud Backup.\n\nCoin Purse \(Self.version) by Yetignome")
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $rearranging) { ReorderView() }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    static var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }
}
