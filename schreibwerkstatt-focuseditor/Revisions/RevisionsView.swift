//
//  RevisionsView.swift
//  schreibwerkstatt-focuseditor
//
//  „Frühere Fassungen …" (⌘⇧R) — Liste der serverseitigen Seiten-Revisionen mit
//  Klartext-Vorschau und Wiederherstellen.
//
//  Bewusst schlicht: links die Fassungen (Zeitpunkt, Umfang, Herkunft), rechts
//  eine Vorschau, unten ein Knopf. KEIN Diff und kein zweiter Editor — die
//  Ansicht beantwortet „welche Fassung will ich zurück", nicht „was genau hat
//  sich geändert". Für den Vergleich gibt es die Web-App; hier zählt, dass der
//  Weg zurück ohne Kontextwechsel erreichbar ist.
//
//  Zustand + Netz liegen im PageRevisionStore; hier ist nur die Darstellung.
//

import SwiftUI

struct RevisionsView: View {
    @EnvironmentObject private var store: PageRevisionStore
    @EnvironmentObject private var library: LibraryStore

    /// Wird nach erfolgreichem Wiederherstellen gerufen (Sync + Reload der
    /// offenen Seite) — verdrahtet der Aufrufer, damit die View nichts von
    /// SyncEngine und Bridge wissen muss.
    let onRestored: () -> Void
    let onClose: () -> Void

    @State private var selected: Int?
    @State private var confirmingRestore: PageRevision?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 720, height: 460)
        .background(BrandColor.bg)
        // Auswahl kommt aus der List (Klick, ↑/↓, VoiceOver) — die Vorschau
        // folgt ihr, egal auf welchem Weg sie sich bewegt.
        .onChange(of: selected) { _, id in
            guard let id else { return }
            Task { await store.loadPreview(revisionId: id) }
        }
        .alert(t("revisions.confirmTitle"), isPresented: confirmBinding) {
            Button(t("general.cancel"), role: .cancel) { confirmingRestore = nil }
            Button(t("revisions.restore")) {
                if let revision = confirmingRestore { restore(revision) }
                confirmingRestore = nil
            }
        } message: {
            Text(t("revisions.confirmMessage"))
        }
    }

    // MARK: - Kopf

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(t("revisions.title")).font(.headline)
                if let name = library.openPageName {
                    Text(name).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(t("general.close"), action: onClose)
                .keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }

    // MARK: - Inhalt

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .idle, .loading:
            centered { ProgressView().controlSize(.small) }
        case .failed(let message):
            centered {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(BrandColor.warning)
                        .accessibilityHidden(true)
                    Text(message).font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    // Offline-Fehler sind meist vorübergehend — ohne Knopf bliebe
                    // nur Schliessen und erneut ⌘⇧R.
                    if let pageId = store.pageId {
                        Button(t("revisions.retry")) {
                            Task { await store.load(pageId: pageId) }
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(24)
            }
        case .loaded where store.revisions.isEmpty:
            centered {
                Text(t("revisions.empty")).font(.callout).foregroundStyle(.secondary)
            }
        case .loaded:
            HStack(spacing: 0) {
                list.frame(width: 280)
                Divider()
                preview
            }
        }
    }

    /// Native Liste mit Auswahl: ↑/↓ und VoiceOver (Zeile = auswählbares
    /// Element) kommen von AppKit, die Markierung im Systemkontrast — vorher
    /// reagierten die Zeilen nur auf Mausklicks.
    private var list: some View {
        List(store.revisions, selection: $selected) { revision in
            RevisionRow(revision: revision)
                .tag(revision.id)
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .accessibilityLabel(t("revisions.title"))
    }

    @ViewBuilder
    private var preview: some View {
        if selected == nil {
            centered {
                Text(t("revisions.selectHint")).font(.callout).foregroundStyle(.secondary)
            }
        } else if let text = store.previewText {
            ScrollView {
                Text(text.isEmpty ? t("revisions.previewEmpty") : text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        } else {
            centered { ProgressView().controlSize(.small) }
        }
    }

    // MARK: - Fuss

    private var footer: some View {
        HStack {
            // Der Hinweis nimmt dem Knopf die Angst: Wiederherstellen ist selbst
            // eine Revision, der überschriebene Stand bleibt erhalten.
            Text(t("revisions.footerHint"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if store.isRestoring { ProgressView().controlSize(.small) }
            Button(t("revisions.restore")) {
                confirmingRestore = store.revisions.first { $0.id == selected }
            }
            .disabled(selected == nil || store.isRestoring)
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    // MARK: - Aktionen

    private func restore(_ revision: PageRevision) {
        Task {
            if await store.restore(revisionId: revision.id) {
                onRestored()
                onClose()
            }
        }
    }

    private var confirmBinding: Binding<Bool> {
        Binding(get: { confirmingRestore != nil },
                set: { if !$0 { confirmingRestore = nil } })
    }

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack { Spacer(); content(); Spacer() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Zeile

private struct RevisionRow: View {
    let revision: PageRevision

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if revision.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .accessibilityLabel(t("revisions.pinned"))
                }
                Text(revision.pinnedTitle ?? timeLabel)
                    .font(.callout)
                    .lineLimit(1)
            }
            Text(detailLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var timeLabel: String {
        guard let date = revision.createdAt else { return "—" }
        return Self.formatter(for: L10nStore.shared.localeCode).string(from: date)
    }

    /// Datumsformat in der App-Sprache (nicht der Systemsprache) und nur einmal
    /// je Sprache gebaut — vorher entstand pro Zeile und Render ein Formatter.
    private static var formatters: [String: DateFormatter] = [:]
    private static func formatter(for localeCode: String) -> DateFormatter {
        if let cached = formatters[localeCode] { return cached }
        let f = DateFormatter()
        f.locale = Locale(identifier: localeCode)
        f.dateStyle = .medium
        f.timeStyle = .short
        formatters[localeCode] = f
        return f
    }

    /// Umfang + Herkunft in einer Zeile. Die Zeichenzahl ist die Zahl, an der
    /// man „hier fehlt ein Abschnitt" erkennt — genau der Fall, für den die
    /// Ansicht gebaut ist.
    private var detailLabel: String {
        var parts: [String] = []
        // Benannte Revision: der Titel ist das Label, das Datum wandert hierher.
        if revision.pinnedTitle != nil { parts.append(timeLabel) }
        if revision.source == "restore" { parts.append(t("revisions.source.restore")) }
        if let chars = revision.chars { parts.append(NumberText.plural(chars, "picker.chars")) }
        if let client = revision.client, !client.isEmpty { parts.append(client) }
        else if let source = revision.source, !source.isEmpty, source != "restore" { parts.append(source) }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }
}
