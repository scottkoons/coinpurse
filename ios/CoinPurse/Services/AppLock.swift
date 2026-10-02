import LocalAuthentication
import SwiftUI

/// Face ID / Touch ID / passcode lock. On by default; locks when the app has
/// been in the background for more than a minute.
@Observable
final class AppLock {
    var isLocked = false
    var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Self.key) }
    }

    private static let key = "appLockEnabled"
    private static let grace: TimeInterval = 60
    private var backgroundedAt: Date?
    private var authenticating = false

    init() {
        enabled = UserDefaults.standard.object(forKey: Self.key) as? Bool ?? true
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uiTestNoLock") { enabled = false }
        #endif
        isLocked = enabled && Self.canLock
    }

    /// False when the phone has no passcode (nothing to unlock with).
    static var canLock: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    static var biometryName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "Passcode"
        }
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .background:
            backgroundedAt = Date()
        case .active:
            if let since = backgroundedAt, enabled, Self.canLock,
               Date().timeIntervalSince(since) > Self.grace {
                isLocked = true
            }
            backgroundedAt = nil
            if isLocked { Task { await unlock() } }
        default:
            break
        }
    }

    func unlock() async {
        guard isLocked, !authenticating else { return }
        guard Self.canLock else { isLocked = false; return }
        authenticating = true
        defer { authenticating = false }
        let context = LAContext()
        do {
            if try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock your purse") {
                isLocked = false
            }
        } catch {
            // Stay locked; the lock screen offers another try.
        }
    }
}

struct LockView: View {
    @Environment(AppLock.self) private var lock

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.fill")
                .font(.system(size: 44))
                .foregroundStyle(Color.accentColor)
            Text("CoinPurse is locked")
                .font(.title3.bold())
            Button {
                Task { await lock.unlock() }
            } label: {
                Text("Unlock with \(AppLock.biometryName)").bold().frame(minWidth: 220, minHeight: 32)
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
    }
}
