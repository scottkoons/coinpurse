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
    private static var grace: TimeInterval {
        #if DEBUG
        // The website film shows the lock without waiting a minute.
        if ProcessInfo.processInfo.arguments.contains("-uiTestLockNow") { return 0 }
        #endif
        return 60
    }
    private var backgroundedAt: Date?
    private var authenticating = false
    /// Face ID is asked for by itself only once each time the lock engages
    /// (at launch, or back after a while away). After a Cancel the lock
    /// screen's button asks, so the prompt never keeps coming back.
    private var promptDue = false

    init() {
        enabled = UserDefaults.standard.object(forKey: Self.key) as? Bool ?? true
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uiTestNoLock") { enabled = false }
        #endif
        isLocked = enabled && Self.canLock
        promptDue = isLocked
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

    /// Face ID is asked for only once the purse has opened. A lock set at
    /// launch stays on while it loads (the purse is not shown until then).
    func scenePhaseChanged(_ phase: ScenePhase, ready: Bool) {
        guard ready else {
            backgroundedAt = nil
            return
        }
        switch phase {
        case .background:
            backgroundedAt = Date()
            // Coming back to a locked purse asks again.
            if isLocked { promptDue = true }
        case .active:
            if let since = backgroundedAt, enabled, Self.canLock,
               Date().timeIntervalSince(since) > Self.grace {
                isLocked = true
                promptDue = true
            }
            backgroundedAt = nil
            if isLocked, promptDue {
                promptDue = false
                Task { await unlock() }
            }
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
            Text("Coin Purse is locked")
                .font(.title3.bold())
            Button {
                Task { await lock.unlock() }
            } label: {
                Text("Unlock with \(AppLock.biometryName)").bold().frame(minWidth: 220, minHeight: 32)
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground).ignoresSafeArea())
    }
}
