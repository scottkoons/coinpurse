import AppIntents
import SwiftUI
import UIKit

/// Ways into Coin Purse from outside the app: pressing and holding the icon,
/// Siri, Shortcuts, Spotlight or the Action Button. Each one just asks the
/// purse to open the right screen once you are signed in.
enum QuickAction: Equatable {
    case addPicture, voiceNote, pinSpot
    case openCoin(String)

    init?(shortcutType: String) {
        switch shortcutType {
        case "addPicture": self = .addPicture
        case "voiceNote": self = .voiceNote
        case "pinSpot": self = .pinSpot
        default: return nil
        }
    }
}

@Observable
final class QuickActions {
    static let shared = QuickActions()
    /// Waiting to be shown; the purse clears it when it does.
    var pending: QuickAction?

    func handle(_ item: UIApplicationShortcutItem) {
        if let action = QuickAction(shortcutType: item.type) { pending = action }
    }
}

// MARK: Home screen quick actions (press and hold the icon)

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        // Launched from a quick action.
        if let item = options.shortcutItem { QuickActions.shared.handle(item) }
        let config = UISceneConfiguration(name: nil, sessionRole: session.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}

final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    // Already running, then a quick action.
    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        QuickActions.shared.handle(shortcutItem)
        completionHandler(true)
    }
}

// MARK: Siri, Shortcuts, Spotlight and the Action Button

struct PinMySpotIntent: AppIntent {
    static let title: LocalizedStringResource = "Pin My Spot"
    static let description = IntentDescription("Opens Coin Purse and drops a pin where you are, like where you parked.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        await MainActor.run { QuickActions.shared.pending = .pinSpot }
        return .result()
    }
}

struct NewVoiceNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "New Voice Note"
    static let description = IntentDescription("Opens Coin Purse ready to turn what you say into a note.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        await MainActor.run { QuickActions.shared.pending = .voiceNote }
        return .result()
    }
}

struct AddPictureIntent: AppIntent {
    static let title: LocalizedStringResource = "Add a Picture Coin"
    static let description = IntentDescription("Opens Coin Purse ready to paste, pick or snap a picture.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        await MainActor.run { QuickActions.shared.pending = .addPicture }
        return .result()
    }
}

/// A coin, as Siri and Shortcuts see it (from the purse saved on this iPhone).
struct CoinEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Coin"
    static let defaultQuery = CoinEntityQuery()

    let id: String
    let title: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }
}

struct CoinEntityQuery: EntityQuery, EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [CoinEntity] {
        SavedPurse.coins().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [CoinEntity] {
        SavedPurse.coins()
    }

    func entities(matching string: String) async throws -> [CoinEntity] {
        SavedPurse.coins().filter { $0.title.localizedStandardContains(string) }
    }
}

struct OpenCoinIntent: AppIntent {
    static let title: LocalizedStringResource = "Show a Coin"
    static let description = IntentDescription("Opens one of your coins, like your parking spot or a ticket.")
    static let openAppWhenRun = true

    @Parameter(title: "Coin")
    var coin: CoinEntity

    func perform() async throws -> some IntentResult {
        let id = coin.id
        await MainActor.run { QuickActions.shared.pending = .openCoin(id) }
        return .result()
    }
}

struct CoinPurseShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PinMySpotIntent(),
                    phrases: ["Pin my spot in \(.applicationName)",
                              "Remember where I parked with \(.applicationName)",
                              "\(.applicationName) pin my spot"],
                    shortTitle: "Pin My Spot",
                    systemImageName: "mappin.and.ellipse")
        AppShortcut(intent: NewVoiceNoteIntent(),
                    phrases: ["New voice note in \(.applicationName)",
                              "Add a note to \(.applicationName)"],
                    shortTitle: "Voice Note",
                    systemImageName: "mic.fill")
        AppShortcut(intent: AddPictureIntent(),
                    phrases: ["Add a picture to \(.applicationName)"],
                    shortTitle: "Add Picture",
                    systemImageName: "camera.fill")
        AppShortcut(intent: OpenCoinIntent(),
                    phrases: ["Show a coin in \(.applicationName)",
                              "Open \(.applicationName)"],
                    shortTitle: "Show a Coin",
                    systemImageName: "rectangle.stack")
    }
}

/// Reads the purse saved on this iPhone, for Siri and Shortcuts.
nonisolated enum SavedPurse {
    static func coins() -> [CoinEntity] {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("purse.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let coins = json["coins"] as? [[String: Any]] else { return [] }
        return coins.compactMap { c in
            guard let id = c["id"] as? String else { return nil }
            return CoinEntity(id: id, title: (c["title"] as? String) ?? "Coin")
        }
    }
}
