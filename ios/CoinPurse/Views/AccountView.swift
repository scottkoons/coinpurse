import SwiftUI

struct AccountView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppLock.self) private var lock
    @Environment(\.dismiss) private var dismiss
    @State private var confirmSignOutAll = false
    @State private var confirmDelete = false
    @State private var deleting = false
    @State private var rearranging = false
    @AppStorage("swipeToDelete") private var swipeToDelete = true

    var body: some View {
        @Bindable var lock = lock
        NavigationStack {
            Form {
                Section("Signed in as") {
                    // An address must never be split with a hyphen that is not in it:
                    // one line, shrinking to fit at the largest text sizes.
                    Text(verbatim: model.email.isEmpty ? "Your account" : model.email)
                        .lineLimit(1)
                        .minimumScaleFactor(0.4)
                        .truncationMode(.middle)
                }
                Section {
                    Button("Rearrange Coins") { rearranging = true }
                        .disabled(model.coins.count < 2)
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
                    Button("Sign out") {
                        dismiss()
                        Task { await model.signOut() }
                    }
                    Button("Sign out of all devices") { confirmSignOutAll = true }
                } footer: {
                    Text("Use this if you lose a phone. Every other phone and browser will need a new email code.")
                }
                Section {
                    Button("Delete Account", role: .destructive) { confirmDelete = true }
                        .disabled(deleting)
                } footer: {
                    Text("Permanently deletes your account, every coin and every picture, on all devices.")
                }
                Section {
                    Link("Privacy Policy", destination: Config.baseURL.appendingPathComponent("privacy"))
                    Link("Support", destination: Config.baseURL.appendingPathComponent("support"))
                } footer: {
                    Text("Coin Purse \(Self.version) by Yetignome")
                }
            }
            .navigationTitle("Account")
            .sheet(isPresented: $rearranging) { ReorderView() }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .overlay { if deleting { ProgressView().scaleEffect(1.4) } }
            .alert("Sign out of all devices?", isPresented: $confirmSignOutAll) {
                Button("Sign out all", role: .destructive) { Task { await model.signOutEverywhere() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This phone stays signed in.")
            }
            .alert("Delete your account?", isPresented: $confirmDelete) {
                Button("Delete Account", role: .destructive) {
                    Task {
                        deleting = true
                        let gone = await model.deleteAccount()
                        deleting = false
                        if gone { dismiss() }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your account, every coin and every picture will be permanently deleted. This cannot be undone.")
            }
        }
    }

    static var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }
}
