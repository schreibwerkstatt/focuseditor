//
//  SyncEngine+Conflicts.swift
//  schreibwerkstatt-focuseditor
//
//  Manuelle Auflösung durch den Nutzer: Konflikt-Ansicht (lokal ⇄ Server),
//  „Meinen Stand behalten" / „Server-Stand übernehmen" (je nur für die
//  kollidierenden Absätze, per 3-Wege-Block-Merge) — und der verbindliche
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

    /// Manuelle Konflikt-Auflösung aus der UI. Die Wahl betrifft NUR die
    /// kollidierenden Absätze: beide Varianten rechnen denselben 3-Wege-Block-
    /// Merge wie der Auto-Merge im Push-Pfad, damit Absätze, die nur EINE Seite
    /// geändert hat, nicht still verloren gehen.
    ///  • `keepLocal == true`: Kollisionen → lokal, Rest gemergt (`merged`),
    ///    gegen den frischen Server-`updated_at` gepusht.
    ///  • `keepLocal == false`: Kollisionen → Server, Rest gemergt
    ///    (`mergedRemote`). Bleibt dabei nichts Lokales übrig, wird der
    ///    Server-Stand schlicht übernommen (`adoptServerState`).
    /// Rückfall auf „alles oder nichts" (rohes Outbox-HTML erzwingen bzw.
    /// Server-Stand übernehmen) nur ohne Merge-Ancestor oder wenn der Merge
    /// wirft/in den Timeout läuft. Der Force-Push bleibt damit der Ausweg aus
    /// einem „klebrigen" Konflikt mit falscher Basis (z. B. nach Serverwechsel).
    /// Verworfen wird nur auf ausdrückliche Nutzer-Wahl (CLAUDE.md).
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
        let serverHtml = serverPage.html ?? ""
        let outcome: MergeOutcome? = if let entry {
            await resolutionMerge(pageId: pid, local: entry.html, server: serverHtml)
        } else {
            nil
        }

        if keepLocal {
            guard let entry else {
                // Kein lokaler Outbox-Stand mehr (z. B. zwischenzeitlich quittiert)
                // → nichts zu erzwingen, nur Basis auf den Server stellen.
                try? await store.setServerBaseHtml(serverHtml, id: pid)
                stateStore.mutate { $0.serverBaseISO[pid] = serverPage.updated_at }
                clearConflict(pageId: pid)
                return
            }
            let html = outcome?.merged ?? entry.html
            await pushResolution(pageId: pid, html: html, merged: outcome != nil,
                                 entry: entry, serverPage: serverPage)
        } else if let entry, let outcome, let remote = outcome.mergedRemote,
                  !outcome.remoteUnchanged, remote != serverHtml {
            // Lokale Änderungen ohne Kollision bleiben erhalten → pushen.
            await pushResolution(pageId: pid, html: remote, merged: true,
                                 entry: entry, serverPage: serverPage)
        } else {
            // Server-Stand übernehmen (nichts Lokales ohne Kollision übrig, oder
            // kein Merge möglich). Nutzer hat „Server übernehmen" gewählt → auch
            // eine dirty offene Seite wird ersetzt.
            guard await adoptServerState(pageId: pid, serverPage: serverPage, entry: entry) else { return }
            log.info("Konflikt aufgelöst (Server-Stand übernommen): \(pid, privacy: .public)")
        }

        pendingCount = (try? await store.pendingOutbox().count) ?? pendingCount
    }

    /// 3-Wege-Merge für die manuelle Auflösung. `nil` = kein Merge möglich
    /// (kein Editor, kein Merge-Ancestor, Merge wirft/Timeout) → der Aufrufer
    /// fällt auf das alte „alles oder nichts" zurück.
    private func resolutionMerge(pageId pid: String, local: String, server: String) async -> MergeOutcome? {
        guard let editor,
              let base = (try? await store.serverBaseHtml(id: pid)) ?? nil,
              !base.isEmpty else {
            log.notice("Konflikt-Auflösung \(pid, privacy: .public): kein Merge-Ancestor/Editor — ganze Seite")
            return nil
        }
        do {
            return try await editor.merge3(base: base, local: local, server: server)
        } catch {
            let detail = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
                ?? error.localizedDescription
            log.notice("Konflikt-Auflösung \(pid, privacy: .public): Merge nicht verfügbar — ganze Seite: \(detail, privacy: .public)")
            return nil
        }
    }

    /// Pusht den aufgelösten Stand gegen den frischen Server-`updated_at`.
    /// `merged == false` ist der Force-Push des rohen Outbox-HTML (Rückfall):
    /// Spiegel und Editor tragen diesen Stand schon. `merged == true`: das
    /// gepushte HTML enthält auch Server-Absätze → in den Spiegel schreiben und
    /// die offene Seite neu laden.
    private func pushResolution(pageId pid: String, html: String, merged: Bool,
                                entry: OutboxEntry, serverPage: PushResponse) async {
        let req = PushRequest(html: html, expected_updated_at: serverPage.updated_at)
        do {
            let resp = try await api.send("/content/pages/\(pid)",
                                          method: .PUT,
                                          body: req,
                                          decode: PushResponse.self)
            let ms = ISOTime.millis(resp.updated_at) ?? entry.queuedAt
            // Outbox atomar quittieren; Basis nur vorrücken, wenn der Eintrag
            // unverändert war (sonst trägt ein zwischenzeitlicher Save eine
            // andere Basis und wird beim nächsten Tick regulär gepusht).
            let quittiert: Bool
            if merged {
                quittiert = (try? await store.applyMergedPush(id: pid, html: html, queuedAt: entry.queuedAt,
                                                              serverUpdatedAtMillis: ms)) ?? false
            } else {
                quittiert = (try? await store.markPushed(id: pid, queuedAt: entry.queuedAt,
                                                         serverUpdatedAtMillis: ms)) ?? false
            }
            if quittiert {
                try? await store.setServerBaseHtml(html, id: pid)
                stateStore.mutate { $0.serverBaseISO[pid] = resp.updated_at }
                if merged {
                    // Der Editor trägt noch `entry.html`. Lehnt er den Reload ab
                    // (inzwischen getippt) oder liegt schon ein neuer Save vor,
                    // wird `entry.html` der Ancestor und die ISO-Basis bleibt alt
                    // → der nächste Push merged nur die jüngsten Zeichen ein.
                    let fallback = BaseSnapshot(iso: serverPage.updated_at, ancestor: entry.html)
                    await reloadOpenPageOrRevertBase(pid, html: html, ms: ms, previous: fallback)
                }
            } else if merged {
                // Save während des PUT: der neue Eintrag schreibt `entry.html`
                // fort (wie im Auto-Merge-Pfad) → Ancestor, ISO-Basis bleibt alt.
                try? await store.setServerBaseHtml(entry.html, id: pid)
            }
            clearConflict(pageId: pid)
            lastError = nil
            lastSyncedAt = Date()
            log.info("Konflikt aufgelöst (\(merged ? "gemergt" : "lokaler Stand erzwungen", privacy: .public)): \(pid, privacy: .public)")
        } catch {
            // Push misslungen (z. B. erneutes Rennen) → Konflikt bleibt
            // bestehen, der Nutzer kann es erneut versuchen.
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            log.error("Konflikt-Push \(pid, privacy: .public) fehlgeschlagen: \(self.lastError ?? "?", privacy: .public)")
        }
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
