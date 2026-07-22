import SwiftUI
import UIKit

/// Design tokens for the "Warm brass" identity (handoff direction 1a): warm
/// neutrals, a single brass accent, an elegant display serif. These are the
/// signature of the redesign — deliberately fixed colours (not semantic
/// system colours), so the paper-and-brass look holds regardless of the
/// device's light/dark setting.
enum Theme {
    // MARK: Colours
    // "Warm brass" in both appearances: warm paper by day, warm near-black by
    // night. Every token adapts to the active light/dark trait.
    static let bg         = Color(light: 0xF4F1EA, dark: 0x18150F)  // page background
    static let card       = Color(light: 0xFFFDF8, dark: 0x232019)  // surfaces / pills / tab bar
    static let ink        = Color(light: 0x201D18, dark: 0xF1EBE1)  // primary text
    static let sub        = Color(light: 0x8C857A, dark: 0xA69C8C)  // secondary text
    static let line       = Color(light: 0xE7E1D5, dark: 0x38322A)  // hairline borders / dividers
    static let accent     = Color(light: 0xA87D2E, dark: 0xC99A4C)  // replaces iOS blue
    static let accentSoft = Color(light: 0xECE2CC, dark: 0x3A3223)  // ring track / soft fills
    static let success    = Color(light: 0x3F9D5A, dark: 0x54B26E)  // goal met / connected dot
    static let warn       = Color(light: 0xC98A2E, dark: 0xD89A3E)  // low battery / bt off
    static let danger     = Color(light: 0xC0492E, dark: 0xD75C40)  // critical battery

    // Secondary tokens (soft fills, controls, chips) — also adaptive.
    static let softFill       = Color(light: 0xF0ECE2, dark: 0x2C2820)  // icon tiles / steppers / segmented track
    static let toggleOff       = Color(light: 0xDDD6C8, dark: 0x3E382E)  // BrassToggle off
    static let chevron         = Color(light: 0xC1B8A6, dark: 0x6B6455)  // navigable-row chevron
    static let dayChipOff      = Color(light: 0xEFE9DC, dark: 0x2E2A22)  // inactive day chip fill
    static let dayChipOffText  = Color(light: 0xB3AA98, dark: 0x7A7263)  // inactive day chip glyph
    static let warnSoft        = Color(light: 0xF7ECDF, dark: 0x3A2E1E)  // warn-tinted icon tile
    static let dashedStroke    = Color(light: 0xC7BDA8, dark: 0x4E463A)  // dashed "create" outlines
    static let barMid          = Color(light: 0xC9B485, dark: 0x7C6C46)  // steps chart, mid bars
    static let barLow          = Color(light: 0xE2D7C0, dark: 0x463E2E)  // steps chart, low bars

    // MARK: Fonts
    // Bundled OFL fonts (see project.yml UIAppFonts). `.custom` falls back to
    // the system font if a face somehow fails to register, so the screen
    // never renders blank.

    /// Instrument Serif — display titles and section headers. Scales with
    /// Dynamic Type against `relativeTo` (custom fonts need this explicitly —
    /// unlike `.system(size:)`, plain `.custom(_:size:)` does not auto-scale).
    static func serif(_ size: CGFloat, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom("InstrumentSerif-Regular", size: size, relativeTo: style)
    }

    /// IBM Plex Mono — all numerals, metrics and codes (tabular). Scales with
    /// Dynamic Type against `relativeTo`.
    static func mono(_ size: CGFloat, weight: Font.Weight = .medium,
                     relativeTo style: Font.TextStyle = .body) -> Font {
        let name: String
        switch weight {
        case .semibold, .bold: name = "IBMPlexMono-SemiBold"
        case .medium:          name = "IBMPlexMono-Medium"
        default:               name = "IBMPlexMono-Regular"
        }
        return .custom(name, size: size, relativeTo: style)
    }

    /// System font that scales with Dynamic Type against `relativeTo` — unlike
    /// `.font(.system(size:))`, which is fixed regardless of the user's text
    /// size setting.
    static func sans(_ size: CGFloat, weight: Font.Weight = .regular,
                     relativeTo style: Font.TextStyle = .body) -> Font {
        let uiWeight: UIFont.Weight
        switch weight {
        case .bold: uiWeight = .bold
        case .semibold: uiWeight = .semibold
        case .medium: uiWeight = .medium
        case .light: uiWeight = .light
        default: uiWeight = .regular
        }
        let base = UIFont.systemFont(ofSize: size, weight: uiWeight)
        let scaled = UIFontMetrics(forTextStyle: style.uiKit).scaledFont(for: base)
        return Font(scaled)
    }

    // Shadows (colour + radius + offset) matching the handoff.
    static let cardShadow   = ShadowStyle(color: .black.opacity(0.05), radius: 11, y: 6)
    static let tabBarShadow = ShadowStyle(color: .black.opacity(0.06), radius: 10, y: 4)
    static let heroShadow   = ShadowStyle(color: .black.opacity(0.10), radius: 10, y: 12)

    struct ShadowStyle {
        let color: Color
        let radius: CGFloat
        var x: CGFloat = 0
        var y: CGFloat = 0
    }

    // MARK: Global UIKit appearance

    /// Themes the stock `Form`/`List` detail sub-screens (reached via chevrons,
    /// not part of the handoff mocks) in one place: warm nav bars with the
    /// display serif, brass bar buttons, warm list backgrounds and green
    /// switches — so they belong to the same identity without a per-control
    /// rewrite. Called once at launch.
    static func configureAppearance() {
        let ink = UIColor(ink)
        let serifLarge = UIFont(name: "InstrumentSerif-Regular", size: 34)
            ?? .systemFont(ofSize: 34, weight: .regular)
        let serifInline = UIFont(name: "InstrumentSerif-Regular", size: 19)
            ?? .systemFont(ofSize: 19, weight: .semibold)

        let bar = UINavigationBarAppearance()
        bar.configureWithOpaqueBackground()
        bar.backgroundColor = UIColor(bg)
        bar.shadowColor = .clear
        bar.largeTitleTextAttributes = [.font: serifLarge, .foregroundColor: ink]
        bar.titleTextAttributes = [.font: serifInline, .foregroundColor: ink]
        UINavigationBar.appearance().standardAppearance = bar
        UINavigationBar.appearance().scrollEdgeAppearance = bar
        UINavigationBar.appearance().compactAppearance = bar
        UINavigationBar.appearance().tintColor = UIColor(accent)

        // List/Form scroll backgrounds (both are UICollectionView-backed).
        UICollectionView.appearance().backgroundColor = UIColor(bg)
        UITableView.appearance().backgroundColor = UIColor(bg)

        // All toggles read green when on, matching the redesign's BrassToggle.
        UISwitch.appearance().onTintColor = UIColor(success)
    }
}

extension View {
    func themeShadow(_ s: Theme.ShadowStyle) -> some View {
        shadow(color: s.color, radius: s.radius, x: s.x, y: s.y)
    }
}

private extension Font.TextStyle {
    /// `UIFontMetrics` wants the UIKit text-style enum, not SwiftUI's.
    var uiKit: UIFont.TextStyle {
        switch self {
        case .largeTitle: return .largeTitle
        case .title: return .title1
        case .title2: return .title2
        case .title3: return .title3
        case .headline: return .headline
        case .subheadline: return .subheadline
        case .callout: return .callout
        case .footnote: return .footnote
        case .caption: return .caption1
        case .caption2: return .caption2
        default: return .body
        }
    }
}

extension Color {
    /// 0xRRGGBB literal.
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue:  Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }

    /// Pack the colour's resolved sRGB components into a 0x00RRGGBB value.
    var rgbHex: UInt32 {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        let clamp = { (v: CGFloat) -> UInt32 in UInt32((min(max(v, 0), 1) * 255).rounded()) }
        return (clamp(r) << 16) | (clamp(g) << 8) | clamp(b)
    }

    /// A colour that resolves to `light` or `dark` per the active appearance.
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { trait in
            UIColor(hex: trait.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

extension UIColor {
    /// 0xRRGGBB literal.
    convenience init(hex: UInt32) {
        self.init(
            red:   CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue:  CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
