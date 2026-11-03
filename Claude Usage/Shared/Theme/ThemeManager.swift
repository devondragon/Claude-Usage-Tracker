//
//  ThemeManager.swift
//  Claude Usage
//
//  Holds the selected theme (app-wide, not per profile) and persists it.
//

import SwiftUI
import Combine

final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    @Published private(set) var themeID: AppThemeID

    private let store: SharedDataStore

    var current: AppTheme { themeID.theme }

    init(store: SharedDataStore = .shared) {
        self.store = store
        self.themeID = store.loadAppTheme()
    }

    /// Selects a theme, saves it, and redraws the menu bar icons.
    func select(_ id: AppThemeID) {
        guard id != themeID else { return }
        themeID = id
        store.saveAppTheme(id)
        LoggingService.shared.log("ThemeManager: theme set to \(id.rawValue)")
        // Theme colors, fonts, and bar shapes are part of the icon's styling.
        NotificationCenter.default.post(name: .menuBarIconConfigChanged, object: nil)
    }
}

// MARK: - Environment

private struct AppThemeKey: EnvironmentKey {
    static let defaultValue: AppTheme = .system
}

extension EnvironmentValues {
    var appTheme: AppTheme {
        get { self[AppThemeKey.self] }
        set { self[AppThemeKey.self] = newValue }
    }
}
