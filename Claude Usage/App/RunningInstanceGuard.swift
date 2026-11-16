//
//  RunningInstanceGuard.swift
//  Claude Usage
//
//  Keeps one copy of the app running (upstream PR #344) and warns when the
//  upstream app runs beside this fork. Both poll the same accounts, write the
//  same history folder and listen on the same notch hook port.
//

import AppKit

@MainActor
final class RunningInstanceGuard {

    static let shared = RunningInstanceGuard()

    private var launchObserver: NSObjectProtocol?
    private var isShowingUpstreamAlert = false

    private init() {}

    // MARK: - Decisions

    /// Another running copy of this app among `apps`, excluding `ownPID`.
    nonisolated static func otherCopy(
        in apps: [(bundleID: String?, pid: pid_t)],
        ownBundleID: String,
        ownPID: pid_t
    ) -> pid_t? {
        apps.first { $0.bundleID == ownBundleID && $0.pid != ownPID }?.pid
    }

    /// Whether a running app is the upstream app.
    nonisolated static func isUpstreamApp(bundleID: String?) -> Bool {
        bundleID == UpstreamSettingsImporter.upstreamBundleIdentifier
    }

    // MARK: - Launch

    /// True when another copy of this app is already running, in which case the
    /// caller quits. Debug builds are exempt so development can go on beside an
    /// installed copy.
    func anotherCopyIsRunning() -> Bool {
        #if DEBUG
        return false
        #else
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let apps = NSWorkspace.shared.runningApplications
            .filter { !$0.isTerminated }
            .map { (bundleID: $0.bundleIdentifier, pid: $0.processIdentifier) }
        guard let pid = Self.otherCopy(
            in: apps,
            ownBundleID: bundleID,
            ownPID: ProcessInfo.processInfo.processIdentifier
        ) else { return false }
        LoggingService.shared.log("Another instance is already running (pid \(pid)); quitting")
        return true
        #endif
    }

    /// Warns now if the upstream app is running, and again whenever it launches.
    func startWatchingForUpstreamApp() {
        if let running = NSWorkspace.shared.runningApplications.first(where: {
            !$0.isTerminated && Self.isUpstreamApp(bundleID: $0.bundleIdentifier)
        }) {
            // Let the launch finish (menu bar items, wizard) before a modal alert.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.warnAboutUpstreamApp(running)
            }
        }

        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  Self.isUpstreamApp(bundleID: app.bundleIdentifier) else { return }
            MainActor.assumeIsolated {
                RunningInstanceGuard.shared.warnAboutUpstreamApp(app)
            }
        }
    }

    // MARK: - Warning

    private func warnAboutUpstreamApp(_ app: NSRunningApplication) {
        guard !app.isTerminated, !isShowingUpstreamAlert else { return }
        isShowingUpstreamAlert = true
        defer { isShowingUpstreamAlert = false }

        LoggingService.shared.log("The upstream app is running (pid \(app.processIdentifier)); warning")

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "duplicate.upstream_title".localized
        alert.informativeText = "duplicate.upstream_message".localized
        alert.addButton(withTitle: "duplicate.quit_other".localized)
        alert.addButton(withTitle: "duplicate.keep_both".localized)

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            app.terminate()
            LoggingService.shared.log("Asked the upstream app to quit")
        }
    }
}
