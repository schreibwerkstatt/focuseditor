//
//  BookExportBanner.swift
//  schreibwerkstatt-focuseditor
//
//  Ergebnis des Buch-Exports über der Schreibfläche — stiltreu zum
//  Lektorats-Banner (gleiche Höhe, gleiche Kanten), damit der Stapel aus
//  Save-Fehler / Lektorat / Widerrufen / Export eine Linie hält.
//
//  Die Meldung nennt bewusst die Zahl der Seiten, deren lokaler Stand den
//  Server noch nicht erreicht hat: ein Export mit Lücken darf nicht wie ein
//  vollständiges Backup aussehen (s. BookExportController).
//

import SwiftUI

struct BookExportBanner: View {
    @EnvironmentObject private var export: BookExportController

    var body: some View {
        NoticeBanner(
            tone: isFailure ? .failure : .success,
            icon: icon,
            title: title,
            message: detail,
            dismiss: { export.dismiss() }
        ) {
            if case .done = export.phase {
                Button(t("export.reveal")) { export.revealInFinder() }
                    .buttonStyle(.link)
                    .font(BrandFont.sans(12))
                    .pointerLink()
            }
        }
    }

    private var isFailure: Bool {
        if case .failed = export.phase { return true }
        return false
    }

    private var icon: String {
        isFailure ? "exclamationmark.triangle.fill" : "square.and.arrow.down"
    }

    private var title: String {
        switch export.phase {
        case .done(_, let unsynced):
            let base = t("export.bannerDone")
            return unsynced == 0 ? base : base + " · " + tn(unsynced, "export.bannerUnsynced")
        case .failed(let message):
            return message
        case .idle, .exporting:
            return ""
        }
    }

    private var detail: String? {
        guard case .done(let url, _) = export.phase else { return nil }
        return url.path(percentEncoded: false)
    }
}
