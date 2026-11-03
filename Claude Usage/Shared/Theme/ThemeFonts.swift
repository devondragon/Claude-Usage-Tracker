//
//  ThemeFonts.swift
//  Claude Usage
//
//  Font families used by themes. The non-system families ship in Resources/Fonts
//  (SIL Open Font License, license texts alongside) and are registered for this
//  process at launch.
//

import SwiftUI
import AppKit
import CoreText

enum ThemeFontFamily: Equatable {
    case system
    case systemRounded
    case orbitron
    case exo2
    case rajdhani
    case shareTechMono
    case vt323

    /// Families differ a lot in apparent size at the same point size. Scaling keeps a
    /// themed label close to the space the system font would take.
    var sizeScale: CGFloat {
        switch self {
        case .system, .systemRounded: return 1.0
        case .orbitron: return 0.82
        case .exo2: return 1.0
        case .rajdhani: return 1.12
        case .shareTechMono: return 0.95
        case .vt323: return 1.35
        }
    }

    /// PostScript name of the bundled face closest to `weight`.
    func postScriptName(for weight: NSFont.Weight) -> String? {
        switch self {
        case .system, .systemRounded:
            return nil
        case .orbitron:
            if weight >= .bold { return "Orbitron-Bold" }
            if weight >= .medium { return "Orbitron-Medium" }
            return "Orbitron-Regular"
        case .exo2:
            return weight >= .medium ? "Exo2-Medium" : "Exo2-Regular"
        case .rajdhani:
            if weight >= .bold { return "Rajdhani-Bold" }
            if weight >= .semibold { return "Rajdhani-SemiBold" }
            return "Rajdhani-Medium"
        case .shareTechMono:
            return "ShareTechMono-Regular"
        case .vt323:
            return "VT323-Regular"
        }
    }

    func nsFont(size: CGFloat, weight: NSFont.Weight, monospacedDigits: Bool = false) -> NSFont {
        let scaled = (size * sizeScale).rounded(.toNearestOrEven)
        switch self {
        case .system:
            return monospacedDigits
                ? .monospacedDigitSystemFont(ofSize: scaled, weight: weight)
                : .systemFont(ofSize: scaled, weight: weight)
        case .systemRounded:
            let base: NSFont = monospacedDigits
                ? .monospacedDigitSystemFont(ofSize: scaled, weight: weight)
                : .systemFont(ofSize: scaled, weight: weight)
            guard let rounded = base.fontDescriptor.withDesign(.rounded) else { return base }
            return NSFont(descriptor: rounded, size: scaled) ?? base
        default:
            ThemeFontRegistrar.registerIfNeeded()
            if let name = postScriptName(for: weight), let font = NSFont(name: name, size: size * sizeScale) {
                return font
            }
            return .systemFont(ofSize: size, weight: weight)
        }
    }

    func font(size: CGFloat, weight: NSFont.Weight, monospacedDigits: Bool = false) -> Font {
        Font(nsFont(size: size, weight: weight, monospacedDigits: monospacedDigits) as CTFont)
    }
}

// MARK: - Registration

enum ThemeFontRegistrar {
    /// File names of the bundled faces, without extension.
    static let fontFiles = [
        "Orbitron-Regular", "Orbitron-Medium", "Orbitron-Bold",
        "Exo2-Regular", "Exo2-Medium",
        "Rajdhani-Medium", "Rajdhani-SemiBold", "Rajdhani-Bold",
        "ShareTechMono-Regular",
        "VT323-Regular",
    ]

    private static var didRegister = false

    /// Registers the bundled fonts for this process. Safe to call repeatedly.
    static func registerIfNeeded(bundle: Bundle = .main) {
        guard !didRegister else { return }
        didRegister = true
        var missing: [String] = []
        for name in fontFiles {
            guard let url = bundle.url(forResource: name, withExtension: "ttf")
                ?? bundle.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts") else {
                missing.append(name)
                continue
            }
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                // Already registered is fine (e.g. a test host that registered first).
                let cfError = error?.takeRetainedValue()
                let code = cfError.map { CFErrorGetCode($0) } ?? 0
                if code != CTFontManagerError.alreadyRegistered.rawValue {
                    LoggingService.shared.log("ThemeFontRegistrar: could not register \(name): \(String(describing: cfError))")
                }
            }
        }
        if !missing.isEmpty {
            LoggingService.shared.log("ThemeFontRegistrar: missing bundled fonts \(missing)")
        }
    }
}
