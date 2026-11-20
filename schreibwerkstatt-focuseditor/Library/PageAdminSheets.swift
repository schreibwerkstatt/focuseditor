//
//  PageAdminSheets.swift
//  schreibwerkstatt-focuseditor
//
//  Die drei kleinen Dialoge zu PageAdminController: Seite anlegen (⌘N),
//  umbenennen, löschen.
//
//  Alle drei sind bewusst winzig und tastaturbedienbar (⏎ bestätigt, ⎋ bricht
//  ab) — sie stehen zwischen dem Nutzer und dem Schreiben, nicht daneben.
//
//  Der Offline-Hinweis steht im Anlegen-Dialog, nicht als Fehlermeldung
//  hinterher: eine neue Seite braucht den Server (POST, s. PageAdminController),
//  und das erfährt man besser vorher als nach dem Tippen des Namens.
//

import SwiftUI

// MARK: - Neue Seite

struct NewPageSheet: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var pageAdmin: PageAdminController
    /// Netzlage — eine neue Seite braucht den Server (POST); der Hinweis
    /// erscheint VOR dem Tippen des Namens, nicht als Fehler danach.
    @EnvironmentObject private var sync: SyncEngine

    let onClose: () -> Void

    @State private var name = ""
    /// Kapitel, in das die Seite soll — `nil` = auf Buchebene ans Ende.
    @State private var chapterId: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(t("pageadmin.new.title")).font(.headline)

            TextField(t("pageadmin.new.placeholder"), text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(create)

            if !chapters.isEmpty {
                Picker(t("pageadmin.new.chapter"), selection: $chapterId) {
                    Text(t("pageadmin.new.noChapter")).tag(Int?.none)
                    ForEach(chapters, id: \.id) { chapter in
                        Text(chapter.name).tag(Int?.some(chapter.id))
                    }
                }
            }

            if !sync.isOnline {
                Label(t("pageadmin.new.offlineHint"), systemImage: "wifi.slash")
                    .font(.caption)
                    .foregroundStyle(BrandColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if case .failed(let message) = pageAdmin.phase {
                Text(message).font(.caption).foregroundStyle(BrandColor.error)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button(t("general.cancel")) { onClose() }
                    .keyboardShortcut(.cancelAction)
                Button(t("pageadmin.new.create"), action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || pageAdmin.phase == .working)
            }
        }
        .padding(20)
        .frame(width: 380)
        .background(BrandColor.bg)
        // Ein Fehler aus einem früheren Dialog gehört nicht in diesen.
        .onAppear { pageAdmin.dismissError() }
    }

    /// Kapitel des aktiven Buchs, in der Reihenfolge des Baums und ohne
    /// Dubletten — aus den Picker-Zeilen abgeleitet, weil der Client keine
    /// eigene Kapitelliste führt. Gezeigt wird der volle Pfad, sonst sind zwei
    /// gleichnamige Unterkapitel nicht unterscheidbar.
    private var chapters: [(id: Int, name: String)] {
        var seen = Set<String>()
        var out: [(id: Int, name: String)] = []
        for row in library.pages where !row.chapterPath.isEmpty {
            let label = row.chapterPath.joined(separator: " › ")
            guard let chapterId = row.chapterId, seen.insert(label).inserted else { continue }
            out.append((id: chapterId, name: label))
        }
        return out
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            await pageAdmin.createPage(named: trimmed, chapterId: chapterId)
            if pageAdmin.phase == .idle { onClose() }
        }
    }
}

// MARK: - Umbenennen

struct RenamePageSheet: View {
    @EnvironmentObject private var pageAdmin: PageAdminController

    let page: PagePickerRow
    let onClose: () -> Void

    @State private var name: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(t("pageadmin.rename.title")).font(.headline)

            TextField(t("pageadmin.rename.placeholder"), text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(rename)

            if case .failed(let message) = pageAdmin.phase {
                Text(message).font(.caption).foregroundStyle(BrandColor.error)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button(t("general.cancel")) { onClose() }
                    .keyboardShortcut(.cancelAction)
                Button(t("pageadmin.rename.apply"), action: rename)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || pageAdmin.phase == .working)
            }
        }
        .padding(20)
        .frame(width: 380)
        .background(BrandColor.bg)
        .onAppear {
            name = page.name
            pageAdmin.dismissError()
        }
    }

    private func rename() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != page.name else { return onClose() }
        Task {
            await pageAdmin.renamePage(id: page.id, to: trimmed)
            if pageAdmin.phase == .idle { onClose() }
        }
    }
}
