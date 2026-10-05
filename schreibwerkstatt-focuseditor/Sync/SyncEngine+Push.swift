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
    ///
    /// Datenverlust-Schutz: die Basis wird nur dann auf den aktuellen Server-Stand
    /// gesetzt, wenn der Server seit der Basis der LOKALEN Änderung unverändert ist
    /// (gleicher Stempel). Sonst — Server inzwischen bewegt, oder die lokale Basis
    /// ist unbekannt (verlorener/korrupter Sync-Zustand) — wäre „Basis = jetzt" ein
    /// stilles Last-Write-Wins über fremde Änderungen. Dann sofort der 3-Wege-Merge
    /// (kollisionsfrei → still, sonst Konflikt-UI). Ein 404 (Seite serverseitig
    /// weg) wird als sichtbarer Konflikt erfasst, statt jeden Tick neu zu fragen.
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
            // Offener Konflikt → die UI entscheidet, kein erneuter Server-Abruf.
            if conflicts.contains(where: { $0.pageId == entry.pageId }) { continue }
            // Seite ohne Buch → Waise, wird vom Push-Pfad als Konflikt erfasst.
            guard let stored = try? await store.page(id: entry.pageId),
                  stored.bookId != nil else { continue }
            // Server-Stand holen.
            guard let encodedId = entry.pageId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { continue }
            let resp: PushResponse
            do {
                resp = try await reachableSend {
                    try await api.send("/content/pages/\(encodedId)",
                                       method: .GET,
                                       decode: PushResponse.self)
                }
            } catch let AuthError.server(status, _, _) where status == 404 {
                await recordConflict(pageId: entry.pageId, serverUpdatedAt: nil, serverEditorName: nil)
                log.notice("Sync-Basis-Reparatur: Seite serverseitig weg (404), als Konflikt erfasst: \(entry.pageId, privacy: .public)")
                continue
            } catch {
                continue
            }
            guard !isSuperseded, let html = resp.html else { continue }
            let localBase = entry.baseUpdatedAt ?? stored.baseUpdatedAt
            if let localBase, ISOTime.millis(resp.updated_at) == localBase {
                // Server seit der Basis der lokalen Änderung unverändert → gefahrlos.
                await setSyncBase(pageId: entry.pageId, serverUpdatedAt: resp.updated_at, html: html)
                log.info("Sync-Deadlock repariert (Basis nachgesetzt): \(entry.pageId, privacy: .public)")
            } else {
                // Server bewegt oder Basis unbekannt → mergen statt überschreiben.
                log.notice("Sync-Basis-Reparatur: Server-Stand weicht ab → Merge: \(entry.pageId, privacy: .public)")
                await resolveConflict(entry: entry, conflict: nil)
            }
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
                // Serverwechsel während des PUT → nichts mehr in den (neuen) Spiegel schreiben.
                try ensureNotSuperseded()
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
                    // Zwischenzeitlicher Save → der neue Outbox-Eintrag bleibt und geht
                    // beim nächsten Tick raus. Die Basis trotzdem vorrücken: der Server
                    // hält jetzt GENAU `entry.html` unter `resp.updated_at`, und der neue
                    // Eintrag ist eine Fortschreibung desselben Editor-Stands. Bliebe die
                    // alte Basis stehen, liefe der nächste Push in ein 409 gegen den
                    // eigenen Text und der Merge meldete eine Kollision (alle drei
                    // Fassungen des Absatzes verschieden) — Konflikt-Modal gegen sich
                    // selbst, bei „Server übernehmen" mit Verlust der jüngsten Zeichen.
                    try? await store.setServerBaseHtml(entry.html, id: entry.pageId)
                    stateStore.mutate { $0.serverBaseISO[entry.pageId] = resp.updated_at }
                    lockedUntil[entry.pageId] = nil
                    log.info("Push nicht quittiert (Save während PUT), Basis vorgerückt: \(entry.pageId, privacy: .public)")
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
            } catch SyncSuperseded.serverSwitch {
                throw SyncSuperseded.serverSwitch
            } catch {
                // Netzfehler/Timeout o. Ä. → nur diesen Eintrag überspringen, die
                // restliche Outbox nicht blockieren. Nächster Tick versucht erneut.
                // Ein Transport-Fehler ist Alltag (offline), ein Server-Fehler
                // (5xx, 413 …) dagegen ein Problem, das sich nicht von selbst
                // löst — der zählt für die Status-Anzeige.
                if case AuthError.server = error { runIssues += 1 }
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
        guard !isSuperseded else { return }

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
            // Ursache mitloggen: ein JS-Fehler im Merge (WebKit legt die Exception-
            // Meldung in den userInfo) sieht sonst genauso aus wie „kein Editor".
            let detail = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
                ?? error.localizedDescription
            log.notice("Block-Merge nicht verfügbar für \(pid, privacy: .public) — Konflikt offen: \(detail, privacy: .public)")
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
            guard !isSuperseded else { return }
            let ms = ISOTime.millis(resp.updated_at) ?? entry.queuedAt
            let previous = await baseSnapshot(pid)
            // Gemergten Stand lokal übernehmen + Outbox quittieren in EINER
            // Transaktion — und nur, wenn der Outbox-Eintrag seit dem Lesen
            // unverändert ist. Früher wurde die Seitenzeile VOR dieser Prüfung
            // überschrieben: kam während des Merge ein Save, stand im Spiegel das
            // Merge-Ergebnis ohne die jüngsten Zeichen, und das nächste Öffnen der
            // Seite lud genau diesen Stand. Schlägt der Write fehl, Basis NICHT
            // vorrücken: der nächste Tick merged idempotent erneut.
            let quittiert: Bool
            do {
                quittiert = try await store.applyMergedPush(id: pid, html: outcome.merged,
                                                            queuedAt: entry.queuedAt,
                                                            serverUpdatedAtMillis: ms)
            } catch {
                log.error("Auto-Merge lokal persistieren fehlgeschlagen \(pid, privacy: .public): \(error.localizedDescription, privacy: .public) — Basis nicht vorgerückt, Retry beim nächsten Tick")
                return
            }
            guard quittiert else {
                // Save während des Merge-PUT → Seitenzeile + neuer Outbox-Eintrag
                // bleiben unangetastet. Der neue Eintrag schreibt `entry.html` fort,
                // nicht das Merge-Ergebnis — darum wird `entry.html` sein Ancestor,
                // während die ISO-Basis bewusst ALT bleibt: der nächste Push läuft
                // so in ein 409 und merged nur noch die jüngsten Zeichen gegen den
                // (bereits gemergten) Server-Stand, statt ihn zu überschreiben.
                try? await store.setServerBaseHtml(entry.html, id: pid)
                log.notice("Auto-Merge: Save während PUT — Ancestor fortgeschrieben, Retry: \(pid, privacy: .public)")
                return
            }
            autoMergeRe409[pid] = nil   // erfolgreich konvergiert → Re-Zähler zurücksetzen
            try? await store.setServerBaseHtml(outcome.merged, id: pid)
            stateStore.mutate { $0.serverBaseISO[pid] = resp.updated_at }
            clearConflict(pageId: pid)
            // Offene, saubere Seite still mit dem Merge-Ergebnis aktualisieren
            // (lehnt der Editor ab, wird die Basis zurückgedreht).
            await reloadOpenPageOrRevertBase(pid, html: outcome.merged, ms: ms, previous: previous)
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
