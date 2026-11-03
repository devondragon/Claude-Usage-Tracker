//
//  AppTheme+MenuBarDrawing.swift
//  Claude Usage
//
//  Drawing helpers the menu bar icon renderer uses so each icon style picks up the
//  active theme's bar shape, fonts, dot shape, and glow. All drawing happens inside an
//  NSImage lockFocus context.
//

import Cocoa

extension AppTheme {

    // MARK: - Fonts

    private var menuBarFontFamily: ThemeFontFamily {
        // The system theme keeps the plain system font the renderer always used.
        id == .system ? .system : numberFont
    }

    func menuBarFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        menuBarFontFamily.nsFont(size: size, weight: weight)
    }

    func menuBarDigitFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        menuBarFontFamily.nsFont(size: size, weight: weight, monospacedDigits: true)
    }

    // MARK: - Glow

    /// Runs `draw` with a soft colored shadow when the theme glows. Glow is skipped on a
    /// light menu bar, where it reads as a smudge.
    func withMenuBarGlow(_ color: NSColor, isDarkMode: Bool, radius: CGFloat = 3, _ draw: () -> Void) {
        guard menuBarGlow, isDarkMode else {
            draw()
            return
        }
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = color.withAlphaComponent(0.9)
        shadow.shadowBlurRadius = radius
        shadow.shadowOffset = .zero
        shadow.set()
        draw()
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: - Bars

    /// Outline of a bar in the theme's shape.
    func menuBarBarPath(_ rect: NSRect, radius: CGFloat) -> NSBezierPath {
        switch barStyle {
        case .rounded, .trail:
            let r = min(radius, rect.height / 2)
            return NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r)
        case .segmented(_, _, let angled):
            guard angled else { return NSBezierPath(rect: rect) }
            let slant = min(rect.height * 0.5, 3)
            let path = NSBezierPath()
            path.move(to: NSPoint(x: rect.minX + slant, y: rect.maxY))
            path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
            path.line(to: NSPoint(x: rect.maxX - slant, y: rect.minY))
            path.line(to: NSPoint(x: rect.minX, y: rect.minY))
            path.close()
            return path
        }
    }

    /// Draws the empty part of a bar.
    func drawMenuBarTrack(_ rect: NSRect, radius: CGFloat, color: NSColor) {
        let path = menuBarBarPath(rect, radius: radius)
        switch barStyle {
        case .rounded:
            color.setFill()
            path.fill()
        case .trail:
            color.withAlphaComponent(color.alphaComponent * 0.4).setFill()
            path.fill()
            let outline = menuBarBarPath(rect.insetBy(dx: 0.5, dy: 0.5), radius: radius)
            color.withAlphaComponent(min(1, color.alphaComponent * 3)).setStroke()
            outline.lineWidth = 1
            outline.stroke()
        case .segmented:
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            color.setFill()
            for segment in menuBarSegments(in: rect, upTo: rect.width) {
                NSBezierPath(rect: segment).fill()
            }
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// Draws the filled part of a bar, `width` points from the track's leading edge.
    func drawMenuBarFill(track: NSRect, width: CGFloat, radius: CGFloat, color: NSColor, isDarkMode: Bool) {
        let width = min(max(width, 0), track.width)
        guard width > 0.5 else { return }
        let fillRect = NSRect(x: track.minX, y: track.minY, width: width, height: track.height)

        switch barStyle {
        case .rounded:
            color.setFill()
            menuBarBarPath(fillRect, radius: radius).fill()

        case .trail:
            withMenuBarGlow(color, isDarkMode: isDarkMode) {
                NSGraphicsContext.saveGraphicsState()
                menuBarBarPath(fillRect, radius: radius).addClip()
                let gradient = NSGradient(colors: [color.withAlphaComponent(0.25), color.withAlphaComponent(0.7), color])
                gradient?.draw(in: fillRect, angle: 0)
                // Bright leading edge, like the head of a light trail.
                let edgeWidth: CGFloat = min(2, width)
                color.blended(withFraction: 0.6, of: .white)?.setFill()
                NSBezierPath(rect: NSRect(x: fillRect.maxX - edgeWidth, y: fillRect.minY, width: edgeWidth, height: fillRect.height)).fill()
                NSGraphicsContext.restoreGraphicsState()
            }

        case .segmented:
            withMenuBarGlow(color, isDarkMode: isDarkMode, radius: 2) {
                NSGraphicsContext.saveGraphicsState()
                menuBarBarPath(track, radius: radius).addClip()
                color.setFill()
                for segment in menuBarSegments(in: track, upTo: width) {
                    NSBezierPath(rect: segment).fill()
                }
                NSGraphicsContext.restoreGraphicsState()
            }
        }
    }

    /// Block rectangles for a segmented bar, sized down from the popover's segments to
    /// suit an icon a few points tall. The last block is cut off at `upTo`.
    private func menuBarSegments(in rect: NSRect, upTo width: CGFloat) -> [NSRect] {
        guard case .segmented(let segment, let gap, _) = barStyle else { return [rect] }
        let seg = max(2, (segment * 0.5).rounded())
        let space = max(1, (gap * 0.5).rounded())
        var result: [NSRect] = []
        var x = rect.minX
        while x < rect.minX + width {
            let w = min(seg, rect.minX + width - x)
            result.append(NSRect(x: x, y: rect.minY, width: w, height: rect.height))
            x += seg + space
        }
        return result
    }

    // MARK: - Rings and Dots

    /// Applies the theme's line cap, and dashes for segmented themes, to a progress arc.
    func styleMenuBarRing(_ path: NSBezierPath) {
        switch barStyle {
        case .rounded, .trail:
            path.lineCapStyle = .round
        case .segmented:
            path.lineCapStyle = .butt
            let pattern: [CGFloat] = [2.5, 1]
            path.setLineDash(pattern, count: pattern.count, phase: 0)
        }
    }

    /// Status dot in the theme's marker shape.
    func menuBarDotPath(_ rect: NSRect) -> NSBezierPath {
        switch statusMarker {
        case .circle:
            return NSBezierPath(ovalIn: rect)
        case .diamond:
            let path = NSBezierPath()
            path.move(to: NSPoint(x: rect.midX, y: rect.maxY))
            path.line(to: NSPoint(x: rect.maxX, y: rect.midY))
            path.line(to: NSPoint(x: rect.midX, y: rect.minY))
            path.line(to: NSPoint(x: rect.minX, y: rect.midY))
            path.close()
            return path
        case .square, .bracketText:
            return NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
        }
    }
}
