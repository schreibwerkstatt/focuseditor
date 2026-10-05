//
//  SyncEngine+Conflicts.swift
//  schreibwerkstatt-focuseditor
//
//  Manuelle Auflösung durch den Nutzer: Konflikt-Ansicht (lokal ⇄ Server),
//  „Meinen Stand behalten" / „Server-Stand übernehmen" — und derselbe
//  Übernahme-Pfad für eine wiederhergestellte frühere Fassung. Ausgelagert aus
//  SyncEngine.swift (Zeilen-Guard); der automatische 409-Merge liegt im
//  Push-Pfad (SyncEngine+Push.swift).
//

import Foundation
import OSLog

extension SyncEngine {

    /// Lokaler (ungepushter) + frischer Server-Stand eines Konflikts — Grundlage
    /// für die Nebeneinander-Ansicht der `ConflictResolutionView`. Lokal aus der
    /// Outbox (Fallback: Store), Server per Online-GET (wie `resolveConflict`).
    /// `nil`, wenn der Server-Abruf scheitert (offline) oder kein lokaler Stand
    /// (mehr) vorliegt — die UI zeigt dann einen Lade-/Fehlerzustand.
    struct ConflictContents: Equatable {
        let localHtml: String
        let serverHtml: String
        let serverUpdatedAt: String?
    }

    func conflictContents(pageId pid: String) async -> ConflictContents? {
        let localHtml: String
        if let entry = ((try? await store.pendingOutbox()) ?? []).first(where: { $0.pageId == pid }) {
            localHtml = entry.html
        } else if let page = (try? await store.page(id: pid)) ?? nil {
            localHtml = page.html
        } else {
            return nil
        }
        guard let serverPage = try? await api.send("/content/pages/\(pid)",
                                                   method: .GET,
                                                   decode: PushResponse.self) else {
            return nil
        }
        return ConflictContents(localHtml: localHtml,
                                serverHtml: serverPage.html ?? "",
                                serverUpdatedAt: serverPage.updated_at)
    }

    /// Manuelle Konflikt-Auflösung aus der UI. Verwirft Inhalte NUR auf
    /// ausdrückliche Nutzer-Wahl (CLAUDE.md: kein automatisches Verwerfen).
    ///  • `keepLocal == true`: lokaler Stand erzwingt sich gegen den Server
    ///    (Force-Push). Wir holen den frischen Server-`updated_at` und pushen das
    ///    lokale Outbox-HTML mit genau dieser Basis → der Server-Stand wird
    ///    überschrieben. Damit löst sich auch ein „klebriger" Konflikt, dessen
    ///    Auto-Merge an einer falschen Basis (z. B. nach Serverwechsel) scheiterte.
    ///  • `keepLocal == false`: Server-Stand übernehmen, die lokale ungepushte
    ///    Änderung verwerfen (Outbox-Eintrag droppen, offene Seite neu laden).
    func resolveConflict(pageId pid: String, keepLocal: Bool) async {
        guard conflicts.contains(where: { $0.pageId == pid }) else { return }

        // Frischen Server-Stand holen — liefert die exakte `updated_at`-Basis,
        // die das Überschreiben (PUT) bzw. das Übernehmen braucht.
        let serverPage: PushResponse
        do {
            serverPage = try await api.send("/content/pages/\(pid)",
                                            method: .GET,
                                            decode: PushResponse.self)
        } catch let AuthError.server(status, _, _) where status == 404 {
            // Seite serverseitig weg (PUT kann nicht anlegen). Konflikt fällt weg,
            // der lokale Inhalt bleibt erhalten (kein Anlage-Pfad im Client).
            clearConflict(pageId: pid)
            lastError = t("sync.conflict.serverGone")
            log.notice("Konflikt-Auflösung \(pid, privacy: .public): Seite serverseitig nicht (mehr) vorhanden")
            return
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            log.error("Konflikt-Auflösung \(pid, privacy: .public): Server-GET fehlgeschlagen: \(self.lastError ?? "?", privacy: .public)")
            return
        }

        let entry = ((try? await store.pendingOutbox()) ?? []).first { $0.pageId == pid }

        if keepLocal {
            guard let entry else {
                // Kein lokaler Outbox-Stand mehr (z. B. zwischenzeitlich quittiert)
                // → nichts zu erzwingen, nur Basis auf den Server stellen.
                try? await store.setServerBaseHtml(serverPage.html ?? "", id: pid)
                stateStore.mutate { $0.serverBaseISO[pid] = serverPage.updated_at }
                clearConflict(pageId: pid)
                return
            }
            let req = PushRequest(html: entry.html, expected_updated_at: serverPage.updated_at)
            do {
                let resp = try await api.send("/content/pages/\(pid)",
                                              method: .PUT,
                                              body: req,
                                              decode: PushResponse.self)
                let ms = ISOTime.millis(resp.updated_at) ?? entry.queuedAt
                // Outbox atomar quittieren; Basis nur vorrücken, wenn der Eintrag
                // unverändert war (sonst trägt ein zwischenzeitlicher Save eine
                // andere Basis und wird beim nächsten Tick regulär gepusht).
                let quittiert = (try? await store.markPushed(id: pid, queuedAt: entry.queuedAt, serverUpdatedAtMillis: ms)) ?? false
                if quittiert {
                    try? await store.setServerBaseHtml(entry.html, id: pid)
                    stateStore.mutate { $0.serverBaseISO[pid] = resp.updated_at }
                }
                clearConflict(pageId: pid)
                lastError = nil
                lastSyncedAt = Date()
                log.info("Konflikt aufgelöst (lokaler Stand erzwungen): \(pid, privacy: .public)")
            } catch {
                // Force-Push misslungen (z. B. erneutes Rennen) → Konflikt bleibt
                // bestehen, der Nutzer kann es erneut versuchen.
                lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                log.error("Force-Push \(pid, privacy: .public) fehlgeschlagen: \(self.lastError ?? "?", privacy: .public)")
            }
        } else {
            // Server-Stand übernehmen, lokale Änderung verwerfen. Nutzer hat
            // „Server übernehmen" gewählt → auch eine dirty offene Seite wird ersetzt.
            guard await adoptServerState(pageId: pid, serverPage: serverPage, entry: entry) else { return }
            log.info("Konflikt aufgelöst (Server-Stand übernommen): \(pid, privacy: .public)")
        }

        pendingCount = (try? await store.pendingOutbox().count) ?? pendingCount
    }

    /// Nach einer serverseitig wiederhergestellten früheren Fassung: den
    /// Server-Stand der Seite VERBINDLICH übernehmen — wie „Server übernehmen"
    /// im Konflikt. Ein gewöhnlicher Pull reicht nicht: er überspringt eine Seite
    /// mit Outbox-Eintrag oder dirty Editor, und genau dann (etwa nach dem
    /// versehentlichen ⌘Z, das die Wiederherstellung auslöste) pushte der alte
    /// lokale Stand die Wiederherstellung per Merge wieder weg. Der Aufrufer hat
    /// vorher gesichert und synchronisiert (`PageRevisionStore.prepare`), damit
    /// der verworfene lokale Stand selbst als Revision am Server liegt.
    @discardableResult
    func adoptServerStateAfterRestore(pageId pid: String) async -> Bool {
        guard let encodedId = pid.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let serverPage = try? await api.send("/content/pages/\(encodedId)",
                                                   method: .GET,
                                                   decode: PushResponse.self) else {
            log.notice("Restore-Übernahme \(pid, privacy: .public): Server-GET fehlgeschlagen — regulärer Pull holt nach")
            return false
        }
        let entry = ((try? await store.pendingOutbox()) ?? []).first { $0.pageId == pid }
        return await adoptServerState(pageId: pid, serverPage: serverPage, entry: entry)
    }

    /// Server-Stand lokal übernehmen, den Outbox-Eintrag droppen (falls seit dem
    /// Lesen unverändert), Basis vorrücken, Konflikt lösen und die offene Seite
    /// — auch dirty — neu laden. Erst lokal schreiben, DANN die Basis vorrücken:
    /// sonst bliebe bei einem fehlgeschlagenen Write der alte lokale Stand mit
    /// vorgerückter Basis zurück und käme über einen 409-Re-Merge wieder hoch.
    private func adoptServerState(pageId pid: String, serverPage: PushResponse,
                                  entry: OutboxEntry?) async -> Bool {
        let serverHtml = serverPage.html ?? ""
        let ms = ISOTime.millis(serverPage.updated_at) ?? 0
        do {
            try await store.applyServerPage(id: pid, html: serverHtml,
                                            pageName: nil, bookId: nil, chapterId: nil,
                                            serverUpdatedAtMillis: ms)
            if let entry {
                try await store.markPushed(id: pid, queuedAt: entry.queuedAt, serverUpdatedAtMillis: ms)
            }
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            log.error("Server-Stand \(pid, privacy: .public) lokal übernehmen fehlgeschlagen: \(self.lastError ?? "?", privacy: .public)")
            return false
        }
        try? await store.setServerBaseHtml(serverHtml, id: pid)
        stateStore.mutate { $0.serverBaseISO[pid] = serverPage.updated_at }
        clearConflict(pageId: pid)
        lastError = nil
        if editor?.openPageId == pid {
            await editor?.reloadPage(pageId: pid, html: serverHtml, baseUpdatedAt: ms, force: true)
        }
        pendingCount = (try? await store.pendingOutbox().count) ?? pendingCount
        return true
    }
}
