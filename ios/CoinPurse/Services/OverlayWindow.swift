import SwiftUI
import UIKit

/// A window of its own above the whole app, including sheets and full-screen
/// pictures. Used for the lock screen (it must cover everything) and for short
/// messages (they must show whatever is open).
final class OverlayWindow {
    private var window: PassThroughWindow?
    private let level: UIWindow.Level
    /// Touches go through to the app underneath (for messages, not the lock).
    private let passesTouches: Bool

    init(level: UIWindow.Level, passesTouches: Bool) {
        self.level = level
        self.passesTouches = passesTouches
    }

    func show(_ content: some View) {
        if let window, let host = window.rootViewController as? UIHostingController<AnyView> {
            host.rootView = AnyView(content)
            window.isHidden = false
            return
        }
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState != .unattached }) else { return }
        let host = UIHostingController(rootView: AnyView(content))
        host.view.backgroundColor = .clear
        let window = PassThroughWindow(windowScene: scene)
        window.windowLevel = level
        window.passesTouches = passesTouches
        window.backgroundColor = .clear
        window.rootViewController = host
        window.isHidden = false
        self.window = window
    }

    func hide() {
        window?.isHidden = true
        window = nil
    }
}

final class PassThroughWindow: UIWindow {
    var passesTouches = false

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        // Empty space lets the touch through to the app below.
        if passesTouches, hit === rootViewController?.view { return nil }
        return hit
    }
}
