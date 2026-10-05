import SwiftUI

@main
struct CoinPurseApp: App {
    @State private var model = AppModel()
    @State private var lock = AppLock()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(lock)
                .preferredColorScheme(.dark)
                .task {
                    await model.start()
                    // Launching into a signed-in purse: ask to unlock now.
                    lock.scenePhaseChanged(scenePhase, signedIn: model.phase == .signedIn)
                }
                .onChange(of: model.phase) { old, new in
                    // Signing in just proved who you are; signing out leaves
                    // nothing to lock. Launching into a saved session stays locked.
                    if new == .signedOut || old == .signedOut { lock.isLocked = false }
                }
                .onChange(of: scenePhase) { _, phase in
                    lock.scenePhaseChanged(phase, signedIn: model.phase == .signedIn)
                    if phase == .active, model.phase == .signedIn, !lock.isLocked {
                        Task { await model.refresh() }
                    }
                }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppLock.self) private var lock
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack(alignment: .bottom) {
            switch model.phase {
            case .loading:
                ProgressView()
            case .signedOut:
                SignInView()
            case .signedIn:
                PurseView()
            }
            if let toast = model.toast {
                Text(toast)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(10)
            }
            // Locked, or hidden in the app switcher: never show the purse.
            if model.phase == .signedIn && lock.enabled && AppLock.canLock
                && (lock.isLocked || scenePhase != .active) {
                LockView().zIndex(20)
            }
        }
        .animation(.default, value: model.toast)
    }
}
