//
//  SyncEngine+Push.swift
//  schreibwerkstatt-focuseditor
//
//  Push-Pfad der SyncEngine: drainiert die Outbox des LocalStore →
//  `PUT /content/pages/:id` mit `expected_updated_at` (exakte Server-ISO-Basis).
//  200 → Basis vorrücken; 409 → 3-Wege-Block-Merge (sonst Konflikt erfassen,
//  kein Last-Write-Wins); 404/423 → defensiv überspringen. Kern, State und
//  Konflikt-UI liegen in SyncEngine.swift; der Pull-Pfad in SyncEngine+Pull.swift.
//

import Foundation
import OSLog

extension SyncEngine {

    /// Repariert Seiten im Sync-Deadlock: Outbox-Eintrag vorhanden, aber keine
    /// `serverBaseISO` → Push überspringt ("noch nicht gepullt"), Pull überspringt
    /// (Outbox-Eintrag → Datenverlust-Schutz). Holt den Server-Stand dieser Seiten
    /// und setzt die Basis, damit der nächste Push gegen eine gültige Basis läuft.
    ///
    /// Läuft zu Beginn jedes `syncNow`-Durchlaufs VOR `pushOutbox()`. Idempotent:
    /// setzt nur, wenn noch keine Basis existiert. Seiten ohne Buch (Waisen) werden
    /// übersprungen — die erfasst der Push-Pfad als Konflikt.
    func repairStalledSyncBases() async {
        let entries: [OutboxEntry]
        do {
            entries = try await store.pendingOutbox()
        } catch {
            log.error("repairStalledSyncBases: Outbox-Lesefehler: \(error.localizedDescription, privacy: .public)")
            return
        }
        for entry in entries {
            // Nur Seiten ohne Basis reparieren (idempotent).
            guard stateStore.state.serverBaseISO[entry.pageId] == nil else { continue }
            // Seite ohne Buch → Waise, wird vom Push-Pfad als Konflikt erfasst.
            guard let stored = try? await store.page(id: entry.pageId),
                  stored.bookId != nil else { continue }
            // Server-Stand holen.
            guard let encodedId = entry.pageId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                  let resp = try? await reachableSend({
                      try await api.send("/content/pages/\(encodedId)",
                                         method: .GET,
                                         decode: PushResponse.self)
                  }),
                  let html = resp.html else {
                continue
            }
            // Basis setzen (idempotent: nur wenn noch keine existiert).
            await setSyncBase(pageId: entry.pageId, serverUpdatedAt: resp.updated_at, html: html)
            log.info("Sync-Deadlock repariert (Basis nachgesetzt): \(entry.pageId, privacy: .public)")
        }
    }

    func pushOutbox() async throws {
        let entries = try await store.pendingOutbox()
        let now = Date()
        for entry in entries {
            // Selbstheilung: die 'default'-Platzhalter-Seite (Boot-Fallback bei
            // leerem/ungesynctem Buch) ist kein echter Datensatz — kein Buch,
            // keine Server-Basis. Frühere Builds persistierten sie und sie blieb
            // als nie-pushbarer „default"-Konflikt zurück. Solche Leichen hier
            // restlos tilgen (Store + Outbox + State + evtl. Konflikt), statt sie
            // erneut als Konflikt zu erfassen. (Prävention: WebAssets.savePage
            // speichert 'default' gar nicht mehr.)
            if entry.pageId == Self.placeholderPageId {
                // `deletePage` nimmt den Merge-Ancestor als Spalte der Seite mit weg.
                try await store.deletePage(id: entry.pageId)
                stateStore.mutate { $0.serverBaseISO[entry.pageId] = nil }
                clearConflict(pageId: entry.pageId)
                log.info("Platzhalter-Seite '\(entry.pageId, privacy: .public)' getilgt (kein echter Datensatz)")
                continue
            }

            // Unaufgelöste Konflikte nicht erneut blind pushen.
            if conflicts.contains(where: { $0.pageId == entry.pageId }) { continue }

            // Serverseitig gesperrte Seite (423) noch in der Backoff-Frist → diesen
            // Tick überspringen, statt erneut nutzlos zu pushen.
            if let until = lockedUntil[entry.pageId], until > now { continue }

            guard let base = stateStore.state.serverBaseISO[entry.pageId] else {
                // Keine Server-Basis → PUT kann nur updaten, nicht anlegen
                // (Anlegen wäre POST /content/pages). Zwei Fälle unterscheiden:
                //   • Seite HAT ein Buch → sie ist nur noch nicht gepullt; der
                //     nächste Pull setzt die Basis, dann pusht sie. Still weiter.
                //   • Seite hat KEIN Buch → Waise (z. B. Rest eines früheren
                //     Servers): wird NIE gepullt (Pull ist buch-skopiert) und NIE
                //     gepusht → ihre lokalen Edits versickern lautlos. Darum als
                //     sichtbaren Konflikt erfassen (Toolbar-Indikator), statt sie
                //     ewig still zu überspringen. Lokaler Inhalt bleibt erhalten;
                //     der Konflikt-Guard oben verhindert nutzlose Re-Versuche.
                let storedBookId = ((try? await store.page(id: entry.pageId)) ?? nil)?.bookId
                if storedBookId == nil {
                    await recordConflict(pageId: entry.pageId, serverUpdatedAt: nil, serverEditorName: nil)
                    log.notice("Push-Sackgasse: Seite ohne Buch & ohne Server-Basis (Waise) als Konflikt erfasst: \(entry.pageId, privacy: .public)")
                } else {
                    log.info("Push übersprungen (keine Server-Basis, noch nicht gepullt): \(entry.pageId, privacy: .public)")
                }
                continue
            }

            let req = PushRequest(html: entry.html, expected_updated_at: base)
            do {
                let resp = try await reachableSend {
                    try await api.send("/content/pages/\(entry.pageId)",
                                       method: .PUT,
                                       body: req,
                                       decode: PushResponse.self)
                }
                // ERST Outbox atomar quittieren, DANN die Basis vorrücken — und nur,
                // wenn wirklich quittiert wurde. Hat der Nutzer WÄHREND des PUT erneut
                // gespeichert, trägt der neue Outbox-Eintrag eine andere Basis; die
                // Basis dann NICHT auf diesen überholten Push-Stand vorrücken (sonst
                // pushte der nächste Tick das neue HTML gegen eine Basis, die nicht zu
                // seinem Inhalt passt). Datenverlust-Schutz (s. markPushed-Vertrag).
                let quittiert = try await store.markPushed(
                    id: entry.pageId,
                    queuedAt: entry.queuedAt,
                    serverUpdatedAtMillis: ISOTime.millis(resp.updated_at) ?? entry.queuedAt)
                if quittiert {
                    // Merge-Ancestor = gerade gepushtes HTML (nun der Server-Stand).
                    try? await store.setServerBaseHtml(entry.html, id: entry.pageId)
                    stateStore.mutate {
                        $0.serverBaseISO[entry.pageId] = resp.updated_at   // exakte Server-ISO
                    }
                    // Erfolgreicher Push → eine etwaige Lock-Backoff-Frist aufheben.
                    lockedUntil[entry.pageId] = nil
                } else {
                    // Zwischenzeitlicher Save → der nächste Tick pusht den neuen Stand
                    // regulär (ggf. 409 → Block-Merge). Basis bewusst nicht vorgerückt.
                    log.info("Push nicht quittiert (Save während PUT): \(entry.pageId, privacy: .public)")
                }
            } catch let AuthError.server(status, _, body) where status == 409 {
                // Stale-Write → 3-Wege-Block-Merge versuchen, sonst Konflikt erfassen.
                let c = body.flatMap { try? JSONDecoder().decode(ConflictBody.self, from: $0) }
                await resolveConflict(entry: entry, conflict: c)
            } catch let AuthError.server(status, _, body) where status == 423 {
                // Seite serverseitig gesperrt (Lektorat) — später erneut versuchen,
                // aber mit Backoff: bis zum Ablauf der Frist überspringt der Push
                // diese Seite (kein Dauer-PUT bei langem Lock). Lokaler Stand bleibt.
                // Das genaue Lock-Ende aus dem 423-Body übernehmen, falls vorhanden
                // (langer Lektorats-Lock → keine nutzlosen 60-s-Re-Versuche/Log-Spam);
                // sonst auf den festen Backoff zurückfallen.
                let lock = body.flatMap { try? JSONDecoder().decode(LockBody.self, from: $0) }
                let until: Date
                if let expISO = lock?.expires_at, let exp = ISOTime.date(expISO), exp > now {
                    until = exp
                } else {
                    until = now.addingTimeInterval(lockBackoff)
                }
                lockedUntil[entry.pageId] = until
                log.info("Seite gesperrt (423) bis \(until.timeIntervalSince1970, privacy: .public): \(entry.pageId, privacy: .public)")
            } catch let AuthError.server(status, _, _) where status == 404 {
                // Seite existiert serverseitig nicht mehr (PUT legt nicht an) —
                // Basis verwerfen, Inhalt aber lokal behalten (kein Datenverlust).
                // OHNE Server-Basis würde der Push die Seite ab jetzt STILL für
                // immer überspringen (Sackgasse). Darum als sichtbaren Konflikt
                // erfassen, damit der Nutzer es bemerkt; der Konflikt-Guard oben
                // verhindert zugleich nutzlose Re-Pushes.
                stateStore.mutate { $0.serverBaseISO[entry.pageId] = nil }
                await recordConflict(pageId: entry.pageId, serverUpdatedAt: nil, serverEditorName: nil)
                log.notice("Seite serverseitig nicht gefunden (404), als Konflikt erfasst: \(entry.pageId, privacy: .public)")
            } catch AuthError.unauthorized {
                // Session beendet → ganzen Sync abbrechen (kein blindes Weiterpushen).
                throw AuthError.unauthorized
            } catch {
                // Netzfehler/Timeout o. Ä. → nur diesen Eintrag überspringen, die
                // restliche Outbox nicht blockieren. Nächster Tick versucht erneut.
                log.error("Push fehlgeschlagen \(entry.pageId, privacy: .public): \(error.localizedDescription, privacy: .public)")
                continue
            }
        }
    }

    /// 409-Auflösung per 3-Wege-Block-Merge in der WebView. Kollisionsfrei →
    /// gemergtes HTML mit der neuen Server-Basis erneut pushen; echte Block-
    /// Kollision oder kein Merge möglich → Konflikt erfassen (Editor-UI/Block-Merge).
    /// Verwirft NIE lokale Inhalte.
    func resolveConflict(entry: OutboxEntry, conflict c: ConflictBody?) async {
        let pid = entry.pageId

        // Kein WebView/Editor-Bundle → nicht auto-mergebar, echter Konflikt für die UI.
        guard let editor else {
            await recordConflict(pageId: pid,
                                 serverUpdatedAt: c?.server_updated_at,
                                 serverEditorName: c?.server_editor_name)
            log.notice("Konflikt \(pid, privacy: .public): kein Editor zum Mergen")
            return
        }

        // Aktuelles Server-HTML + neue Basis holen. Ein transienter Netzfehler hier
        // darf KEINEN klebrigen Konflikt setzen (würde die Seite bis Neustart vom
        // Sync ausschließen). Stattdessen still verschieben: Eintrag bleibt in der
        // Outbox ohne Konflikt-Flag, der nächste Push-Tick versucht es erneut.
        let serverPage: PushResponse
        do {
            serverPage = try await reachableSend {
                try await api.send("/content/pages/\(pid)",
                                   method: .GET,
                                   decode: PushResponse.self)
            }
        } catch {
            log.notice("Konflikt-Merge für \(pid, privacy: .public) verschoben: \(error.localizedDescription, privacy: .public)")
            return
        }

        let serverHtml = serverPage.html ?? ""
        // Merge-Ancestor der Seite (Spalte im Store; `nil` = keiner bekannt → der
        // Merge kann nur 2-Wege und landet in der Konflikt-UI).
        let base = try? await store.serverBaseHtml(id: pid)

        let outcome: MergeOutcome
        do {
            outcome = try await editor.merge3(base: base, local: entry.html, server: serverHtml)
        } catch {
            // Kein Editor-Bundle/WebView → nicht auto-mergebar, als Konflikt zur UI.
            await recordConflict(pageId: pid,
                                 serverUpdatedAt: serverPage.updated_at,
                                 serverEditorName: c?.server_editor_name)
            log.notice("Block-Merge nicht verfügbar für \(pid, privacy: .public) — Konflikt offen")
            return
        }

        guard outcome.conflictCount == 0 else {
            // Echte Block-Kollision → Konflikt-Modal des Editors.
            await recordConflict(pageId: pid,
                                 serverUpdatedAt: serverPage.updated_at,
                                 serverEditorName: c?.server_editor_name)
            log.notice("Block-Kollision bei \(pid, privacy: .public): \(outcome.conflictCount) Block/Blöcke — UI nötig")
            return
        }

        // Kollisionsfrei: gemergtes HTML mit der neuen Server-Basis erneut pushen.
        let req = PushRequest(html: outcome.merged, expected_updated_at: serverPage.updated_at)
        do {
            let resp = try await reachableSend {
                try await api.send("/content/pages/\(pid)",
                                   method: .PUT,
                                   body: req,
                                   decode: PushResponse.self)
            }
            let ms = ISOTime.millis(resp.updated_at) ?? entry.queuedAt
            // Gemergten Stand ERST lokal übernehmen + Outbox quittieren, DANN die
            // Basis vorrücken. Schlägt der lokale Write fehl, die Basis NICHT
            // vorrücken und den Eintrag NICHT quittieren: der nächste Tick merged
            // denselben Stand idempotent erneut, statt mit vorgerückter Basis das
            // alte lokale HTML gegen den bereits gemergten Server-Stand zu pushen
            // (das würde die eingemergten Server-Änderungen verlieren).
            let quittiert: Bool
            do {
                try await store.applyServerPage(id: pid, html: outcome.merged,
                                                pageName: nil, bookId: nil, chapterId: nil,
                                                serverUpdatedAtMillis: ms)
                quittiert = try await store.markPushed(id: pid, queuedAt: entry.queuedAt, serverUpdatedAtMillis: ms)
            } catch {
                log.error("Auto-Merge lokal persistieren fehlgeschlagen \(pid, privacy: .public): \(error.localizedDescription, privacy: .public) — Basis nicht vorgerückt, Retry beim nächsten Tick")
                return
            }
            guard quittiert else {
                // Save während des Merge-PUT → der neue Outbox-Eintrag wird beim
                // nächsten Tick frisch gemergt. Basis NICHT vorrücken (sonst ginge
                // der zwischenzeitliche Edit gegen die falsche Basis).
                log.notice("Auto-Merge: Save während PUT — Basis nicht vorgerückt, Retry: \(pid, privacy: .public)")
                return
            }
            autoMergeRe409[pid] = nil   // erfolgreich konvergiert → Re-Zähler zurücksetzen
            try? await store.setServerBaseHtml(outcome.merged, id: pid)
            stateStore.mutate { $0.serverBaseISO[pid] = resp.updated_at }
            clearConflict(pageId: pid)
            // Offene, saubere Seite still mit dem Merge-Ergebnis aktualisieren.
            if editor.openPageId == pid, !editor.isDirty(pid) {
                await editor.reloadPage(pageId: pid, html: outcome.merged, baseUpdatedAt: ms)
            }
            log.info("Auto-Merge gepusht: \(pid, privacy: .public)")
        } catch let AuthError.server(status, _, _) where status == 409 {
            // Erneutes Rennen. Begrenzt oft still neu versuchen; danach als
            // SICHTBAREN Konflikt erfassen, statt jeden Tick einen vollen
            // Merge-Roundtrip zu fahren, der nie konvergiert (Live-Lock-Schutz).
            let n = (autoMergeRe409[pid] ?? 0) + 1
            autoMergeRe409[pid] = n
            if n >= maxAutoMergeRetries {
                autoMergeRe409[pid] = nil
                await recordConflict(pageId: pid,
                                     serverUpdatedAt: serverPage.updated_at,
                                     serverEditorName: c?.server_editor_name)
                log.notice("Auto-Merge \(pid, privacy: .public): \(n, privacy: .public)× erneut 409 — als sichtbaren Konflikt erfasst")
            } else {
                log.notice("Auto-Merge verlor das Rennen (erneut 409, \(n, privacy: .public)/\(self.maxAutoMergeRetries, privacy: .public)): \(pid, privacy: .public)")
            }
        } catch {
            log.error("Auto-Merge-Push fehlgeschlagen \(pid, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
