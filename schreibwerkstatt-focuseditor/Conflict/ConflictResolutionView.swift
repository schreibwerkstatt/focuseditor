//
//  ConflictResolutionView.swift
//  schreibwerkstatt-focuseditor
//
//  Sheet zur informierten Konflikt-Auflösung: zeigt den lokalen und den
//  Server-Stand NEBENEINANDER (mit absatzweisem Diff-Highlight), nennt den
//  serverseitigen Bearbeiter + Zeitpunkt und lässt den Nutzer bewusst wählen,
//  welcher Stand gewinnt. Löst das alte „blind im Toolbar-Dropdown lokal/server
//  wählen" ab. Die eigentliche Auflösung macht weiter `SyncEngine.resolveConflict`
//  (Force-Push bzw. Server übernehmen) — hier wird nur informiert gewählt.
//

import SwiftUI

struct ConflictResolutionView: View {
    let conflict: SyncEngine.Conflict

    @EnvironmentObject private var sync: SyncEngine
    @EnvironmentObject private var loc: LocalizationController
    @Environment(\.dismiss) private var dismiss

    private enum LoadState: Equatable {
        case loading
        case failed
        case loaded(local: [DiffParagraph], server: [DiffParagraph])
    }

    @State private var state: LoadState = .loading
    @State private var resolving = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 720, minHeight: 460)
        .background(BrandColor.bg)
        .task { await load() }
    }

    // MARK: - Kopf

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(conflict.pageName ?? conflict.pageId)
                .font(BrandFont.serif(16, weight: .semibold))
                .foregroundStyle(BrandColor.text)
            Text(subtitle)
                .font(BrandFont.sans(11))
                .foregroundStyle(BrandColor.muted)
            // Die Wahl unten betrifft nur kollidierende Absätze (3-Wege-Merge,
            // `SyncEngine.resolveConflict`) — der Diff zeigt dagegen alles.
            Text(t("conflict.hint"))
                .font(BrandFont.sans(11))
                .foregroundStyle(BrandColor.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    /// „Server geändert von <Name> · <relativ>" — so viel, wie der 409 hergibt.
    private var subtitle: String {
        let who = conflict.serverEditorName?.trimmingCharacters(in: .whitespaces)
        let when = conflict.serverUpdatedAt.flatMap { ISOTime.millis($0) }
            .map { Date(timeIntervalSince1970: Double($0) / 1000) }
        if let who, !who.isEmpty, let when {
            // `loc.locale` explizit: hält die EnvironmentObject-Abhängigkeit, damit
            // das Sheet beim Sprachwechsel neu rendert.
            return t("conflict.subtitle.byWhen",
                     ["who": who, "when": RelativeTime.string(for: when, localeCode: loc.locale)])
        }
        if let who, !who.isEmpty {
            return t("conflict.subtitle.by", ["who": who])
        }
        return t("conflict.subtitle.generic")
    }

    // MARK: - Inhalt (Nebeneinander)

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            ProgressView().controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            VStack(spacing: 10) {
                Image(systemName: "wifi.slash").foregroundStyle(BrandColor.muted)
                    .accessibilityHidden(true)
                Text(t("conflict.loadFailed"))
                    .font(BrandFont.sans(12))
                    .foregroundStyle(BrandColor.muted)
                    .multilineTextAlignment(.center)
                // Transienter Lade-/Netzfehler → erneut versuchen, ohne das Sheet zu
                // schliessen und neu öffnen zu müssen (wie der Picker-Leerzustand).
                Button(t("content.retry")) {
                    state = .loading
                    Task { await load() }
                }
                .buttonStyle(.plain)
                .font(BrandFont.sans(11, weight: .semibold))
                .foregroundStyle(BrandColor.primary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
        case let .loaded(local, server):
            HStack(spacing: 0) {
                column(title: t("conflict.column.local"), paragraphs: local, tint: BrandColor.success)
                Divider()
                column(title: t("conflict.column.server"), paragraphs: server, tint: BrandColor.primary)
            }
        }
    }

    private func column(title: String, paragraphs: [DiffParagraph], tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(BrandFont.sans(11, weight: .semibold))
                .foregroundStyle(BrandColor.subtle)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .accessibilityAddTraits(.isHeader)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if paragraphs.isEmpty {
                        Text(t("conflict.empty"))
                            .font(BrandFont.sans(11))
                            .foregroundStyle(BrandColor.faint)
                            .padding(.horizontal, 14)
                            .padding(.top, 10)
                    }
                    ForEach(paragraphs) { p in
                        Text(p.text)
                            .font(BrandFont.serif(13))
                            .foregroundStyle(BrandColor.text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(p.changed ? tint.opacity(0.16) : Color.clear)
                            )
                            .overlay(alignment: .leading) {
                                if p.changed {
                                    Rectangle().fill(tint).frame(width: 2.5)
                                }
                            }
                            // „Geändert" wird sonst NUR über Farbe/Balken
                            // transportiert — für VoiceOver explizit ansagen.
                            .accessibilityLabel(p.changed
                                                ? t("conflict.a11y.changed", ["text": p.text])
                                                : p.text)
                    }
                }
                .padding(12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Fuß (Aktionen)

    private var footer: some View {
        HStack {
            Button(t("general.cancel")) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            if resolving { ProgressView().controlSize(.small) }
            Button(t("conflict.keepServer")) { resolve(keepLocal: false) }
                .disabled(resolving || state == .loading)
            Button(t("conflict.keepLocal")) { resolve(keepLocal: true) }
                .keyboardShortcut(.defaultAction)
                .disabled(resolving || state == .loading)
        }
        .padding(16)
    }

    // MARK: - Laden / Auflösen

    private func load() async {
        guard let c = await sync.conflictContents(pageId: conflict.pageId) else {
            state = .failed
            return
        }
        let localParas = ConflictText.paragraphs(fromHTML: c.localHtml)
        let serverParas = ConflictText.paragraphs(fromHTML: c.serverHtml)
        let diff = ConflictDiff.compare(local: localParas, server: serverParas)
        state = .loaded(local: diff.local, server: diff.server)
    }

    private func resolve(keepLocal: Bool) {
        resolving = true
        Task {
            await sync.resolveConflict(pageId: conflict.pageId, keepLocal: keepLocal)
            dismiss()
        }
    }
}
