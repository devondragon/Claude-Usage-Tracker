//
//  ClaudeCodeAccountsCard.swift
//  Claude Usage
//
//  Lists the Claude Code config dirs that are logged in (`~/.claude`, `~/.claude-*`) and
//  links one to the active profile. A linked profile reads that dir's keychain entry for
//  usage and never changes it. See docs/plans/2026-11-01-claude-code-accounts.md.
//

import SwiftUI

struct ClaudeCodeAccountsCard: View {
    @ObservedObject var profileManager: ProfileManager
    /// Called after a link or unlink so the parent can reload what it shows.
    var onLinksChanged: () -> Void = {}

    @State private var accounts: [ClaudeCodeSyncService.ConfigDirAccount] = []
    @State private var isLoading = false
    @State private var statusMessage: String?

    private var sync: ClaudeCodeSyncService { .shared }

    var body: some View {
        SettingsSectionCard(
            title: "cc_accounts.title".localized,
            subtitle: "cc_accounts.subtitle".localized
        ) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
                if let profile = profileManager.activeProfile {
                    if let pinned = profile.customKeychainServiceName,
                       !accounts.contains(where: { $0.serviceName == pinned }), !isLoading {
                        unknownPinRow(pinned)
                    }

                    ForEach(accounts) { account in
                        accountRow(account, activeProfile: profile)
                    }

                    if accounts.isEmpty && !isLoading {
                        Text("cc_accounts.empty".localized)
                            .font(DesignTokens.Typography.caption)
                            .foregroundColor(.secondary)
                    }
                }

                HStack(spacing: DesignTokens.Spacing.small) {
                    Button(action: reload) {
                        HStack(spacing: DesignTokens.Spacing.extraSmall) {
                            if isLoading {
                                ProgressView()
                                    .scaleEffect(0.7)
                                    .frame(width: DesignTokens.Icons.small, height: DesignTokens.Icons.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: DesignTokens.Icons.small))
                            }
                            Text("common.refresh".localized)
                                .font(DesignTokens.Typography.body)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isLoading)

                    if !matches.isEmpty {
                        Button("cc_accounts.link_matching".localized, action: linkMatching)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help(matches.map { match in
                                let name = profileManager.profiles.first { $0.id == match.profileId }?.name ?? ""
                                return "\(name) → \(match.account.directoryName)"
                            }.joined(separator: "\n"))
                    }
                }

                if let statusMessage {
                    Text(statusMessage)
                        .font(DesignTokens.Typography.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .onAppear(perform: reload)
    }

    // MARK: - Rows

    @ViewBuilder
    private func accountRow(_ account: ClaudeCodeSyncService.ConfigDirAccount, activeProfile: Profile) -> some View {
        let owner = profileManager.profiles.first { $0.customKeychainServiceName == account.serviceName }
        HStack(alignment: .center, spacing: DesignTokens.Spacing.medium) {
            VStack(alignment: .leading, spacing: 2) {
                Text(account.emailAddress)
                    .font(DesignTokens.Typography.bodyMedium)
                Text([account.organizationName, "~/\(account.directoryName)"]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(DesignTokens.Typography.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if owner?.id == activeProfile.id {
                Label("cc_accounts.linked".localized, systemImage: "checkmark.circle.fill")
                    .font(DesignTokens.Typography.caption)
                    .foregroundColor(.green)
                Button("cc_accounts.unlink".localized) { unlink(activeProfile.id) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else if let owner {
                Text(String(format: "cc_accounts.used_by".localized, owner.name))
                    .font(DesignTokens.Typography.caption)
                    .foregroundColor(.secondary)
            } else {
                Button("cc_accounts.use".localized) { link(activeProfile.id, to: account) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    private func unknownPinRow(_ serviceName: String) -> some View {
        HStack(spacing: DesignTokens.Spacing.medium) {
            Text(String(format: "cc_accounts.unknown_pin".localized, serviceName))
                .font(DesignTokens.Typography.caption)
                .foregroundColor(.secondary)
            Spacer()
            if let id = profileManager.activeProfile?.id {
                Button("cc_accounts.unlink".localized) { unlink(id) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Actions

    private var matches: [(profileId: UUID, account: ClaudeCodeSyncService.ConfigDirAccount)] {
        ClaudeCodeSyncService.matchProfiles(profileManager.profiles, to: accounts)
    }

    private func reload() {
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let found = ClaudeCodeSyncService.shared.discoverConfigDirAccounts()
            DispatchQueue.main.async {
                accounts = found
                isLoading = false
            }
        }
    }

    private func link(_ profileId: UUID, to account: ClaudeCodeSyncService.ConfigDirAccount) {
        sync.linkProfile(profileId, to: account)
        afterChange(message: nil)
    }

    private func unlink(_ profileId: UUID) {
        sync.unlinkProfile(profileId)
        afterChange(message: nil)
    }

    private func linkMatching() {
        let pending = matches
        for match in pending {
            sync.linkProfile(match.profileId, to: match.account)
        }
        afterChange(message: String(format: "cc_accounts.linked_count".localized, pending.count))
    }

    private func afterChange(message: String?) {
        profileManager.loadProfiles()
        statusMessage = message
        onLinksChanged()
    }
}
