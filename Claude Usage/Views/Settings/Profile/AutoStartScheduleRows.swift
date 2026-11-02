//
//  AutoStartScheduleRows.swift
//  Claude Usage
//
//  Weekday and weekend start/stop pickers and the last-result line for the
//  auto-start card.
//

import SwiftUI

struct AutoStartScheduleRows: View {
    let profile: Profile
    let onChange: (Profile) -> Void

    private let calendar = Calendar.current
    // Fixed reference day so the pickers only edit the time of day.
    private let referenceDay = Date(timeIntervalSinceReferenceDate: 0)

    @State private var lastResult: AutoStartResult?

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
            windowRow(title: "general.autostart_weekdays".localized, keyPath: \.weekdays)
            windowRow(title: "general.autostart_weekends".localized, keyPath: \.weekends)
            resultLine
        }
        .onAppear(perform: reloadResult)
        .onChange(of: profile.id) { _, _ in reloadResult() }
        .onReceive(NotificationCenter.default.publisher(for: .autoStartResultChanged)) { _ in
            reloadResult()
        }
    }

    // MARK: - Rows

    private func windowRow(
        title: String,
        keyPath: WritableKeyPath<AutoStartSchedule, AutoStartSchedule.Window>
    ) -> some View {
        HStack(spacing: DesignTokens.Spacing.small) {
            Text(title)
                .font(DesignTokens.Typography.body)
                .frame(width: 80, alignment: .leading)

            picker(label: "general.autostart_start".localized, keyPath: keyPath, isStop: false)
            Text("-")
                .foregroundColor(.secondary)
            picker(label: "general.autostart_stop".localized, keyPath: keyPath, isStop: true)

            Spacer()
        }
    }

    private func picker(
        label: String,
        keyPath: WritableKeyPath<AutoStartSchedule, AutoStartSchedule.Window>,
        isStop: Bool
    ) -> some View {
        DatePicker(
            label,
            selection: Binding(
                get: {
                    let window = profile.effectiveAutoStartSchedule[keyPath: keyPath]
                    return AutoStartScheduleEditing.date(
                        forMinute: isStop ? window.stopMinute : window.startMinute,
                        on: referenceDay,
                        calendar: calendar
                    )
                },
                set: { newValue in
                    let minute = AutoStartScheduleEditing.minute(from: newValue, calendar: calendar, isStop: isStop)
                    var schedule = profile.effectiveAutoStartSchedule
                    var window = schedule[keyPath: keyPath]
                    if isStop { window.stopMinute = minute } else { window.startMinute = minute }
                    schedule[keyPath: keyPath] = AutoStartScheduleEditing.clamped(window)
                    var updated = profile
                    updated.autoStartSchedule = schedule
                    onChange(updated)
                }
            ),
            displayedComponents: .hourAndMinute
        )
        .labelsHidden()
        .accessibilityLabel(label)
        .fixedSize()
    }

    // MARK: - Last result

    private var resultLine: some View {
        Text(resultText)
            .font(DesignTokens.Typography.caption)
            .foregroundColor(lastResult?.success == false ? .red : .secondary)
    }

    private var resultText: String {
        guard let result = lastResult else { return "general.autostart_never".localized }
        let when = result.date.formatted(date: .abbreviated, time: .shortened)
        if result.success {
            return String(format: "general.autostart_last_success".localized, when)
        }
        return String(
            format: "general.autostart_last_failure".localized,
            when,
            result.message ?? ""
        )
    }

    private func reloadResult() {
        lastResult = AutoStartStatusStore().lastResult(for: profile.id)
    }
}
