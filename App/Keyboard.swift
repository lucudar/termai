import UIKit

/// Puts the keyboard away, whichever field has it.
enum Keyboard {
    @MainActor
    static func hide() {
        _ = UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}
