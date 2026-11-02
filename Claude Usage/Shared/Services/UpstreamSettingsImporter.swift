//
//  UpstreamSettingsImporter.swift
//  Claude Usage
//
//  One-time copy of settings from the upstream app's UserDefaults domain.
//

import Foundation

/// This fork runs under its own bundle ID, so it starts with an empty
/// UserDefaults domain. On first launch, copy the upstream app's domain
/// (profiles, display config, notch token, prompt state) so existing users keep
/// their setup.
///
/// Credentials are not carried over: upstream keeps them in the login Keychain
/// under its own service name, and reading those items from a differently signed
/// app would raise a Keychain password prompt per item. Profiles come across
/// without secrets and need a CLI re-sync or sign-in.
enum UpstreamSettingsImporter {
    static let upstreamBundleIdentifier = "HamedElfayome.Claude-Usage"
    static let importedFlagKey = "fork.upstreamSettingsImported_v1"

    /// Keys never copied: Sparkle state belongs to the upstream feed, and the
    /// heartbeat was removed from this fork.
    static func shouldSkip(key: String) -> Bool {
        key.hasPrefix("SU") || key.hasPrefix("heartbeat.")
    }

    /// Runs the import against the real domains. Call before anything reads
    /// UserDefaults-backed stores.
    @discardableResult
    static func importIfNeeded() -> Int {
        guard Bundle.main.bundleIdentifier != upstreamBundleIdentifier else { return 0 }
        let source = UserDefaults.standard.persistentDomain(forName: upstreamBundleIdentifier)
        return importIfNeeded(from: source, into: .standard)
    }

    /// Copies `source` into `defaults` once. Returns the number of keys copied.
    /// Skipped when the import already ran or when this app already has profiles.
    static func importIfNeeded(from source: [String: Any]?, into defaults: UserDefaults) -> Int {
        guard !defaults.bool(forKey: importedFlagKey) else { return 0 }
        defer { defaults.set(true, forKey: importedFlagKey) }

        guard defaults.object(forKey: "profiles_v3") == nil else {
            LoggingService.shared.log("UpstreamSettingsImporter: profiles already present, skipping import")
            return 0
        }
        guard let source, !source.isEmpty else {
            LoggingService.shared.log("UpstreamSettingsImporter: no upstream settings found")
            return 0
        }

        var copied = 0
        for (key, value) in source where !shouldSkip(key: key) {
            defaults.set(value, forKey: key)
            copied += 1
        }
        LoggingService.shared.log("UpstreamSettingsImporter: copied \(copied) keys from \(upstreamBundleIdentifier)")
        return copied
    }
}
