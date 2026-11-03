//
//  ThemedPopoverComponents.swift
//  Claude Usage
//
//  Building blocks the popover uses to draw itself in the active theme. Each reads the
//  theme from the environment, so a view tree only has to set `.environment(\.appTheme, …)`
//  once at the top. With the System theme every component draws what the popover drew
//  before themes existed.
//

import SwiftUI

// MARK: - Shapes

/// Rectangle with the top-right and bottom-left corners cut at 45 degrees.
struct ChamferedRectangle: InsettableShape {
    var cut: CGFloat
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let top = max(0, cut - insetAmount * 0.4)
        let bottom = top * 1.35
        var path = Path()
        path.move(to: CGPoint(x: r.minX, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX - top, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX, y: r.minY + top))
        path.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        path.addLine(to: CGPoint(x: r.minX + bottom, y: r.maxY))
        path.addLine(to: CGPoint(x: r.minX, y: r.maxY - bottom))
        path.closeSubpath()
        return path
    }

    func inset(by amount: CGFloat) -> ChamferedRectangle {
        var copy = self
        copy.insetAmount += amount
        return copy
    }
}

/// Parallelogram: the top edge is shifted right by `slant`, so both ends lean.
struct AngledBarShape: Shape {
    var slant: CGFloat

    func path(in rect: CGRect) -> Path {
        let s = min(slant, rect.width / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + s, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - s, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// A row of equal blocks across the rect, used for segmented bars.
struct SegmentsShape: Shape {
    var segment: CGFloat
    var gap: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        var x = rect.minX
        while x < rect.maxX {
            path.addRect(CGRect(x: x, y: rect.minY, width: min(segment, rect.maxX - x), height: rect.height))
            x += segment + gap
        }
        return path
    }
}

private struct HorizontalLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

// MARK: - Panel

/// Popover background: the system blur, or the theme's gradient with its overlays.
struct ThemedPanelBackground: View {
    @Environment(\.appTheme) private var theme

    var body: some View {
        switch theme.background {
        case .vibrancy:
            VisualEffectBackground()
        case .gradient(let top, let bottom):
            ZStack {
                LinearGradient(colors: [Color(nsColor: top), Color(nsColor: bottom)], startPoint: .top, endPoint: .bottom)
                if theme.vignette {
                    RadialGradient(
                        colors: [.clear, .black.opacity(0.55)],
                        center: .center,
                        startRadius: 60,
                        endRadius: 260
                    )
                }
                if let scanlineColor = theme.scanlineColor {
                    ScanlinesOverlay(color: scanlineColor)
                }
            }
        }
    }
}

/// Border drawn on top of the panel for themes that have one.
struct ThemedPanelBorder: View {
    @Environment(\.appTheme) private var theme

    var body: some View {
        if let color = theme.panelBorder {
            switch theme.panelShape {
            case .standard:
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(color, lineWidth: theme.vignette ? 2 : 1)
                    .shadow(color: theme.glow ? color : .clear, radius: 6)
            case .chamfered(let cut):
                ChamferedRectangle(cut: cut)
                    .strokeBorder(color, lineWidth: 1.5)
            }
        }
    }
}

extension View {
    /// Clips the popover content to the theme's panel shape.
    @ViewBuilder
    func themedPanelClip(_ theme: AppTheme) -> some View {
        switch theme.panelShape {
        case .standard:
            self
        case .chamfered(let cut):
            self.clipShape(ChamferedRectangle(cut: cut))
        }
    }
}

/// Horizontal lines every few points, like a CRT raster.
struct ScanlinesOverlay: View {
    var color: Color
    var spacing: CGFloat = 3

    var body: some View {
        Canvas { context, size in
            var path = Path()
            var y: CGFloat = 0
            while y < size.height {
                path.addRect(CGRect(x: 0, y: y, width: size.width, height: 1))
                y += spacing
            }
            context.fill(path, with: .color(color))
        }
        .allowsHitTesting(false)
    }
}

/// A grid floor receding toward a horizon at the top edge.
struct PerspectiveGridView: View {
    var color: Color

    var body: some View {
        Canvas { context, size in
            var path = Path()
            let centerX = size.width / 2
            let spacing: CGFloat = 24
            let columns = Int(size.width / spacing) + 4
            for i in -columns...columns {
                let topX = centerX + CGFloat(i) * spacing * 0.35
                let bottomX = centerX + CGFloat(i) * spacing * 1.7
                path.move(to: CGPoint(x: topX, y: 0))
                path.addLine(to: CGPoint(x: bottomX, y: size.height))
            }
            var y: CGFloat = 1
            var step: CGFloat = 2.5
            while y < size.height {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                step *= 1.45
                y += step
            }
            context.stroke(path, with: .color(color), lineWidth: 0.6)
        }
        .mask(LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom))
        .allowsHitTesting(false)
    }
}

// MARK: - Dividers and Markers

struct ThemedDivider: View {
    @Environment(\.appTheme) private var theme

    var body: some View {
        switch theme.dividerStyle {
        case .system:
            Divider()
                .padding(.horizontal, 16)
        case .glowLine:
            Rectangle()
                .fill(LinearGradient(colors: [.clear, theme.divider, .clear], startPoint: .leading, endPoint: .trailing))
                .frame(height: 1)
                .shadow(color: theme.divider, radius: 4)
        case .hidden:
            EmptyView()
        case .dashed:
            HorizontalLine()
                .stroke(theme.divider, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .frame(height: 1)
                .padding(.horizontal, 12)
        }
    }
}

/// The claude.ai service status indicator in the header.
struct ThemedStatusMarker: View {
    @Environment(\.appTheme) private var theme
    let color: Color
    let isOperational: Bool

    var body: some View {
        switch theme.statusMarker {
        case .circle:
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
        case .diamond:
            Rectangle()
                .fill(color)
                .frame(width: 4.5, height: 4.5)
                .rotationEffect(.degrees(45))
                .shadow(color: theme.glow ? color : .clear, radius: 3)
                .frame(width: 6, height: 6)
        case .square:
            Rectangle()
                .fill(color)
                .frame(width: 5, height: 5)
        case .bracketText:
            Text(isOperational ? "[OK]" : "[!!]")
                .font(theme.detailFont.font(size: 9, weight: .regular))
                .foregroundColor(color)
        }
    }
}

struct ThemedTag: View {
    @Environment(\.appTheme) private var theme
    let text: String

    var body: some View {
        tag.fixedSize()
    }

    @ViewBuilder
    private var tag: some View {
        switch theme.tagStyle {
        case .capsule:
            Text(text)
                .font(theme.bodyFont.font(size: 9, weight: .medium))
                .foregroundColor(theme.textSecondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
        case .outlined:
            Text(theme.label(text))
                .font(theme.titleFont.font(size: 9, weight: .medium))
                .tracking(theme.titleTracking * 0.5)
                .foregroundColor(theme.accent)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .overlay(Rectangle().strokeBorder(theme.accent.opacity(0.5), lineWidth: 1))
        case .block:
            Text(theme.label(text))
                .font(theme.detailFont.font(size: 8, weight: .regular))
                .foregroundColor(theme.headerText ?? .black)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Rectangle().fill(theme.headerBand ?? theme.accent))
        }
    }
}

/// Usage row title with the theme's capitalization, tracking, and prefix.
struct ThemedRowTitle: View {
    @Environment(\.appTheme) private var theme
    let text: String

    var body: some View {
        HStack(spacing: 2) {
            if let prefix = theme.titlePrefix {
                Text(prefix)
                    .font(theme.detailFont.font(size: 9, weight: .regular))
                    .foregroundColor(theme.accent)
            }
            if theme.titleTracking > 0 {
                // Wide tracked titles step down in size instead of truncating:
                // truncated tracked text can run under the tag that follows it.
                ViewThatFits(in: .horizontal) {
                    title(scale: 1)
                    title(scale: 0.85)
                    title(scale: 0.7)
                }
            } else {
                // System theme: unchanged from before themes.
                title(scale: 1)
            }
        }
    }

    private func title(scale: CGFloat) -> some View {
        Text(theme.label(text))
            .font(theme.titleFont.font(size: 13 * scale, weight: theme.id == .system ? .medium : .bold))
            .tracking(theme.titleTracking * scale)
            .foregroundColor(theme.textPrimary)
            .shadow(color: theme.glow ? theme.accent.opacity(0.35) : .clear, radius: 4)
            .lineLimit(theme.titleTracking > 0 ? 1 : nil)
    }
}

/// Block cursor that blinks once a second.
struct BlinkingCursor: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let color: Color

    var body: some View {
        if reduceMotion {
            block(visible: true)
        } else {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                block(visible: Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0)
            }
        }
    }

    private func block(visible: Bool) -> some View {
        Rectangle()
            .fill(color)
            .frame(width: 7, height: 13)
            .opacity(visible ? 1 : 0)
    }
}

/// One-line status readout under the header (Night City).
struct ThemedReadout: View {
    @Environment(\.appTheme) private var theme
    let isHealthy: Bool
    let lastUpdated: Date

    private var hexStamp: String {
        String(format: "0x%04X", Int(lastUpdated.timeIntervalSince1970) & 0xFFFF)
    }

    var body: some View {
        HStack(spacing: 4) {
            Text("NET.LINK")
                .foregroundColor(theme.textSecondary)
            Text(isHealthy ? "STABLE" : "DEGRADED")
                .foregroundColor(isHealthy ? theme.accent : theme.statusColor(.critical))
            Spacer()
            Text(hexStamp)
                .foregroundColor(theme.textSecondary)
        }
        .font(theme.detailFont.font(size: 8.5, weight: .regular))
        .tracking(0.6)
        .padding(.horizontal, 14)
        .padding(.top, 5)
    }
}

// MARK: - Usage Row Pieces

/// Container around a usage row or card.
struct ThemedRowChrome: ViewModifier {
    @Environment(\.appTheme) private var theme
    /// Status color of the row, used by themes that tint the row.
    let accent: Color

    func body(content: Content) -> some View {
        switch theme.rowStyle {
        case .outlined:
            content
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(theme.rowBorder, lineWidth: 0.5)
                )
        case .separated:
            content
                .padding(.horizontal, 6)
                .padding(.vertical, 8)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(theme.rowBorder).frame(height: 1)
                }
        case .leadingAccent:
            content
                .padding(.leading, 10)
                .padding(.trailing, 8)
                .padding(.vertical, 6)
                .background(
                    LinearGradient(
                        colors: [accent.opacity(0.1), .clear],
                        startPoint: .leading,
                        endPoint: UnitPoint(x: 0.7, y: 0.5)
                    )
                )
                .overlay(alignment: .leading) {
                    Rectangle().fill(accent).frame(width: 2)
                }
        case .plain:
            content
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
        }
    }
}

extension View {
    func themedRowChrome(accent: Color) -> some View {
        modifier(ThemedRowChrome(accent: accent))
    }
}

/// Timing of the Night City glitch: quiet most of the cycle, then a burst of offsets.
enum GlitchClock {
    static let period: TimeInterval = 2.6

    /// Horizontal offset and color-split distance for the frame at `date`. Zero when quiet.
    static func frame(at date: Date) -> (offset: CGFloat, split: CGFloat) {
        let t = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period)
        let burstStart = period - 0.36
        guard t >= burstStart else { return (0, 0) }
        switch Int((t - burstStart) / 0.06) {
        case 0: return (1, 2)
        case 1: return (-2, 2.5)
        case 2: return (1, 1)
        case 3: return (-1, 2)
        default: return (0, 0)
        }
    }
}

/// Usage percentage with the theme's font, glow, and critical effect.
struct ThemedPercent: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let value: Int
    let color: Color
    let isCritical: Bool
    @State private var pulse = false

    private var effect: AppTheme.CriticalEffect {
        guard isCritical, !reduceMotion else { return .none }
        return theme.criticalEffect
    }

    var body: some View {
        // A usage number never truncates; the title beside it shrinks instead.
        percent.fixedSize()
    }

    @ViewBuilder
    private var percent: some View {
        switch effect {
        case .none:
            text(color: color)
                .shadow(color: theme.glow ? color.opacity(0.7) : .clear, radius: 5)
        case .pulse:
            text(color: color)
                .shadow(color: color.opacity(pulse ? 1 : 0.5), radius: pulse ? 10 : 4)
                .onAppear {
                    withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                        pulse = true
                    }
                }
        case .glitch:
            TimelineView(.periodic(from: .now, by: 0.06)) { context in
                let frame = GlitchClock.frame(at: context.date)
                text(color: color)
                    .shadow(color: theme.statusColor(.safe).opacity(frame.split > 0 ? 1 : 0), radius: 0, x: -frame.split)
                    .shadow(color: theme.statusColor(.critical).opacity(frame.split > 0 ? 1 : 0), radius: 0, x: frame.split)
                    .offset(x: frame.offset)
            }
        case .blink:
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                let on = Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
                text(color: on ? Color(nsColor: theme.background.baseColor) : color)
                    .padding(.horizontal, 3)
                    .background(Rectangle().fill(on ? color : .clear))
            }
        }
    }

    private func text(color: Color) -> some View {
        Text("\(value)%")
            .font(theme.numberFont.font(size: theme.percentSize, weight: .semibold))
            .foregroundColor(color)
    }
}

extension AppTheme.PanelBackground {
    /// Darkest color of the panel, for text drawn on a block of status color.
    var baseColor: NSColor {
        switch self {
        case .vibrancy: return .black
        case .gradient(_, let bottom): return bottom
        }
    }
}

/// Usage bar in the theme's style, with the elapsed-time marker.
struct ThemedUsageBar: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Filled fraction, 0 to 1.
    let fraction: Double
    let color: Color
    var markerFraction: CGFloat? = nil
    var markerColor: Color = Color(nsColor: .labelColor)
    var isCritical: Bool = false
    @State private var pulse = false

    private var clamped: CGFloat { CGFloat(min(max(fraction, 0), 1)) }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                track
                fill(fullWidth: width)
                    .animation(.easeInOut(duration: 0.6), value: fraction)
            }
            .overlay(alignment: .leading) {
                if let markerFraction {
                    marker
                        .offset(x: round(width * markerFraction) - 0.75)
                }
            }
            .modifier(GlitchOffset(active: isCritical && theme.criticalEffect == .glitch && !reduceMotion))
        }
        .frame(height: theme.barHeight)
    }

    @ViewBuilder
    private var track: some View {
        switch theme.barStyle {
        case .rounded:
            RoundedRectangle(cornerRadius: 2.5)
                .fill(theme.track)
        case .trail:
            Rectangle()
                .fill(theme.track)
                .overlay(Rectangle().strokeBorder(theme.accent.opacity(0.35), lineWidth: 1))
        case .segmented(let segment, let gap, let angled):
            SegmentsShape(segment: segment, gap: gap)
                .fill(theme.track)
                .clipShape(AngledBarShape(slant: angled ? 5 : 0))
        }
    }

    @ViewBuilder
    private func fill(fullWidth: CGFloat) -> some View {
        let filled = fullWidth * clamped
        switch theme.barStyle {
        case .rounded:
            RoundedRectangle(cornerRadius: 2.5)
                .fill(color)
                .frame(width: filled)
        case .trail:
            Rectangle()
                .fill(LinearGradient(
                    stops: [
                        .init(color: color.opacity(0.12), location: 0),
                        .init(color: color.opacity(0.55), location: 0.4),
                        .init(color: color, location: 0.9),
                        .init(color: .white, location: 1),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                ))
                .frame(width: filled)
                .padding(.vertical, 1)
                .shadow(color: color.opacity(pulse ? 1 : 0.8), radius: pulse ? 10 : 5)
                .onAppear {
                    guard isCritical, theme.criticalEffect == .pulse, !reduceMotion else { return }
                    withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                        pulse = true
                    }
                }
        case .segmented(let segment, let gap, let angled):
            SegmentsShape(segment: segment, gap: gap)
                .fill(color)
                .frame(width: fullWidth)
                .mask(alignment: .leading) {
                    Rectangle().frame(width: filled)
                }
                .clipShape(AngledBarShape(slant: angled ? 5 : 0))
                .shadow(color: theme.glow ? color.opacity(0.6) : .clear, radius: 3)
        }
    }

    @ViewBuilder
    private var marker: some View {
        switch theme.barStyle {
        case .rounded:
            RoundedRectangle(cornerRadius: 1)
                .fill(markerColor)
                .frame(width: 2.5, height: 8)
        case .trail:
            Rectangle()
                .fill(markerColor)
                .frame(width: 1.5, height: theme.barHeight + 6)
                .shadow(color: markerColor, radius: 3)
        case .segmented(_, _, let angled):
            Rectangle()
                .fill(markerColor)
                .frame(width: 2, height: theme.barHeight + 5)
                .rotationEffect(.degrees(angled ? 25 : 0))
                .shadow(color: theme.glow ? markerColor : .clear, radius: 2)
        }
    }
}

/// Shifts a view during the glitch burst.
private struct GlitchOffset: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if active {
            TimelineView(.periodic(from: .now, by: 0.06)) { context in
                content.offset(x: GlitchClock.frame(at: context.date).offset * 1.5)
            }
        } else {
            content
        }
    }
}

// MARK: - Entrance Animation

extension AppTheme.OpenAnimation {
    var animation: Animation {
        switch self {
        case .standard: return .spring(response: 0.32, dampingFraction: 0.82)
        case .trace: return .linear(duration: 1.0)
        case .wipe: return .linear(duration: 0.35)
        case .powerOn: return .linear(duration: 0.6)
        }
    }
}

/// Plays the theme's open animation as `progress` goes from 0 to 1. Only transforms,
/// opacity, masks, and overlays change, never the view's size, so the popover window
/// never resizes during the animation (see the note on `PopoverContentView.appeared`).
struct ThemedEntrance: ViewModifier, Animatable {
    var progress: CGFloat
    let style: AppTheme.OpenAnimation
    let traceColor: Color

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        switch style {
        case .standard:
            content
                .opacity(Double(progress))
                .scaleEffect(0.96 + 0.04 * progress, anchor: .top)
        case .trace:
            content
                .opacity(Self.flicker(progress))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .trim(from: max(0, progress * 1.2 - 0.18), to: min(1, progress * 1.2))
                        .stroke(Color.white, lineWidth: 2)
                        .shadow(color: traceColor, radius: 4)
                        .shadow(color: traceColor, radius: 8)
                        .opacity(progress >= 1 ? 0 : 1)
                        .allowsHitTesting(false)
                }
        case .wipe:
            content
                .mask(alignment: .leading) {
                    GeometryReader { geometry in
                        Rectangle()
                            .frame(width: geometry.size.width * Self.stepped(progress, steps: 6))
                    }
                }
                .offset(x: progress < 0.5 ? -3 : (progress < 1 ? 2 : 0))
        case .powerOn:
            content
                .scaleEffect(x: 1, y: Self.tubeHeight(progress), anchor: .center)
                .brightness(Double(1 - min(progress, 1)) * 0.9)
        }
    }

    /// Opacity curve that stutters on, like a light tube striking.
    static func flicker(_ p: CGFloat) -> Double {
        switch p {
        case ..<0.15: return Double(p * 2)
        case ..<0.25: return 0.1
        case ..<0.4: return 0.8
        case ..<0.5: return 0.45
        default: return Double(min(p, 1))
        }
    }

    static func stepped(_ p: CGFloat, steps: Int) -> CGFloat {
        guard p < 1 else { return 1 }
        return (p * CGFloat(steps)).rounded(.down) / CGFloat(steps)
    }

    /// Vertical scale for the CRT power-on: a thin line, a quick overshoot, then rest.
    static func tubeHeight(_ p: CGFloat) -> CGFloat {
        if p < 0.3 { return 0.01 }
        let t = min((p - 0.3) / 0.7, 1)
        if t < 0.6 { return 0.01 + t / 0.6 * 1.01 }
        return 1.02 - (t - 0.6) / 0.4 * 0.02
    }
}
