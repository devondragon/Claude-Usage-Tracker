import SwiftUI
import Charts

// MARK: - Always-active vibrancy background
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let container = NSView()

        // Base vibrancy layer
        let effectView = NSVisualEffectView()
        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.isEmphasized = true
        effectView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(effectView)

        // Solid tint overlay for more density
        let tintView = NSView()
        tintView.wantsLayer = true
        if NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            tintView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.25).cgColor
        } else {
            tintView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.4).cgColor
        }
        tintView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(tintView)

        NSLayoutConstraint.activate([
            effectView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            effectView.topAnchor.constraint(equalTo: container.topAnchor),
            effectView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            tintView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tintView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tintView.topAnchor.constraint(equalTo: container.topAnchor),
            tintView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Update tint for appearance changes
        if let tintView = nsView.subviews.last {
            tintView.wantsLayer = true
            if NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                tintView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.25).cgColor
            } else {
                tintView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.4).cgColor
            }
        }
    }
}

/// Native macOS popover interface - minimal, flat, system-style
struct PopoverContentView: View {
    @ObservedObject var manager: MenuBarManager
    let onRefresh: () -> Void
    let onPreferences: () -> Void

    @State private var isRefreshing = false
    @State private var showInsights = false
    // Drives a custom entrance animation. The native NSPopover open animation is
    // disabled (see MenuBarManager) because its animated window resize recurses
    // infinitely on macOS 26/27; this fades/scales the content in from the top
    // instead — a pure SwiftUI transform on a fixed-size view, so it can't trigger
    // the window-resize loop.
    // 0 → 1 drives the theme's entrance animation (ThemedEntrance).
    @State private var openProgress: CGFloat = 0

    @StateObject private var profileManager = ProfileManager.shared
    @ObservedObject private var themeManager = ThemeManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func profileInitials(for name: String) -> String {
        let words = name.split(separator: " ")
        if words.count >= 2 {
            return String(words[0].prefix(1) + words[1].prefix(1)).uppercased()
        } else if let first = words.first {
            return String(first.prefix(2)).uppercased()
        }
        return "?"
    }

    // Computed properties for multi-profile mode support
    private var displayUsage: ClaudeUsage {
        manager.clickedProfileUsage ?? manager.usage
    }

    private var displayAPIUsage: APIUsage? {
        // When viewing a non-active profile, use only that profile's API data
        // to avoid leaking the active profile's console data
        if manager.clickedProfileUsage != nil {
            return manager.clickedProfileAPIUsage
        }
        return manager.apiUsage
    }

    /// Provider of the profile being viewed (clicked profile in multi-profile
    /// mode, else the active profile).
    private var displayProvider: Provider {
        let viewingProfile = manager.clickedProfileId.flatMap { id in
            profileManager.profiles.first(where: { $0.id == id })
        } ?? profileManager.activeProfile
        return viewingProfile?.provider ?? .anthropic
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            SmartHeader(
                usage: displayUsage,
                status: manager.status,
                isRefreshing: isRefreshing,
                onRefresh: {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        isRefreshing = true
                    }
                    onRefresh()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            isRefreshing = false
                        }
                    }
                },
                onManageProfiles: onPreferences,
                onPreferences: onPreferences,
                clickedProfileId: manager.clickedProfileId
            )

            PopoverDivider()

            if themeManager.current.showsReadout {
                ThemedReadout(
                    isHealthy: !manager.hasCredentialError && manager.consecutiveRefreshFailures == 0,
                    lastUpdated: displayUsage.lastUpdated
                )
            }

            // Error / stale data banners
            if manager.hasCredentialError {
                StatusBannerView(
                    icon: "exclamationmark.triangle.fill",
                    message: "popover.banner.credentials_expired".localized,
                    color: .orange
                ) {
                    onPreferences()
                }
            } else if manager.consecutiveRefreshFailures >= 3 {
                StatusBannerView(
                    icon: "arrow.clockwise.circle.fill",
                    message: String(format: "popover.banner.refresh_failed".localized, manager.consecutiveRefreshFailures),
                    color: .yellow
                ) {
                    onRefresh()
                }
            } else if let lastRefresh = manager.lastSuccessfulRefreshTime,
                      Date().timeIntervalSince(lastRefresh) > 300 {
                let minutesAgo = Int(Date().timeIntervalSince(lastRefresh) / 60)
                StatusBannerView(
                    icon: "clock.fill",
                    message: String(format: "popover.banner.updated_ago".localized, minutesAgo),
                    color: .orange
                ) {
                    onRefresh()
                }
            } else if (manager.clickedProfileId.flatMap { id in profileManager.profiles.first { $0.id == id } }
                        ?? profileManager.activeProfile)?.claudeUsage != nil,
                      Date().timeIntervalSince(displayUsage.lastUpdated) > 600 {
                // The refresh ran, but this profile's data is its last stored reading (e.g. a
                // linked Claude Code login whose token expired and has not been refreshed yet).
                StatusBannerView(
                    icon: "clock.fill",
                    message: String(format: "popover.banner.updated_ago".localized,
                                    Int(Date().timeIntervalSince(displayUsage.lastUpdated) / 60)),
                    color: .orange
                ) {
                    onRefresh()
                }
            }

            // Viewing usage tag (shown in multi-profile mode)
            if profileManager.displayMode == .multi,
               let viewingProfile = manager.clickedProfileId.flatMap({ id in
                   profileManager.profiles.first(where: { $0.id == id })
               }) ?? profileManager.activeProfile {
                HStack(spacing: 8) {
                    // Profile initials avatar
                    ZStack {
                        Circle()
                            .fill(themeManager.current.accent.opacity(0.15))
                            .frame(width: 20, height: 20)
                        Text(profileInitials(for: viewingProfile.name))
                            .font(themeManager.current.numberFont.font(size: 8, weight: .bold))
                            .foregroundColor(themeManager.current.accent)
                    }

                    Text(themeManager.current.label(viewingProfile.name))
                        .font(themeManager.current.bodyFont.font(size: 11, weight: .semibold))
                        .foregroundColor(themeManager.current.textPrimary)
                        .lineLimit(1)

                    if viewingProfile.provider != .anthropic {
                        ProviderLogoView(provider: viewingProfile.provider, size: 10)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    if viewingProfile.id == profileManager.activeProfile?.id {
                        Text(themeManager.current.label("Active"))
                            .font(themeManager.current.bodyFont.font(size: 8, weight: .semibold))
                            .foregroundColor(themeManager.current.accent)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(
                                Capsule()
                                    .fill(themeManager.current.accent.opacity(0.12))
                            )
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(0.03))
                )
                .padding(.horizontal, 10)
                .padding(.top, 6)
            }

            // Usage
            SmartUsageDashboard(usage: displayUsage, apiUsage: displayAPIUsage, provider: displayProvider)

            // Contextual Insights
            // Insights are about session and weekly usage, which a
            // spend-limited account does not have.
            if showInsights && !displayUsage.isSpendLimited {
                PopoverDivider()
                ContextualInsights(usage: displayUsage)
                    .transition(.opacity)
            }

        }
        .padding(.bottom, 8)
        .frame(width: 280)
        .background(ThemedPanelBackground())
        .overlay(ThemedPanelBorder())
        .themedPanelClip(themeManager.current)
        .modifier(ThemedEntrance(
            progress: openProgress,
            style: reduceMotion ? .standard : themeManager.current.openAnimation,
            traceColor: themeManager.current.accent
        ))
        .environment(\.appTheme, themeManager.current)
        .onAppear {
            openProgress = 0
            let style = reduceMotion ? .standard : themeManager.current.openAnimation
            withAnimation(style.animation) {
                openProgress = 1
            }
        }
    }
}

// MARK: - Native Divider

struct PopoverDivider: View {
    var body: some View {
        ThemedDivider()
    }
}

// MARK: - Profile Switcher Compact (for header)

struct ProfileSwitcherCompact: View {
    @StateObject private var profileManager = ProfileManager.shared
    @Environment(\.appTheme) private var theme
    @State private var isHovered = false
    let onManageProfiles: () -> Void

    var body: some View {
        Menu {
            ForEach(profileManager.profiles) { profile in
                Button(action: {
                    Task {
                        await profileManager.activateProfile(profile.id)
                    }
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "person.circle.fill")
                            .font(.system(size: 12))

                        Text(profile.name)
                            .font(.system(size: 12, weight: .medium))

                        Spacer()

                        HStack(spacing: 4) {
                            if profile.provider != .anthropic {
                                ProviderLogoView(provider: profile.provider, size: 9)
                                    .foregroundColor(.secondary)
                            }

                            if profile.hasCliAccount {
                                Image(systemName: "terminal.fill")
                                    .font(.system(size: 9))
                                    .foregroundColor(.adaptiveGreen)
                            }

                            if profile.claudeSessionKey != nil {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 9))
                                    .foregroundColor(.blue)
                            }

                            if profile.id == profileManager.activeProfile?.id {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(.accentColor)
                            }
                        }
                    }
                }
            }

            Divider()

            Button(action: onManageProfiles) {
                HStack {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 12))
                    Text("popover.manage_profiles".localized)
                        .font(.system(size: 12, weight: .medium))
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text((theme.profilePrefix ?? "") + theme.label(profileManager.activeProfile?.name ?? "popover.no_profile".localized))
                    .font(theme.titleFont.font(size: 13, weight: .bold))
                    .tracking(theme.titleTracking * 0.6)
                    .foregroundColor(theme.headerText ?? theme.textPrimary)
                    .shadow(color: theme.glow ? theme.accent.opacity(0.7) : .clear, radius: 5)
                    .lineLimit(1)
                if theme.showsCursor {
                    BlinkingCursor(color: theme.accent)
                }
            }
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        // The popover window can hand this Menu first-responder status on open,
        // which draws an accent-colored focus ring around the header label.
        .focusEffectDisabled()
    }
}

// MARK: - Profile Switcher Bar

struct ProfileSwitcherBar: View {
    @StateObject private var profileManager = ProfileManager.shared
    @State private var isHovered = false
    let onManageProfiles: () -> Void

    var body: some View {
        Menu {
            ForEach(profileManager.profiles) { profile in
                Button(action: {
                    Task {
                        await profileManager.activateProfile(profile.id)
                    }
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "person.circle.fill")
                            .font(.system(size: 12))

                        Text(profile.name)
                            .font(.system(size: 12, weight: .medium))

                        Spacer()

                        HStack(spacing: 4) {
                            if profile.provider != .anthropic {
                                ProviderLogoView(provider: profile.provider, size: 9)
                                    .foregroundColor(.secondary)
                            }

                            if profile.hasCliAccount {
                                Image(systemName: "terminal.fill")
                                    .font(.system(size: 9))
                                    .foregroundColor(.adaptiveGreen)
                            }

                            if profile.claudeSessionKey != nil {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 9))
                                    .foregroundColor(.blue)
                            }

                            if profile.id == profileManager.activeProfile?.id {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(.accentColor)
                            }
                        }
                    }
                }
            }

            Divider()

            Button(action: onManageProfiles) {
                HStack {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 12))
                    Text("popover.manage_profiles".localized)
                        .font(.system(size: 12, weight: .medium))
                }
            }
        } label: {
            HStack(spacing: 8) {
                // Profile avatar
                ZStack {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 28, height: 28)

                    Text(profileInitials)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(profileManager.activeProfile?.name ?? "popover.no_profile".localized)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        if profileManager.profiles.count > 1 {
                            Text(String(format: "popover.profiles_count".localized, profileManager.profiles.count))
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(.secondary)
                        } else {
                            Text("popover.profile_count_singular".localized)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(.secondary)
                        }

                        Text("•")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary.opacity(0.5))

                        Text("common.switch".localized)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovered ? Color.primary.opacity(0.05) : Color.clear)
            )
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        // See ProfileSwitcherCompact: suppress the first-responder focus ring.
        .focusEffectDisabled()
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }

    private var profileInitials: String {
        guard let name = profileManager.activeProfile?.name else { return "?" }
        let words = name.split(separator: " ")
        if words.count >= 2 {
            return String(words[0].prefix(1) + words[1].prefix(1)).uppercased()
        } else if let first = words.first {
            return String(first.prefix(2)).uppercased()
        }
        return "?"
    }
}

// MARK: - Smart Header Component
struct SmartHeader: View {
    let usage: ClaudeUsage
    let status: ClaudeStatus
    let isRefreshing: Bool
    let onRefresh: () -> Void
    let onManageProfiles: () -> Void
    let onPreferences: () -> Void
    var clickedProfileId: UUID? = nil

    @StateObject private var profileManager = ProfileManager.shared
    @Environment(\.appTheme) private var theme

    private var statusColor: Color {
        theme.serviceStatusColor(status.indicator.color)
    }

    private var isMultiProfileMode: Bool {
        profileManager.displayMode == .multi
    }

    private var clickedProfile: Profile? {
        guard let id = clickedProfileId else { return nil }
        return profileManager.profiles.first { $0.id == id }
    }

    private func profileInitials(for name: String) -> String {
        let words = name.split(separator: " ")
        if words.count >= 2 {
            return String(words[0].prefix(1) + words[1].prefix(1)).uppercased()
        } else if let first = words.first {
            return String(first.prefix(2)).uppercased()
        }
        return "?"
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                ProfileSwitcherCompact(onManageProfiles: onManageProfiles)

                // Status
                Button(action: {
                    if let url = URL(string: "https://status.claude.com") {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    HStack(spacing: 4) {
                        ThemedStatusMarker(color: statusColor, isOperational: status.indicator == .none)

                        Text(theme.label(status.description))
                            .font(theme.detailFont.font(size: 9, weight: .medium))
                            .foregroundColor(theme.headerText?.opacity(0.75) ?? theme.textSecondary)
                    }
                }
                .buttonStyle(.plain)
                .help("Click to open status.claude.com")
            }

            Spacer()

            HStack(alignment: .center, spacing: 2) {
                // Refresh
                HeaderIconButton(
                    icon: "arrow.clockwise",
                    isRefreshing: isRefreshing,
                    action: onRefresh
                )
                .disabled(isRefreshing)

                // Settings
                HeaderIconButton(
                    icon: "gearshape.fill",
                    fontSize: 12,
                    action: onPreferences
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background {
            if let band = theme.headerBand {
                band
            } else if theme.perspectiveGrid {
                PerspectiveGridView(color: theme.accent.opacity(0.4))
                    .padding(.top, 12)
            }
        }
    }
}

// MARK: - Header Icon Button
struct HeaderIconButton: View {
    let icon: String
    var fontSize: CGFloat = 10.5
    var isRefreshing: Bool = false
    let action: () -> Void

    @Environment(\.appTheme) private var theme
    @State private var isHovered = false

    private var iconColor: Color {
        if let headerText = theme.headerText { return headerText }
        if theme.glow { return theme.accent.opacity(isHovered ? 1 : 0.85) }
        return isHovered ? theme.textPrimary : theme.textSecondary
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 10, height: 10)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: fontSize, weight: .medium))
                        .imageScale(.medium)
                }
            }
            .foregroundColor(iconColor)
            .shadow(color: theme.glow ? theme.accent.opacity(0.7) : .clear, radius: 3)
            .frame(width: 24, height: 24, alignment: .center)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isHovered ? Color.primary.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Smart Usage Dashboard
struct SmartUsageDashboard: View {
    let usage: ClaudeUsage
    let apiUsage: APIUsage?
    var provider: Provider = .anthropic
    @StateObject private var profileManager = ProfileManager.shared
    @Environment(\.appTheme) private var theme
    private var capabilities: ProviderCapabilities {
        provider.descriptor.capabilities
    }

    private var showRemainingPercentage: Bool {
        if profileManager.displayMode == .multi {
            return profileManager.multiProfileConfig.showRemainingPercentage
        }
        return profileManager.activeProfile?.iconConfig.showRemainingPercentage ?? false
    }

    private var showTimeMarker: Bool {
        if profileManager.displayMode == .multi {
            return profileManager.multiProfileConfig.showTimeMarker
        }
        return profileManager.activeProfile?.iconConfig.showTimeMarker ?? true
    }

    private var usePaceColoring: Bool {
        if profileManager.displayMode == .multi {
            return profileManager.multiProfileConfig.usePaceColoring
        }
        return profileManager.activeProfile?.iconConfig.usePaceColoring ?? true
    }

    private var showPaceMarker: Bool {
        if profileManager.displayMode == .multi {
            return profileManager.multiProfileConfig.showPaceMarker
        }
        return profileManager.activeProfile?.iconConfig.showPaceMarker ?? true
    }

    private var timeDisplay: PopoverTimeDisplay {
        SharedDataStore.shared.loadPopoverTimeDisplay()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Spend-limited accounts (monthly cap, no windows): one spend card.
            if usage.isSpendLimited, let used = usage.costUsed, let limit = usage.costLimit {
                let currency = usage.costCurrency ?? "USD"
                let period = SpendPeriod.containing(Date())
                UsageRow(
                    title: "menubar.monthly_spend".localized,
                    subtitle: "menubar.spend_of_limit".localized(
                        with: SpendFormatting.string(cents: used, currency: currency),
                        SpendFormatting.string(cents: limit, currency: currency)
                    ),
                    usedPercentage: usage.spendPercentage,
                    showRemaining: showRemainingPercentage,
                    resetTime: period.end,
                    periodDuration: period.duration,
                    showTimeMarker: showTimeMarker,
                    showPaceMarker: showPaceMarker,
                    usePaceColoring: usePaceColoring,
                    timeDisplay: timeDisplay
                )
            }

            // Primary: Session Usage (not shown for spend-limited accounts)
            if !usage.isSpendLimited {
                UsageRow(
                    title: "menubar.session_usage".localized,
                    subtitle: "menubar.5_hour_window".localized,
                    usedPercentage: usage.effectiveSessionPercentage,
                    showRemaining: showRemainingPercentage,
                    resetTime: usage.sessionResetTime,
                    periodDuration: Constants.sessionWindow,
                    showTimeMarker: showTimeMarker,
                    showPaceMarker: showPaceMarker,
                    usePaceColoring: usePaceColoring,
                    timeDisplay: timeDisplay
                )
            }

            if usage.designWeeklyTokensUsed > 0 {
                UsageRow(
                    title: "menubar.design_usage".localized,
                    tag: "menubar.weekly".localized,
                    subtitle: nil,
                    usedPercentage: usage.designWeeklyPercentage,
                    showRemaining: showRemainingPercentage,
                    resetTime: usage.designWeeklyResetTime,
                    periodDuration: nil,
                    timeDisplay: timeDisplay
                )
            }

            // All Models (Weekly)
            if !usage.isSpendLimited {
                UsageRow(
                    title: "menubar.all_models".localized,
                    tag: "menubar.weekly".localized,
                    subtitle: nil,
                    usedPercentage: usage.weeklyPercentage,
                    showRemaining: showRemainingPercentage,
                    resetTime: usage.weeklyResetTime,
                    periodDuration: Constants.weeklyWindow,
                    showTimeMarker: showTimeMarker,
                    showPaceMarker: showPaceMarker,
                    usePaceColoring: usePaceColoring,
                    timeDisplay: timeDisplay
                )
            }

            if usage.fableWeeklyTokensUsed > 0 {
                UsageRow(
                    title: "menubar.fable_usage".localized,
                    tag: "menubar.weekly".localized,
                    subtitle: nil,
                    usedPercentage: usage.fableWeeklyPercentage,
                    showRemaining: showRemainingPercentage,
                    resetTime: usage.fableWeeklyResetTime,
                    periodDuration: nil,
                    timeDisplay: timeDisplay
                )
            }

            if usage.opusWeeklyTokensUsed > 0 {
                UsageRow(
                    title: "menubar.opus_usage".localized,
                    tag: "menubar.weekly".localized,
                    subtitle: nil,
                    usedPercentage: usage.opusWeeklyPercentage,
                    showRemaining: showRemainingPercentage,
                    resetTime: nil,
                    periodDuration: nil
                )
            }

            if usage.sonnetWeeklyTokensUsed > 0 {
                UsageRow(
                    title: "menubar.sonnet_usage".localized,
                    subtitle: nil,
                    usedPercentage: usage.sonnetWeeklyPercentage,
                    showRemaining: showRemainingPercentage,
                    resetTime: usage.sonnetWeeklyResetTime,
                    periodDuration: nil,
                    timeDisplay: timeDisplay
                )
            }

            // Extra usage (cost-based); a spend-limited account shows it in the spend card instead
            if !usage.isSpendLimited, let used = usage.costUsed, let limit = usage.costLimit, let currency = usage.costCurrency, limit > 0 {
                let usedPercentage = (used / limit) * 100.0
                UsageRow(
                    title: "menubar.extra_usage".localized,
                    subtitle: String(format: "%.2f / %.2f %@", used / 100.0, limit / 100.0, currency),
                    usedPercentage: usedPercentage,
                    showRemaining: showRemainingPercentage,
                    resetTime: nil,
                    periodDuration: nil
                )

                // Overage credit grant balance
                if let balance = usage.overageBalance, let balanceCurrency = usage.overageBalanceCurrency {
                    HStack {
                        Text(theme.label("popover.overage_balance".localized))
                            .font(theme.bodyFont.font(size: 11, weight: .medium))
                            .foregroundColor(theme.textSecondary)
                        Spacer()
                        Text(String(format: "%.2f %@", balance / 100.0, balanceCurrency.uppercased()))
                            .font(theme.numberFont.font(size: 11, weight: .semibold))
                            .foregroundColor(theme.statusColor(.safe))
                    }
                }
            }

            // Plan / credits (providers that report them, e.g. Codex)
            if usage.planType != nil || usage.creditsUnlimited == true || usage.creditsBalance != nil {
                HStack(spacing: 6) {
                    if let plan = usage.planType {
                        Text(theme.label(plan.replacingOccurrences(of: "_", with: " ").capitalized))
                            .font(theme.bodyFont.font(size: 9, weight: .semibold))
                            .foregroundColor(theme.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(theme.accent.opacity(0.12)))
                    }

                    Spacer()

                    if usage.creditsUnlimited == true {
                        Text(theme.label("popover.credits_unlimited".localized))
                            .font(theme.bodyFont.font(size: 10, weight: .medium))
                            .foregroundColor(theme.statusColor(.safe))
                    } else if let balance = usage.creditsBalance {
                        Text(theme.label("popover.credits_balance".localized(with: String(format: "%.2f", balance))))
                            .font(theme.bodyFont.font(size: 10, weight: .medium))
                            .foregroundColor(theme.textSecondary)
                    }
                }
                .padding(.top, 2)
            }

            // API Usage (console-billing providers only)
            if capabilities.consoleBilling, let apiUsage = apiUsage {
                APIUsageCard(apiUsage: apiUsage, showRemaining: showRemainingPercentage, timeDisplay: timeDisplay)

                // API Cost Card (only if cost data is available)
                if let costCents = apiUsage.apiTokenCostCents, costCents > 0 {
                    APICostCard(apiUsage: apiUsage)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

// MARK: - Usage Row (flat, native style)
struct UsageRow: View {
    let title: String
    var tag: String? = nil
    let subtitle: String?
    let usedPercentage: Double
    let showRemaining: Bool
    let resetTime: Date?
    let periodDuration: TimeInterval?
    var showTimeMarker: Bool = true
    var showPaceMarker: Bool = true
    var usePaceColoring: Bool = true
    var timeDisplay: PopoverTimeDisplay = .resetTime

    @Environment(\.appTheme) private var theme

    private var displayPercentage: Double {
        UsageStatusCalculator.getDisplayPercentage(
            usedPercentage: usedPercentage,
            showRemaining: showRemaining
        )
    }

    private var rawElapsedFraction: Double? {
        UsageStatusCalculator.elapsedFraction(
            resetTime: resetTime,
            duration: periodDuration ?? 0,
            showRemaining: false
        )
    }

    private var timeMarkerFraction: CGFloat? {
        guard showTimeMarker, let f = rawElapsedFraction else { return nil }
        return CGFloat(showRemaining ? 1.0 - f : f)
    }

    private var paceStatus: PaceStatus? {
        guard showPaceMarker, let elapsed = rawElapsedFraction else { return nil }
        return PaceStatus.calculate(usedPercentage: usedPercentage, elapsedFraction: elapsed)
    }

    private var timeMarkerColor: Color {
        if let pace = paceStatus {
            return pace.swiftUIColor
        }
        return Color(nsColor: .labelColor)
    }

    private var statusLevel: UsageStatusLevel {
        UsageStatusCalculator.calculateStatus(
            usedPercentage: usedPercentage,
            showRemaining: showRemaining,
            elapsedFraction: usePaceColoring ? rawElapsedFraction : nil
        )
    }

    private var statusColor: Color {
        theme.statusColor(statusLevel)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Title row with percentage
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        ThemedRowTitle(text: title)

                        if let tag = tag {
                            ThemedTag(text: tag)
                        }
                    }

                    if let subtitle = subtitle {
                        Text(theme.label(subtitle))
                            .font(theme.detailFont.font(size: 10, weight: .regular))
                            .foregroundColor(theme.textSecondary)
                    }
                }

                Spacer()

                ThemedPercent(
                    value: Int(displayPercentage),
                    color: statusColor,
                    isCritical: statusLevel == .critical
                )
            }

            // Progress bar
            ThemedUsageBar(
                fraction: displayPercentage / 100.0,
                color: statusColor,
                markerFraction: timeMarkerFraction,
                markerColor: timeMarkerColor,
                isCritical: statusLevel == .critical
            )

            // Reset time
            if let reset = resetTime {
                Text(theme.label(resetTimeText(for: reset)))
                    .font(theme.detailFont.font(size: 9, weight: .regular))
                    .foregroundColor(theme.textSecondary)
            }
        }
        .themedRowChrome(accent: statusColor)
    }

    private func resetTimeText(for reset: Date) -> String {
        switch timeDisplay {
        case .resetTime:
            return "menubar.resets_time".localized(with: reset.resetTimeString())
        case .remainingTime:
            return "menubar.resets_in".localized(with: reset.timeRemainingString())
        case .both:
            return "menubar.resets_both".localized(with: reset.timeRemainingString(), reset.resetTimeString())
        }
    }
}

// MARK: - Contextual Insights
struct ContextualInsights: View {
    let usage: ClaudeUsage
    @Environment(\.appTheme) private var theme

    private var insights: [Insight] {
        var result: [Insight] = []

        if usage.effectiveSessionPercentage > 80 {
            result.append(Insight(
                icon: "exclamationmark.triangle.fill",
                color: theme.statusColor(.moderate),
                title: "usage.high_session".localized,
                description: "usage.high_session.desc".localized
            ))
        }

        if usage.weeklyPercentage > 90 {
            result.append(Insight(
                icon: "clock.fill",
                color: theme.statusColor(.critical),
                title: "usage.weekly_approaching".localized,
                description: "usage.weekly_approaching.desc".localized
            ))
        }

        if usage.effectiveSessionPercentage < 20 && usage.weeklyPercentage < 30 {
            result.append(Insight(
                icon: "checkmark.circle.fill",
                color: theme.statusColor(.safe),
                title: "usage.efficient".localized,
                description: "usage.efficient.desc".localized
            ))
        }

        return result
    }

    var body: some View {
        VStack(spacing: 2) {
            ForEach(insights, id: \.title) { insight in
                HStack(spacing: 8) {
                    Image(systemName: insight.icon)
                        .font(.system(size: 11))
                        .foregroundColor(insight.color)
                        .frame(width: 16)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(theme.label(insight.title))
                            .font(theme.bodyFont.font(size: 11, weight: .medium))
                            .foregroundColor(theme.textPrimary)

                        Text(insight.description)
                            .font(theme.detailFont.font(size: 10, weight: .regular))
                            .foregroundColor(theme.textSecondary)
                            .lineLimit(2)
                    }

                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
        }
        .padding(.vertical, 4)
    }
}

struct Insight {
    let icon: String
    let color: Color
    let title: String
    let description: String
}

// MARK: - Smart Footer
struct SmartFooter: View {
    let usage: ClaudeUsage
    let status: ClaudeStatus
    @Binding var showInsights: Bool
    let onPreferences: () -> Void

    var body: some View {
        HStack {
            Spacer()
            SmartActionButton(
                icon: "gearshape.fill",
                title: "common.settings".localized,
                action: onPreferences
            )
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Claude Status Row
struct ClaudeStatusRow: View {
    let status: ClaudeStatus
    @State private var isHovered = false

    private var statusColor: Color {
        switch status.indicator.color {
        case .green: return .adaptiveGreen
        case .yellow: return .yellow
        case .orange: return .orange
        case .red: return .red
        case .gray: return .gray
        }
    }

    var body: some View {
        Button(action: {
            if let url = URL(string: "https://status.claude.com") {
                NSWorkspace.shared.open(url)
            }
        }) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)

                Text(status.description)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Spacer()

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isHovered ? Color.accentColor.opacity(0.1) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) {
                isHovered = hovering
            }
        }
        .help("Click to open status.claude.com")
    }
}

// MARK: - Smart Action Button (kept for backward compatibility)
struct SmartActionButton: View {
    let icon: String
    let title: String
    var isDestructive: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                    .frame(width: 12)

                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(isDestructive ? .red : (isHovered ? .primary : .secondary))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - API Cost Card
struct APICostCard: View {
    let apiUsage: APIUsage
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Header
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    ThemedRowTitle(text: "API Cost")

                    Text(theme.label("This Month"))
                        .font(theme.detailFont.font(size: 10, weight: .regular))
                        .foregroundColor(theme.textSecondary)
                }

                Spacer()

                // Total cost
                if let formatted = apiUsage.formattedAPICost {
                    Text(formatted)
                        .font(theme.numberFont.font(size: 13, weight: .semibold))
                        .foregroundColor(theme.textPrimary)
                }
            }

            // Daily cost chart
            DailyCostChart(dailyCosts: apiUsage.sortedDailyCosts, currency: apiUsage.currency)

            // Per-key breakdown (if multiple sources) or flat model list
            if apiUsage.hasMultipleSources {
                VStack(spacing: 6) {
                    ForEach(apiUsage.sortedCostSources) { source in
                        APICostSourceRow(source: source, currency: apiUsage.currency)
                    }
                }
            } else {
                // Single source or no source data — show flat model breakdown
                let models = apiUsage.sortedModelCosts
                if !models.isEmpty {
                    VStack(spacing: 4) {
                        ForEach(models, id: \.model) { item in
                            HStack {
                                Text(item.model)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)

                                Spacer()

                                Text(item.cost)
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .themedRowChrome(accent: theme.accent)
    }
}

// MARK: - Daily Cost Chart
struct DailyCostChart: View {
    let dailyCosts: [(date: Date, cents: Double)]
    let currency: String
    @Environment(\.appTheme) private var theme

    private struct DayCost: Identifiable {
        let id: Date
        let dollars: Double
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    private var xDomain: ClosedRange<Date> {
        let cal = Calendar.current
        let today = Date()
        let startOfMonth = cal.date(from: cal.dateComponents([.year, .month], from: today))!
        // End of today (start of tomorrow)
        let endOfToday = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: today))!
        return startOfMonth ... endOfToday
    }

    var body: some View {
        if !dailyCosts.isEmpty {
            let data = dailyCosts.map { DayCost(id: $0.date, dollars: $0.cents / 100.0) }
            let maxValue = data.map(\.dollars).max() ?? 0
            Chart(data) { item in
                BarMark(
                    x: .value("Day", item.id, unit: .day),
                    y: .value("Cost", item.dollars),
                    width: .fixed(12)
                )
                .foregroundStyle(theme.statusColor(.moderate).opacity(0.75))
                .cornerRadius(2)
            }
            .chartXScale(domain: xDomain)
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { value in
                    AxisValueLabel(centered: true) {
                        if let date = value.as(Date.self) {
                            Text("\(Calendar.current.component(.day, from: date))")
                                .font(.system(size: 7))
                                .foregroundColor(.secondary.opacity(0.6))
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.3))
                        .foregroundStyle(Color.secondary.opacity(0.15))
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(formatDollars(v, max: maxValue))
                                .font(.system(size: 7, design: .rounded))
                                .foregroundColor(.secondary.opacity(0.6))
                        }
                    }
                }
            }
            .chartYScale(domain: 0 ... max(maxValue * 1.15, 0.01))
            .frame(height: 80)
        }
    }

    private func formatDollars(_ amount: Double, max: Double) -> String {
        if max >= 100 {
            return "$\(Int(amount))"
        } else if max >= 1 {
            return String(format: "$%.1f", amount)
        } else {
            return String(format: "$%.2f", amount)
        }
    }
}

// MARK: - API Cost Source Row
struct APICostSourceRow: View {
    let source: APICostSource
    let currency: String
    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 4) {
            // Source header (tappable to expand)
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: source.sourceType.icon)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(width: 12)

                    Text(source.keyName)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    Spacer()

                    Text(source.formattedTotal(currency: currency))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(.primary)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(.secondary.opacity(0.6))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.06))
                )
            }
            .buttonStyle(.plain)

            // Expanded model breakdown
            if isExpanded {
                let models = source.sortedModelCosts(currency: currency)
                VStack(spacing: 3) {
                    ForEach(models, id: \.model) { item in
                        HStack {
                            Text(item.model)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(.secondary)
                                .lineLimit(1)

                            Spacer()

                            Text(item.cost)
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.leading, 24)
                .padding(.trailing, 6)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

// MARK: - API Usage Card
struct APIUsageCard: View {
    let apiUsage: APIUsage
    let showRemaining: Bool
    var timeDisplay: PopoverTimeDisplay = .resetTime

    private var displayPercentage: Double {
        UsageStatusCalculator.getDisplayPercentage(
            usedPercentage: apiUsage.usagePercentage,
            showRemaining: showRemaining
        )
    }

    private var statusLevel: UsageStatusLevel {
        UsageStatusCalculator.calculateStatus(
            usedPercentage: apiUsage.usagePercentage,
            showRemaining: showRemaining
        )
    }

    @Environment(\.appTheme) private var theme

    private var usageColor: Color {
        theme.statusColor(statusLevel)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Header
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    ThemedRowTitle(text: "menubar.api_credits".localized)

                    Text(theme.label("menubar.anthropic_console".localized))
                        .font(theme.detailFont.font(size: 10, weight: .regular))
                        .foregroundColor(theme.textSecondary)
                }

                Spacer()

                ThemedPercent(
                    value: Int(displayPercentage),
                    color: usageColor,
                    isCritical: statusLevel == .critical
                )
            }

            // Progress bar
            ThemedUsageBar(
                fraction: displayPercentage / 100.0,
                color: usageColor,
                isCritical: statusLevel == .critical
            )

            // Used / Remaining
            HStack {
                Text(apiUsage.formattedUsed)
                    .font(theme.detailFont.font(size: 10, weight: .regular))
                    .foregroundColor(theme.textSecondary)

                Spacer()

                Text(apiUsage.formattedRemaining)
                    .font(theme.detailFont.font(size: 10, weight: .regular))
                    .foregroundColor(theme.textSecondary)
            }

            // Reset Time
            if apiUsage.resetsAt > Date() {
                Text(theme.label(resetTimeText(for: apiUsage.resetsAt)))
                    .font(theme.detailFont.font(size: 9, weight: .regular))
                    .foregroundColor(theme.textSecondary)
            }
        }
        .themedRowChrome(accent: usageColor)
    }

    private func resetTimeText(for reset: Date) -> String {
        switch timeDisplay {
        case .resetTime:
            return "menubar.resets_time".localized(with: reset.resetTimeString())
        case .remainingTime:
            return "menubar.resets_in".localized(with: reset.timeRemainingString())
        case .both:
            return "menubar.resets_both".localized(with: reset.timeRemainingString(), reset.resetTimeString())
        }
    }
}

// MARK: - Status Banner View
struct StatusBannerView: View {
    let icon: String
    let message: String
    let color: Color
    var onTap: (() -> Void)? = nil
    @Environment(\.appTheme) private var theme

    var body: some View {
        // A Button rather than a tap gesture: the popover belongs to an inactive
        // accessory app, and AppKit only delivers a click-through mouse-down to views
        // that accept first mouse, which a bare tap gesture does not.
        if let onTap {
            Button(action: onTap) {
                bannerContent
            }
            .buttonStyle(.plain)
        } else {
            bannerContent
        }
    }

    private var bannerContent: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(color)
            Text(theme.label(message))
                .font(theme.bodyFont.font(size: 11, weight: .medium))
                .foregroundColor(theme.textPrimary)
                .lineLimit(1)
            Spacer()
            if onTap != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(color.opacity(0.12))
        .cornerRadius(6)
        .contentShape(Rectangle())
        .padding(.horizontal, 10)
        .padding(.top, 4)
    }
}
