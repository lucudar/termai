import SwiftUI
import TermCore

@main
struct TermAIApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            TerminalView()
                .environment(model)
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }
}

/// SwiftUI colours and fonts for the active theme.
struct Palette {
    let theme: Theme
    let fontSize: Double

    var background: Color { Color(hex: theme.background) }
    var text: Color { Color(hex: theme.text) }
    var dim: Color { Color(hex: theme.dim) }
    var accent: Color { Color(hex: theme.accent) }
    var error: Color { Color(hex: theme.error) }
    var success: Color { Color(hex: theme.success) }
    var code: Color { Color(hex: theme.codeBackground) }
    var sidebar: Color { Color(hex: theme.sidebar ?? theme.codeBackground) }

    /// Terminal themes are monospaced throughout; the desktop theme only for code and tool output.
    var monospaced: Bool { theme.monospacedUI }
    private var design: Font.Design { monospaced ? .monospaced : .default }

    var font: Font { .system(size: fontSize, design: design) }
    var small: Font { .system(size: max(fontSize - 2, 9), design: design) }
    var bold: Font { .system(size: fontSize, weight: .semibold, design: design) }
    /// Code, diffs and tool output.
    var mono: Font { monospaced ? font : .system(size: max(fontSize - 2, 9), design: .monospaced) }
    var monoSmall: Font { monospaced ? small : .system(size: max(fontSize - 3, 9), design: .monospaced) }
    /// The chips and menus around the input.
    var chip: Font { .system(size: 13, design: design) }
    var title: Font { monospaced ? bold : .system(size: 16, weight: .semibold) }
    var greeting: Font { monospaced ? .system(size: 24, weight: .semibold, design: .monospaced) : .system(size: 30, design: .serif) }
}
