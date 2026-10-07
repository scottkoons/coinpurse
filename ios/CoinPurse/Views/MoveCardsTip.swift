import SwiftUI
import TipKit

/// Shown once in the purse when it has a few coins, the way iOS teaches a
/// gesture: how to move cards, with a button for the Rearrange list.
struct MoveCardsTip: Tip {
    @Parameter static var coinCount: Int = 0

    var title: Text { Text("Move your coins") }
    var message: Text? { Text("Touch and hold a card, then drag it up or down.") }
    var image: Image? { Image(systemName: "hand.point.up.left") }
    var actions: [Action] { [Action(id: "rearrange", title: "Rearrange")] }
    var rules: [Rule] { [#Rule(Self.$coinCount) { $0 >= 3 }] }
}
