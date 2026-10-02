import SwiftUI

struct SignInView: View {
    @Environment(AppModel.self) private var model
    @State private var email = ""
    @State private var code = ""
    @State private var sentTo: String?
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focused: Field?

    enum Field { case email, code }

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "wallet.pass.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)
            Text("CoinPurse")
                .font(.largeTitle.bold())
            Text(sentTo == nil
                 ? "Sign in with your email. We will send you a 6-digit code."
                 : "Enter the 6-digit code we sent to \(sentTo ?? "").")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            if sentTo == nil {
                TextField("you@example.com", text: $email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.send)
                    .focused($focused, equals: .email)
                    .onSubmit { Task { await sendCode() } }
                    .fieldStyle()
                Button { Task { await sendCode() } } label: {
                    label("Email me a code")
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy || !email.contains("@"))
            } else {
                TextField("6-digit code", text: $code)
                    .textContentType(.oneTimeCode)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.center)
                    .font(.title2.monospacedDigit())
                    .focused($focused, equals: .code)
                    .onChange(of: code) { _, new in
                        code = String(new.filter(\.isNumber).prefix(6))
                        if code.count == 6 { Task { await verify() } }
                    }
                    .fieldStyle()
                Button { Task { await verify() } } label: {
                    label("Sign in")
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy || code.count != 6)
                Button("Use a different email") {
                    sentTo = nil
                    code = ""
                    error = nil
                    focused = .email
                }
                .font(.footnote)
            }

            if let error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            Spacer()
            HStack(spacing: 16) {
                Link("Privacy", destination: Config.baseURL.appendingPathComponent("privacy"))
                Link("Support", destination: Config.baseURL.appendingPathComponent("support"))
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding(24)
        .onAppear { focused = .email }
    }

    private func label(_ text: String) -> some View {
        Group {
            if busy { ProgressView() } else { Text(text).bold() }
        }
        .frame(maxWidth: .infinity, minHeight: 32)
    }

    private func sendCode() async {
        let address = email.trimmingCharacters(in: .whitespaces).lowercased()
        guard address.contains("@"), !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            try await model.requestCode(email: address)
            sentTo = address
            focused = .code
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func verify() async {
        guard let sentTo, code.count == 6, !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            try await model.verifyCode(email: sentTo, code: code)
        } catch {
            self.error = error.localizedDescription
            code = ""
        }
    }
}

private extension View {
    func fieldStyle() -> some View {
        padding(14)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}
