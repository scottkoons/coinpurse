import CoreSpotlight
import SwiftUI
import TipKit

@main
struct CoinPurseApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @State private var quick = QuickActions.shared
    @State private var lock = AppLock()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if DEBUG
        // UI tests run without tips covering the screen.
        if ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("-uiTest") }) {
            Tips.hideAllTipsForTesting()
        }
        #endif
        try? Tips.configure()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(lock)
                .environment(quick)
                // A coin tapped in iPhone Search opens here.
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    if let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String {
                        quick.pending = .openCoin(id)
                    }
                }
                .task {
                    await model.start()
                    // Launching: ask to unlock now.
                    lock.scenePhaseChanged(scenePhase, ready: model.phase == .ready)
                }
                .onChange(of: lock.isLocked) { wasLocked, locked in
                    // Just unlocked: pick up coins added meanwhile (like ones
                    // shared from Photos or Messages).
                    if wasLocked, !locked, model.phase == .ready {
                        Task { await model.refresh() }
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    lock.scenePhaseChanged(phase, ready: model.phase == .ready)
                    // Leaving the app ends the Undo moment for a swiped-away coin.
                    if phase == .background {
                        Task { await model.finishUndoable() }
                        // Hidden coins are covered again until the next Face ID.
                        model.hideRevealed()
                    }
                    if phase == .active, model.phase == .ready, !lock.isLocked {
                        Task {
                            await model.refresh()
                            // Coins still on the old server: try again now.
                            await model.moveFromServer()
                        }
                    }
                }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppLock.self) private var lock
    @Environment(\.scenePhase) private var scenePhase
    @State private var lockWindow = OverlayWindow(level: .alert + 1, passesTouches: false)
    @State private var toastWindow = OverlayWindow(level: .alert + 2, passesTouches: true)

    /// Locked, or hidden in the app switcher: nothing in the purse may show,
    /// including anything open on top of it.
    private var covered: Bool {
        model.phase == .ready && lock.enabled && AppLock.canLock
            && (lock.isLocked || scenePhase != .active)
    }

    var body: some View {
        Group {
            switch model.phase {
            case .loading:
                ProgressView()
            case .ready:
                PurseView()
            }
        }
        .onChange(of: covered, initial: true) { _, isCovered in
            if isCovered {
                lockWindow.show(LockView().environment(lock))
            } else {
                lockWindow.hide()
            }
        }
        .onChange(of: model.toast, initial: true) { _, message in
            if let message {
                toastWindow.show(ToastView(message: message).environment(model))
            } else {
                toastWindow.hide()
            }
        }
    }
}

/// A short message at the bottom of the screen, above anything that is open.
struct ToastView: View {
    let message: String
    @Environment(AppModel.self) private var model
    @State private var shown = false

    var body: some View {
        VStack {
            Spacer()
            Text(message)
                .font(.callout)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.thinMaterial, in: Capsule())
                .padding(.horizontal, 24)
                // Clear of the New Coin button, and above the Undo bar when it shows.
                .padding(.bottom, model.undoable == nil ? 96 : 156)
                .animation(.spring(response: 0.35, dampingFraction: 0.86), value: model.undoable == nil)
                .offset(y: shown ? 0 : 30)
                .opacity(shown ? 1 : 0)
                .accessibilityAddTraits(.isStaticText)
        }
        .onAppear {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { shown = true }
            UIAccessibility.post(notification: .announcement, argument: message)
        }
    }
}
