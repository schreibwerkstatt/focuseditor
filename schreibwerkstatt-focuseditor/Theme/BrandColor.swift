//
//  BrandColor.swift
//  schreibwerkstatt-focuseditor
//
//  Native Spiegel der Farb-Tokens aus dem Hauptrepo
//  (public/css/tokens/colors.css). Jeder Wert liefert je nach
//  System-Appearance den Light- oder Dark-Ton — wie das Web-Theme
//  über :root[data-theme="dark"]. Quelle ist das Hauptrepo; ändert
//  sich dort die Palette, hier nachziehen (kein eigener Fork).
//

import SwiftUI
import AppKit

enum BrandColor {
    // Paper/Ink-Palette — warmes Papier als Fläche, Tinten-Schwarz statt Pure-Black.
    static let bg        = dynamic(light: "#faf7f2", dark: "#1a1816")
    static let surface   = dynamic(light: "#ffffff", dark: "#2a2722")
    static let text      = dynamic(light: "#1f1c18", dark: "#e6e2d9")
    static let muted     = dynamic(light: "#6b6258", dark: "#9a948a")
    static let subtle    = dynamic(light: "#787068", dark: "#989083")
    static let faint     = dynamic(light: "#b8aea2", dark: "#524d46")

    // Primär (Navy) + Akzent (Gold) — die Markenfarben.
    static let primary      = dynamic(light: "#1e3a5f", dark: "#7aa3ca")
    static let primaryHover = dynamic(light: "#16293d", dark: "#a8c4e0")
    static let primaryLight = dynamic(light: "#6a8cb0", dark: "#5a7a99")
    static let onPrimary    = dynamic(light: "#ffffff", dark: "#1a1816")
    static let accent       = dynamic(light: "#9a7f3e", dark: "#c9a961")

    // Reading-Frame / Seitenansicht (Long-Form-Lesefläche).
    static let pageBg   = dynamic(light: "#fbf8f3", dark: "#1f1d1a")
    static let pageText = dynamic(light: "#2a2620", dark: "#d8d3c8")

    // Semantische Status-Töne — gespiegelt aus der content-severity-Achse des
    // Hauptrepos (`--color-schwach/mittel/success`, colors.css). Ersetzen die
    // früher verstreuten `.orange`/`.red`/`.green`/RGB-Literale durch EIN
    // appearance-abhängiges System (eigene Dark-Töne wie im Web-Theme).
    static let error   = dynamic(light: "#c43838", dark: "#e25c5c")   // schwach
    static let warning = dynamic(light: "#b38600", dark: "#d8b040")   // mittel (Amber)
    static let success = dynamic(light: "#34d399", dark: "#4fd9aa")

    // Gefüllte Flächen mit Schrift darauf (WCAG AA, ≥ 4,5:1). Die Töne oben
    // sind für Icons/Linien auf Papier gedacht; als Hintergrund unter Text
    // reichten sie nicht (Weiss auf `error` dunkel ≈ 3,6:1, Papier auf `accent`
    // hell ≈ 3,6:1). Client-eigene Ableitungen, kein Token des Hauptrepos.
    /// Hintergrund des kritischen Banners (weisse Schrift): ≈ 5,3 / 6,0 : 1.
    static let errorFill  = dynamic(light: "#c43838", dark: "#b83030")
    /// Hintergrund des prominenten Knopfs (Schrift in `bg`): ≈ 5,2 / 7,9 : 1.
    static let accentFill = dynamic(light: "#7d6630", dark: "#c9a961")

    /// Baut eine appearance-abhängige Farbe aus zwei Hex-Werten.
    private static func dynamic(light: String, dark: String) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

extension NSColor {
    /// sRGB-Farbe aus "#rrggbb".
    convenience init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var rgb: UInt64 = 0
        Scanner(string: s).scanHexInt64(&rgb)
        self.init(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255.0,
            green:   CGFloat((rgb >> 8) & 0xFF) / 255.0,
            blue:    CGFloat(rgb & 0xFF) / 255.0,
            alpha:   1.0
        )
    }
}
