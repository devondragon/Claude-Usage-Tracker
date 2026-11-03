import XCTest
import AppKit
@testable import Claude_Usage

final class ThemeTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: SharedDataStore!

    override func setUp() {
        super.setUp()
        suiteName = "ThemeTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = SharedDataStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Persistence

    func testRawValuesAreStable() {
        // Raw values are persisted; renaming one silently resets users to System.
        XCTAssertEqual(AppThemeID.allCases.map(\.rawValue), ["system", "grid", "nightCity", "phosphor"])
    }

    func testDefaultsToSystemWhenNothingSaved() {
        XCTAssertEqual(store.loadAppTheme(), .system)
    }

    func testSaveAndLoadRoundTrip() {
        for id in AppThemeID.allCases {
            store.saveAppTheme(id)
            XCTAssertEqual(store.loadAppTheme(), id)
        }
    }

    func testUnknownSavedValueFallsBackToSystem() {
        defaults.set("tron-classic", forKey: "appTheme")
        XCTAssertEqual(store.loadAppTheme(), .system)
    }

    // MARK: - ThemeManager

    func testSelectPersistsAndRequestsIconRedraw() {
        let manager = ThemeManager(store: store)
        XCTAssertEqual(manager.themeID, .system)

        let redraw = expectation(forNotification: .menuBarIconConfigChanged, object: nil)
        manager.select(.nightCity)
        wait(for: [redraw], timeout: 1)

        XCTAssertEqual(manager.themeID, .nightCity)
        XCTAssertEqual(manager.current.id, .nightCity)
        XCTAssertEqual(store.loadAppTheme(), .nightCity)
        XCTAssertEqual(ThemeManager(store: store).themeID, .nightCity, "a new manager reads the saved theme")
    }

    func testSelectingCurrentThemeDoesNotRedraw() {
        let manager = ThemeManager(store: store)
        let redraw = expectation(forNotification: .menuBarIconConfigChanged, object: nil)
        redraw.isInverted = true
        manager.select(.system)
        wait(for: [redraw], timeout: 0.3)
    }

    // MARK: - Fonts

    func testBundledFontsArePresentAndRegister() {
        for name in ThemeFontRegistrar.fontFiles {
            XCTAssertNotNil(Bundle.main.url(forResource: name, withExtension: "ttf"), "\(name).ttf missing from the app bundle")
        }
        ThemeFontRegistrar.registerIfNeeded()
        for name in ThemeFontRegistrar.fontFiles {
            XCTAssertNotNil(NSFont(name: name, size: 12), "\(name) did not register")
        }
    }

    func testFamiliesResolveToBundledFaces() {
        let cases: [(ThemeFontFamily, NSFont.Weight, String)] = [
            (.orbitron, .regular, "Orbitron-Regular"),
            (.orbitron, .medium, "Orbitron-Medium"),
            (.orbitron, .bold, "Orbitron-Bold"),
            (.exo2, .regular, "Exo2-Regular"),
            (.exo2, .semibold, "Exo2-Medium"),
            (.rajdhani, .regular, "Rajdhani-Medium"),
            (.rajdhani, .semibold, "Rajdhani-SemiBold"),
            (.rajdhani, .heavy, "Rajdhani-Bold"),
            (.shareTechMono, .bold, "ShareTechMono-Regular"),
            (.vt323, .medium, "VT323-Regular"),
        ]
        for (family, weight, expected) in cases {
            XCTAssertEqual(family.nsFont(size: 12, weight: weight).fontName, expected, "\(family) \(weight)")
        }
    }

    func testSystemFamilyIsTheSystemFont() {
        let font = ThemeFontFamily.system.nsFont(size: 13, weight: .bold)
        XCTAssertEqual(font, NSFont.systemFont(ofSize: 13, weight: .bold))
    }

    // MARK: - System Theme Matches the Pre-Theme Look

    func testSystemThemeMenuBarColorsAreUnchanged() {
        let theme = AppTheme.system
        for dark in [true, false] {
            XCTAssertEqual(theme.menuBarStatusColor(.safe, isDarkMode: dark), .systemGreen)
            XCTAssertEqual(theme.menuBarStatusColor(.moderate, isDarkMode: dark), .systemOrange)
            XCTAssertEqual(theme.menuBarStatusColor(.critical, isDarkMode: dark), .systemRed)
        }
        XCTAssertEqual(theme.menuBarForeground(isDarkMode: true), .white)
        XCTAssertEqual(theme.menuBarForeground(isDarkMode: false), .black)
        XCTAssertTrue(theme.allowsTemplateImages)
        XCTAssertEqual(theme.background, .vibrancy)
        XCTAssertEqual(theme.barStyle, .rounded)
        XCTAssertEqual(theme.openAnimation, .standard)
        XCTAssertEqual(theme.criticalEffect, .none)
        XCTAssertFalse(theme.uppercaseLabels)
    }

    func testThemedThemesKeepTheirOwnColors() {
        for id in AppThemeID.allCases where id != .system {
            let theme = id.theme
            XCTAssertFalse(theme.allowsTemplateImages, "\(id) monochrome icons must keep the theme color")
            XCTAssertTrue(theme.forcesDarkAppearance, "\(id) draws a dark panel")
            XCTAssertNotEqual(theme.menuBarStatusColor(.safe, isDarkMode: true),
                              theme.menuBarStatusColor(.critical, isDarkMode: true),
                              "\(id) safe and critical must differ")
            XCTAssertNotEqual(theme.menuBarStatusColor(.critical, isDarkMode: true),
                              theme.menuBarStatusColor(.critical, isDarkMode: false),
                              "\(id) needs a separate critical color for a light menu bar")
        }
    }

    func testLabelCapitalization() {
        XCTAssertEqual(AppTheme.system.label("Session Usage"), "Session Usage")
        XCTAssertEqual(AppTheme.grid.label("Session Usage"), "SESSION USAGE")
    }

    // MARK: - Rendering

    func testEveryThemeRendersEveryIconStyle() {
        var usage = ClaudeUsage.empty
        usage.sessionPercentage = 94
        usage.weeklyPercentage = 40
        for id in AppThemeID.allCases {
            let renderer = MenuBarIconRenderer(theme: id.theme)
            for style in MenuBarIconStyle.allCases {
                for dark in [true, false] {
                    let image = renderer.createImage(
                        for: .session,
                        config: MetricIconConfig(metricType: .session, isEnabled: true, iconStyle: style),
                        globalConfig: MenuBarIconConfiguration(),
                        usage: usage,
                        apiUsage: nil,
                        isDarkMode: dark,
                        colorMode: .multiColor,
                        singleColorHex: "#00BFFF",
                        showIconName: true,
                        showNextSessionTime: false
                    )
                    XCTAssertGreaterThan(image.size.width, 0, "\(id) \(style)")
                    XCTAssertGreaterThan(image.size.height, 0, "\(id) \(style)")
                }
            }
        }
    }

    // MARK: - Animation Helpers

    func testGlitchIsQuietMostOfTheCycle() {
        let base = Date(timeIntervalSinceReferenceDate: 0)
        XCTAssertEqual(GlitchClock.frame(at: base.addingTimeInterval(1.0)).offset, 0)
        XCTAssertEqual(GlitchClock.frame(at: base.addingTimeInterval(1.0)).split, 0)
        let burst = GlitchClock.frame(at: base.addingTimeInterval(GlitchClock.period - 0.33))
        XCTAssertNotEqual(burst.split, 0)
    }

    func testEntranceCurvesEndAtRest() {
        XCTAssertEqual(ThemedEntrance.tubeHeight(1), 1, accuracy: 0.0001)
        XCTAssertEqual(ThemedEntrance.tubeHeight(0), 0.01, accuracy: 0.0001)
        XCTAssertEqual(ThemedEntrance.stepped(1, steps: 6), 1)
        XCTAssertEqual(ThemedEntrance.stepped(0.5, steps: 6), 0.5)
        XCTAssertEqual(ThemedEntrance.flicker(1), 1)
    }
}
