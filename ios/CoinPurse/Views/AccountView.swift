import SwiftUI

struct AccountView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppLock.self) private var lock
    @Environment(\.dismiss) private var dismiss
    @State private var confirmSignOutAll = false
    @State private var confirmDelete = false
    @State private var deleting = false

    var body: some View {
        @Bindable var lock = lock
        NavigationStack {
            Form {
                Section("Signed in as") {
                    Text(model.email.isEmpty ? "Your account" : model.email)
                }
                if AppLock.canLock {
                    Section {
                        Toggle("Lock with \(AppLock.biometryName)", isOn: $lock.enabled)
                    } footer: {
                        Text("Asks for \(AppLock.biometryName) when you open CoinPurse after a minute away.")
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
                    Text("CoinPurse \(Self.version) by Yetignome")
                }
            }
            .navigationTitle("Account")
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
