//
//  ThemeSettingsView.swift
//  Claude Usage
//
//  App-wide theme picker. Each card shows a live preview of the theme: a menu bar strip
//  drawn by the real icon renderer and two usage rows drawn by the real popover views.
//

import SwiftUI

struct ThemeSettingsView: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    private let themes = AppThemeID.allCases

    var body: some View {
        ScrollView {
            content
        }
    }

    /// The page without its scroll view.
    var content: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.section) {
            SettingsPageHeader(
                title: "theme.title".localized,
                subtitle: "theme.subtitle".localized
            )

            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                ForEach(Array(stride(from: 0, to: themes.count, by: 2)), id: \.self) { start in
                    GridRow(alignment: .top) {
                        ForEach(themes[start..<min(start + 2, themes.count)]) { id in
                            ThemePreviewCard(
                                themeID: id,
                                isSelected: themeManager.themeID == id
                            ) {
                                themeManager.select(id)
                            }
                        }
                    }
                }
            }

            Text("theme.footnote".localized)
                .font(DesignTokens.Typography.caption)
                .foregroundColor(.secondary)
        }
        .padding()
    }
}

// MARK: - Preview Card

private struct ThemePreviewCard: View {
    let themeID: AppThemeID
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 8) {
                ThemeMiniPreview(theme: themeID.theme)

                HStack {
                    Text(themeID.displayName)
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(SettingsColors.primary)
                    }
                }

                Text(themeID.summary)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.primary.opacity(isHovered ? 0.07 : 0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        isSelected ? SettingsColors.primary : Color.primary.opacity(0.1),
                        lineWidth: isSelected ? 2 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(themeID.displayName)
        .accessibilityHint(themeID.summary)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Mini Preview

/// A small menu bar strip and two usage rows drawn in `theme`.
private struct ThemeMiniPreview: View {
    let theme: AppTheme

    private static func sampleUsage(session: Double, week: Double) -> ClaudeUsage {
        var usage = ClaudeUsage.empty
        usage.sessionPercentage = session
        usage.weeklyPercentage = week
        usage.sessionResetTime = Date().addingTimeInterval(3 * 60 * 60)
        return usage
    }

    /// One renderer per theme, kept for the life of the app. Freeing a main-actor class
    /// goes through the back-deployed isolated deinit on macOS 14 and 15, which has
    /// aborted the process (seen in CI), so the preview does not create one per redraw.
    private static var renderers: [AppThemeID: MenuBarIconRenderer] = [:]

    private var renderer: MenuBarIconRenderer {
        if let existing = Self.renderers[theme.id] { return existing }
        let created = MenuBarIconRenderer(theme: theme)
        Self.renderers[theme.id] = created
        return created
    }

    private var menuBarIcon: NSImage {
        renderer.createImage(
            for: .session,
            config: MetricIconConfig(metricType: .session, isEnabled: true, iconStyle: .progressBar),
            globalConfig: MenuBarIconConfiguration(showTimeMarker: false, showPaceMarker: false, usePaceColoring: false),
            usage: Self.sampleUsage(session: 62, week: 81),
            apiUsage: nil,
            isDarkMode: true,
            colorMode: .multiColor,
            singleColorHex: "#00BFFF",
            showIconName: true,
            showNextSessionTime: false
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Spacer()
                Image(nsImage: menuBarIcon)
                Text("9:41")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Color(white: 0.1))

            VStack(spacing: 6) {
                UsageRow(
                    title: "menubar.session_usage".localized,
                    subtitle: nil,
                    usedPercentage: 62,
                    showRemaining: false,
                    resetTime: nil,
                    periodDuration: nil
                )
                UsageRow(
                    title: "menubar.all_models".localized,
                    tag: "menubar.weekly".localized,
                    subtitle: nil,
                    usedPercentage: 94,
                    showRemaining: false,
                    resetTime: nil,
                    periodDuration: nil
                )
            }
            .padding(10)
            .background(ThemedPanelBackground())
            .overlay(ThemedPanelBorder())
            .themedPanelClip(theme)
            .environment(\.appTheme, theme)
            .environment(\.colorScheme, theme.forcesDarkAppearance ? .dark : .light)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .allowsHitTesting(false)
    }
}
