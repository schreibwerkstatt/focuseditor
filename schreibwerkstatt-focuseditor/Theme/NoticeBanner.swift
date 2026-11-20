//
//  NoticeBanner.swift
//  schreibwerkstatt-focuseditor
//
//  Die eine Bannerform über der Schreibfläche. Vier Meldungen benutzen sie —
//  Save-Fehler, Lektorats-Ergebnis, Widerrufen-Hinweis und Buch-Export — und
//  hatten sie vorher jeweils selbst nachgebaut. Das war schon auseinander-
//  gelaufen: der Export-Banner kam mit Radius 8, Breite 560 und eigenem
//  Farbbalken, während sein Kommentar „stiltreu … gleiche Kanten" versprach.
//
//  Aufbau: Icon · Titel/Meldung · optionale Aktion · Schliessen. Der Stapel
//  (Reihenfolge, Abstände) liegt in [ContentView](../ContentView.swift) — hier
//  steht nur, wie EIN Banner aussieht.
//

import SwiftUI

/// Gewicht der Meldung. `critical` ist bewusst die einzige gefüllte Variante:
/// ein fehlgeschlagener lokaler Save heisst, der Text ist NICHT gesichert —
/// das darf sich nicht wie eine Statuszeile lesen.
enum NoticeTone {
    case critical
    case failure
    case success
    case info

    var isFilled: Bool { self == .critical }

    /// Farbe des Icons (bzw. der Schrift in der gefüllten Variante).
    var accent: Color {
        switch self {
        case .critical: return .white
        case .failure:  return BrandColor.error
        case .success:  return BrandColor.success
        case .info:     return BrandColor.accent
        }
    }
}

struct NoticeBanner<Actions: View>: View {
    let tone: NoticeTone
    /// SF-Symbol links.
    let icon: String
    let title: String
    /// Zweite Zeile; `nil` blendet sie aus.
    var message: String?
    /// Beschriftung des Schliessen-Knopfes (Voice-Over).
    var dismissLabel: String = t("general.close")
    let dismiss: () -> Void
    /// Zusätzliche Aktion links vom Schliessen-Knopf (z. B. „Im Finder zeigen").
    @ViewBuilder var actions: () -> Actions

    private var titleColor: Color { tone.isFilled ? .white : BrandColor.text }
    private var messageColor: Color { tone.isFilled ? .white.opacity(0.85) : BrandColor.muted }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(tone.accent)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(BrandFont.sans(13, weight: .semibold))
                    .foregroundStyle(titleColor)
                if let message, !message.isEmpty {
                    Text(message)
                        .font(BrandFont.sans(11))
                        .foregroundStyle(messageColor)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(message.map { "\(title): \($0)" } ?? title)

            Spacer(minLength: 8)

            actions()

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tone.isFilled ? .white.opacity(0.9) : BrandColor.muted)
            }
            .buttonStyle(.plain)
            .pointerLink()
            .accessibilityLabel(dismissLabel)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(tone.isFilled ? BrandColor.errorFill : BrandColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(BrandColor.faint.opacity(tone.isFilled ? 0 : 0.9), lineWidth: 1)
        )
        .shadow(radius: 12, y: 4)
        .padding(.horizontal, 16)
        .frame(maxWidth: 520)
    }
}

extension NoticeBanner where Actions == EmptyView {
    init(tone: NoticeTone,
         icon: String,
         title: String,
         message: String? = nil,
         dismissLabel: String = t("general.close"),
         dismiss: @escaping () -> Void) {
        self.init(tone: tone, icon: icon, title: title, message: message,
                  dismissLabel: dismissLabel, dismiss: dismiss, actions: { EmptyView() })
    }
}
