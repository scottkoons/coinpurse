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
        // Scrolls when space is short (small iPhone, keyboard up, large text),
        // so nothing is ever cut off.
        GeometryReader { geo in
        ScrollViewReader { scroller in
        ScrollView {
        VStack(spacing: 20) {
            Spacer(minLength: 0)
            Image("Logo")
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            Text("Coin Purse")
                .font(.largeTitle.bold())
            VStack(spacing: 4) {
                Text("A simple app for simple things.")
                    .font(.headline)
                Text("Snap it.  Find it.  Toss it.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            Text(sentTo == nil
                 ? "Sign in with your email. We will send you a 6-digit code."
                 : "Enter the 6-digit code we sent to \(sentTo ?? "").")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

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
                    .fixedSize(horizontal: false, vertical: true)
                    .id("error")
            }
            Spacer(minLength: 0)
            HStack(spacing: 16) {
                Link("Privacy", destination: Config.baseURL.appendingPathComponent("privacy"))
                Link("Support", destination: Config.baseURL.appendingPathComponent("support"))
            }
            .font(.footnote)
            .frame(minHeight: 44)
        }
        .padding(24)
        .frame(minHeight: geo.size.height)
        }
        .scrollDismissesKeyboard(.interactively)
        // A problem is always seen and heard, even with the keyboard up.
        .onChange(of: error) { _, message in
            guard let message else { return }
            withAnimation { scroller.scrollTo("error", anchor: .bottom) }
            AccessibilityNotification.Announcement(message).post()
        }
        }
        }
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
