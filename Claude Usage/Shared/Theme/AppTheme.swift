//
//  AppTheme.swift
//  Claude Usage
//
//  Visual themes for the menu bar icons and the popover. A theme is a palette plus a set
//  of style choices (bar shape, fonts, glow, overlays, animations). Views read the active
//  theme from the SwiftUI environment; the menu bar renderer reads it from ThemeManager.
//

import SwiftUI
import AppKit

// MARK: - Theme Identifier

/// Persisted identifier for a theme. Raw values are stored in UserDefaults: never rename them.
enum AppThemeID: String, CaseIterable, Identifiable {
    case system
    case grid
    case nightCity
    case phosphor

    var id: String { rawValue }

    var theme: AppTheme {
        switch self {
        case .system: return .system
        case .grid: return .grid
        case .nightCity: return .nightCity
        case .phosphor: return .phosphor
        }
    }

    var displayName: String {
        switch self {
        case .system: return "theme.name.system".localized
        case .grid: return "theme.name.grid".localized
        case .nightCity: return "theme.name.night_city".localized
        case .phosphor: return "theme.name.phosphor".localized
        }
    }

    var summary: String {
        switch self {
        case .system: return "theme.desc.system".localized
        case .grid: return "theme.desc.grid".localized
        case .nightCity: return "theme.desc.night_city".localized
        case .phosphor: return "theme.desc.phosphor".localized
        }
    }
}

// MARK: - Style Options

extension AppTheme {
    /// How a usage bar's fill is drawn.
    enum BarStyle: Equatable {
        /// Solid rounded fill (the system look).
        case rounded
        /// Fades in from the left to a bright leading edge, inside an outlined track.
        case trail
        /// Fill broken into blocks. `angled` slants both ends of the bar.
        case segmented(segment: CGFloat, gap: CGFloat, angled: Bool)
    }

    enum PanelBackground: Equatable {
        /// The system HUD blur used before themes existed.
        case vibrancy
        case gradient(top: NSColor, bottom: NSColor)
    }

    enum PanelShape: Equatable {
        case standard
        /// Top-right and bottom-left corners cut at 45 degrees.
        case chamfered(cut: CGFloat)
    }

    /// Container drawn around each usage row.
    enum RowStyle: Equatable {
        /// Rounded hairline border (the system look).
        case outlined
        /// Hairline between rows, no box.
        case separated
        /// Colored bar on the leading edge with a faint wash of the status color.
        case leadingAccent
        /// No container.
        case plain
    }

    enum TagStyle: Equatable {
        case capsule
        case outlined
        case block
    }

    enum StatusMarker: Equatable {
        case circle
        case diamond
        case square
        /// Text such as `[OK]` in place of a dot.
        case bracketText
    }

    enum DividerStyle: Equatable {
        case system
        case glowLine
        case hidden
        case dashed
    }

    enum OpenAnimation: Equatable {
        /// Fade and scale down from the top (the original entrance).
        case standard
        /// A light runs around the panel border while the content flickers in.
        case trace
        /// Content is revealed left to right with a short horizontal jitter.
        case wipe
        /// Collapses to a bright line, then expands, like a CRT turning on.
        case powerOn
    }

    /// Extra treatment for a percentage that has reached the critical level.
    enum CriticalEffect: Equatable {
        case none
        case pulse
        case glitch
        case blink
    }
}

// MARK: - Theme

struct AppTheme: Equatable {
    let id: AppThemeID

    // Palette
    let safe: NSColor
    let moderate: NSColor
    let critical: NSColor
    let accent: Color
    let textPrimary: Color
    let textSecondary: Color
    let track: Color
    let rowBorder: Color
    let divider: Color
    let panelBorder: Color?
    /// Fill behind the header row. Nil leaves the panel background showing.
    let headerBand: Color?
    /// Text and icon color on top of `headerBand`.
    let headerText: Color?
    let background: PanelBackground
    /// Themes with their own dark panel force the popover into Dark Aqua so system
    /// controls (menus, spinners) draw light-on-dark.
    let forcesDarkAppearance: Bool

    // Typography
    let titleFont: ThemeFontFamily
    let bodyFont: ThemeFontFamily
    let numberFont: ThemeFontFamily
    let detailFont: ThemeFontFamily
    let uppercaseLabels: Bool
    let titleTracking: CGFloat
    /// Decorative prefix before usage row titles, such as "SYS//".
    let titlePrefix: String?
    /// Decorative prefix before the profile name, such as "> ".
    let profilePrefix: String?

    // Shapes and effects
    let barStyle: BarStyle
    let barHeight: CGFloat
    let panelShape: PanelShape
    let rowStyle: RowStyle
    let tagStyle: TagStyle
    let statusMarker: StatusMarker
    let dividerStyle: DividerStyle
    let glow: Bool
    let scanlines: Bool
    let perspectiveGrid: Bool
    /// Shows a one-line status readout under the header.
    let showsReadout: Bool
    /// Shows a blinking block cursor after the profile name.
    let showsCursor: Bool
    let openAnimation: OpenAnimation
    let criticalEffect: CriticalEffect

    // Menu bar
    /// Status colors for a light menu bar, where the dark-panel colors are too pale.
    let lightMenuBarSafe: NSColor
    let lightMenuBarModerate: NSColor
    let lightMenuBarCritical: NSColor
    let menuBarForegroundDark: NSColor
    let menuBarForegroundLight: NSColor
    let menuBarGlow: Bool
    /// Only the system theme lets monochrome icons become template images that macOS
    /// tints; a themed monochrome icon keeps the theme's foreground color.
    let allowsTemplateImages: Bool

    static func == (lhs: AppTheme, rhs: AppTheme) -> Bool { lhs.id == rhs.id }
}

// MARK: - Status Colors

extension AppTheme {
    func statusNSColor(_ level: UsageStatusLevel) -> NSColor {
        switch level {
        case .safe: return safe
        case .moderate: return moderate
        case .critical: return critical
        }
    }

    func statusColor(_ level: UsageStatusLevel) -> Color {
        Color(nsColor: statusNSColor(level))
    }

    func menuBarStatusColor(_ level: UsageStatusLevel, isDarkMode: Bool) -> NSColor {
        if isDarkMode { return menuBarDarkStatusColor(level) }
        switch level {
        case .safe: return lightMenuBarSafe
        case .moderate: return lightMenuBarModerate
        case .critical: return lightMenuBarCritical
        }
    }

    private func menuBarDarkStatusColor(_ level: UsageStatusLevel) -> NSColor {
        // The system theme keeps the exact colors the renderer used before themes.
        guard id == .system else { return statusNSColor(level) }
        switch level {
        case .safe: return .systemGreen
        case .moderate: return .systemOrange
        case .critical: return .systemRed
        }
    }

    func menuBarForeground(isDarkMode: Bool) -> NSColor {
        isDarkMode ? menuBarForegroundDark : menuBarForegroundLight
    }

    /// Color for the claude.ai status indicator in the header.
    func serviceStatusColor(_ color: ClaudeStatus.StatusColor) -> Color {
        if id == .system {
            switch color {
            case .green: return .adaptiveGreen
            case .yellow: return .yellow
            case .orange: return .orange
            case .red: return .red
            case .gray: return .gray
            }
        }
        switch color {
        case .green: return Color(nsColor: safe)
        case .yellow, .orange: return Color(nsColor: moderate)
        case .red: return Color(nsColor: critical)
        case .gray: return textSecondary
        }
    }

    /// Applies the theme's capitalization to a label.
    func label(_ text: String) -> String {
        uppercaseLabels ? text.uppercased() : text
    }
}

// MARK: - Built-in Themes

private func hex(_ value: String) -> NSColor {
    NSColor(hex: value) ?? .magenta
}

extension AppTheme {
    /// The original look: HUD blur, system colors, SF Pro. Matches the app before themes.
    static let system = AppTheme(
        id: .system,
        safe: .adaptiveGreen,
        moderate: .systemOrange,
        critical: .systemRed,
        accent: .accentColor,
        textPrimary: .primary,
        textSecondary: .secondary,
        track: Color.primary.opacity(0.08),
        rowBorder: Color.primary.opacity(0.1),
        divider: Color.primary.opacity(0.1),
        panelBorder: nil,
        headerBand: nil,
        headerText: nil,
        background: .vibrancy,
        forcesDarkAppearance: false,
        titleFont: .system,
        bodyFont: .system,
        numberFont: .systemRounded,
        detailFont: .system,
        uppercaseLabels: false,
        titleTracking: 0,
        titlePrefix: nil,
        profilePrefix: nil,
        barStyle: .rounded,
        barHeight: 4,
        panelShape: .standard,
        rowStyle: .outlined,
        tagStyle: .capsule,
        statusMarker: .circle,
        dividerStyle: .system,
        glow: false,
        scanlines: false,
        perspectiveGrid: false,
        showsReadout: false,
        showsCursor: false,
        openAnimation: .standard,
        criticalEffect: .none,
        lightMenuBarSafe: .systemGreen,
        lightMenuBarModerate: .systemOrange,
        lightMenuBarCritical: .systemRed,
        menuBarForegroundDark: .white,
        menuBarForegroundLight: .black,
        menuBarGlow: false,
        allowsTemplateImages: true
    )

    /// Tron Legacy style: black glass, cyan light lines, orange for critical.
    static let grid = AppTheme(
        id: .grid,
        safe: hex("#6FE3FF"),
        moderate: hex("#FFD38A"),
        critical: hex("#FF8A1F"),
        accent: Color(nsColor: hex("#6FE3FF")),
        textPrimary: Color(nsColor: hex("#E4FBFF")),
        textSecondary: Color(nsColor: hex("#6F9BA8")),
        track: Color(nsColor: hex("#6FE3FF")).opacity(0.05),
        rowBorder: Color(nsColor: hex("#6FE3FF")).opacity(0.14),
        divider: Color(nsColor: hex("#6FE3FF")),
        panelBorder: Color(nsColor: hex("#6FE3FF")).opacity(0.55),
        headerBand: nil,
        headerText: nil,
        background: .gradient(top: hex("#050B10"), bottom: hex("#03060A")),
        forcesDarkAppearance: true,
        titleFont: .orbitron,
        bodyFont: .exo2,
        numberFont: .orbitron,
        detailFont: .exo2,
        uppercaseLabels: true,
        titleTracking: 1.8,
        titlePrefix: nil,
        profilePrefix: nil,
        barStyle: .trail,
        barHeight: 6,
        panelShape: .standard,
        rowStyle: .separated,
        tagStyle: .outlined,
        statusMarker: .diamond,
        dividerStyle: .glowLine,
        glow: true,
        scanlines: false,
        perspectiveGrid: true,
        showsReadout: false,
        showsCursor: false,
        openAnimation: .trace,
        criticalEffect: .pulse,
        lightMenuBarSafe: hex("#0086A8"),
        lightMenuBarModerate: hex("#9A6A00"),
        lightMenuBarCritical: hex("#C25400"),
        menuBarForegroundDark: hex("#DFFAFF"),
        menuBarForegroundLight: hex("#005F78"),
        menuBarGlow: true,
        allowsTemplateImages: false
    )

    /// Cyberpunk 2077 style: yellow header band, cut corners, segmented angled bars.
    static let nightCity = AppTheme(
        id: .nightCity,
        safe: hex("#02D7F2"),
        moderate: hex("#FCEE0A"),
        critical: hex("#FF003C"),
        accent: Color(nsColor: hex("#02D7F2")),
        textPrimary: Color(nsColor: hex("#F0F0F0")),
        textSecondary: Color(nsColor: hex("#7D8189")),
        track: Color.white.opacity(0.08),
        rowBorder: Color.white.opacity(0.08),
        divider: Color.white.opacity(0.08),
        panelBorder: Color(nsColor: hex("#FCEE0A")),
        headerBand: Color(nsColor: hex("#FCEE0A")),
        headerText: Color(nsColor: hex("#0B0C12")),
        background: .gradient(top: hex("#0B0C12"), bottom: hex("#0B0C12")),
        forcesDarkAppearance: true,
        titleFont: .rajdhani,
        bodyFont: .rajdhani,
        numberFont: .rajdhani,
        detailFont: .shareTechMono,
        uppercaseLabels: true,
        titleTracking: 1,
        titlePrefix: "SYS//",
        profilePrefix: "// ",
        barStyle: .segmented(segment: 5, gap: 2, angled: true),
        barHeight: 7,
        panelShape: .chamfered(cut: 16),
        rowStyle: .leadingAccent,
        tagStyle: .block,
        statusMarker: .square,
        dividerStyle: .hidden,
        glow: false,
        scanlines: true,
        perspectiveGrid: false,
        showsReadout: true,
        showsCursor: false,
        openAnimation: .wipe,
        criticalEffect: .glitch,
        lightMenuBarSafe: hex("#007F91"),
        lightMenuBarModerate: hex("#8A7F00"),
        lightMenuBarCritical: hex("#C4002E"),
        menuBarForegroundDark: hex("#FCEE0A"),
        menuBarForegroundLight: hex("#0B0C12"),
        menuBarGlow: false,
        allowsTemplateImages: false
    )

    /// Amber CRT terminal: one color, scanlines, block bars.
    static let phosphor = AppTheme(
        id: .phosphor,
        safe: hex("#FFB000"),
        moderate: hex("#FFC94A"),
        critical: hex("#FFE08A"),
        accent: Color(nsColor: hex("#FFB000")),
        textPrimary: Color(nsColor: hex("#FFB000")),
        textSecondary: Color(nsColor: hex("#FFB000")).opacity(0.6),
        track: Color(nsColor: hex("#FFB000")).opacity(0.12),
        rowBorder: Color(nsColor: hex("#FFB000")).opacity(0.3),
        divider: Color(nsColor: hex("#FFB000")).opacity(0.45),
        panelBorder: Color(nsColor: hex("#2D2107")),
        headerBand: nil,
        headerText: nil,
        background: .gradient(top: hex("#1C1405"), bottom: hex("#0B0702")),
        forcesDarkAppearance: true,
        titleFont: .vt323,
        bodyFont: .vt323,
        numberFont: .vt323,
        detailFont: .vt323,
        uppercaseLabels: true,
        titleTracking: 0.4,
        titlePrefix: nil,
        profilePrefix: "> ",
        barStyle: .segmented(segment: 7, gap: 2, angled: false),
        barHeight: 9,
        panelShape: .standard,
        rowStyle: .plain,
        tagStyle: .outlined,
        statusMarker: .bracketText,
        dividerStyle: .dashed,
        glow: true,
        scanlines: true,
        perspectiveGrid: false,
        showsReadout: false,
        showsCursor: true,
        openAnimation: .powerOn,
        criticalEffect: .blink,
        lightMenuBarSafe: hex("#7A4F00"),
        lightMenuBarModerate: hex("#8F5A00"),
        lightMenuBarCritical: hex("#A33A00"),
        menuBarForegroundDark: hex("#FFB000"),
        menuBarForegroundLight: hex("#7A4F00"),
        menuBarGlow: true,
        allowsTemplateImages: false
    )
}
