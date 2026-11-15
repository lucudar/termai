import SwiftUI

// Liquid Glass (iOS 26) for the controls that float over content, with a material fallback on older iOS.
// Glass is for the navigation and control layer only; transcript content stays solid.

@available(iOS 26.0, *)
func makeGlass(tint: Color?, interactive: Bool) -> Glass {
    var glass = Glass.regular
    if let tint { glass = glass.tint(tint) }
    if interactive { glass = glass.interactive() }
    return glass
}

extension View {
    /// Liquid Glass in `shape` on iOS 26; a thin material with a hairline edge before that.
    @ViewBuilder
    func liquidGlass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(makeGlass(tint: tint, interactive: interactive), in: shape)
        } else {
            self
                .background(.ultraThinMaterial, in: shape)
                .background((tint ?? .clear).opacity(0.5), in: shape)
                .overlay(shape.stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
        }
    }

    /// The glass button style on iOS 26, bordered before that.
    @ViewBuilder
    func glassButton(prominent: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            if prominent {
                self.buttonStyle(.glassProminent)
            } else {
                self.buttonStyle(.glass)
            }
        } else {
            if prominent {
                self.buttonStyle(.borderedProminent)
            } else {
                self.buttonStyle(.bordered)
            }
        }
    }

    /// A round prominent button in `color`: send, run, stop.
    func roundProminent(_ color: Color) -> some View {
        glassButton(prominent: true)
            .buttonBorderShape(.circle)
            .tint(color)
    }

    /// The tab bar shrinks while the content scrolls down (iOS 26).
    @ViewBuilder
    func minimizingTabBar() -> some View {
        if #available(iOS 26.0, *) {
            self.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
    }

    /// Content fades softly under the bars instead of cutting off (iOS 26).
    @ViewBuilder
    func softScrollEdge() -> some View {
        if #available(iOS 26.0, *) {
            self.scrollEdgeEffectStyle(.soft, for: .all)
        } else {
            self
        }
    }
}

/// Groups nearby glass shapes so they blend and render together (GlassEffectContainer on iOS 26).
struct GlassGroup<Content: View>: View {
    let spacing: CGFloat?
    let content: Content

    init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
    }
}

/// The theme background with two soft accent glows, so the glass over it has something to refract.
struct Backdrop: View {
    let palette: Palette

    var body: some View {
        ZStack {
            palette.background
            RadialGradient(colors: [palette.accent.opacity(palette.monospaced ? 0.10 : 0.20), .clear],
                           center: .topLeading, startRadius: 0, endRadius: 460)
            RadialGradient(colors: [palette.accent.opacity(palette.monospaced ? 0.06 : 0.12), .clear],
                           center: .bottomTrailing, startRadius: 0, endRadius: 420)
        }
        .ignoresSafeArea()
    }
}
