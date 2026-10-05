//
//  SyncEngine+Pull.swift
//  schreibwerkstatt-focuseditor
//
//  Pull- und Delete-Reconcile-Pfad der SyncEngine. Pull: je Buch
//  `GET /content/books/:id/sync` mit Keyset-Cursor, bis `has_more=false`.
//  Server-Seiten landen im Store — ABER niemals über lokal ungepushte
//  Änderungen (die löst der Push/Merge auf). Delete-Reconcile: `/sync` meldet
//  keine Löschungen → der Soll-Bestand kommt aus dem Buch-Tree. Kern, State und
//  Konflikt-UI liegen in SyncEngine.swift; der Push-Pfad in SyncEngine+Push.swift.
//

import Foundation
import OSLog

extension SyncEngine {

    // MARK: - Pull

    func pullDeltas() async throws {
        // Bücherliste auffrischen: beim ersten Mal (leer) zwingend, danach
        // gedrosselt — sonst würden in der Web-App neu angelegte Bücher nie
        // gepullt.
        let booksDue: Bool = {
            guard let last = lastBooksRefreshAt else { return true }
            return Date().timeIntervalSince(last) >= booksRefreshInterval
        }()
        if stateStore.state.bookIds.isEmpty || booksDue {
            let books = try await reachableSend {
                try await api.send("/content/books", method: .GET, decode: [BookDTO].self)
            }
            lastBooksRefreshAt = Date()
            let ids = books.map(\.id)
            // `GET /content/books` ist AUTORITATIV: die vollständige Liste der für
            // diesen User zugänglichen Bücher. Buch-IDs, die nicht (mehr) darin
            // stehen — etwa von einem anderen Server (Namespace-Altlast) oder nach
            // Zugriffsentzug —, werden NICHT gepollt; sonst läuft jeder Tick in ein
            // `NO_BOOK_ACCESS` (Server-Log-Flut). Darum die bekannte Liste auf den
            // Server-Bestand kürzen, statt sie nur zu vereinigen. Schutz gegen eine
            // transient leere Antwort: nur kürzen, wenn die Liste nicht leer ist
            // (eine echte leere Antwort lässt der nächste Tick erneut prüfen).
            if ids.isEmpty {
                log.notice("Bücherliste leer — Buch-IDs unverändert gelassen (kein Prune)")
            } else {
                let valid = Set(ids)
                let dropped = stateStore.state.bookIds.filter { !valid.contains($0) }
                stateStore.mutate { state in
                    // Cursor verschwundener Bücher mit aufräumen (kein toter Ballast).
                    for id in dropped { state.cursors[id] = nil }
                    state.bookIds = ids   // Server-Reihenfolge, autoritativ (gekürzt)
                }
                if !dropped.isEmpty {
                    log.info("Buch-IDs gekürzt: \(dropped.map(String.init).joined(separator: ","), privacy: .public) nicht (mehr) zugänglich")
                }
            }
        }

        try ensureNotSuperseded()
        for bookId in stateStore.state.bookIds {
            do {
                try await pullBook(bookId)
            } catch AuthError.unauthorized {
                // Session beendet → ganzen Sync abbrechen.
                throw AuthError.unauthorized
            } catch SyncSuperseded.serverSwitch {
                throw SyncSuperseded.serverSwitch
            } catch {
                // Netzfehler/Timeout bei einem Buch blockiert die restlichen nicht.
                // Server-Fehler zählen für die Status-Anzeige (s. `runIssues`).
                if case AuthError.server = error { runIssues += 1 }
                log.error("Pull Buch \(bookId) fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
                continue
            }
        }
    }

    private func pullBook(_ bookId: Int) async throws {
        var cursor = stateStore.state.cursors[bookId] ?? SyncCursorDTO(since: nil, since_id: 0)

        // Harte Obergrenze gegen ein endloses Paging bei fehlerhaftem Server-
        // Cursor (oszillierend/nicht-monoton). Bei 200 Seiten/Page deckt das
        // sehr große Bücher ab; wird sie erreicht, beim nächsten Tick weiter.
        let maxPages = 500
        var pageCount = 0

        while true {
            pageCount += 1
            if pageCount > maxPages {
                log.notice("Pull Buch \(bookId, privacy: .public): Paging-Limit (\(maxPages, privacy: .public)) erreicht — beim nächsten Tick weiter")
                break
            }
            let resp = try await reachableSend {
                try await api.send(syncPath(bookId: bookId, cursor: cursor),
                                   method: .GET,
                                   decode: BookSyncResponse.self)
            }
            // Serverwechsel während des GET → weder Seiten noch Cursor in den
            // Zustand des NEUEN Servers schreiben.
            try ensureNotSuperseded()

            let pending = Set(try await store.pendingOutbox().map(\.pageId))

            for p in resp.pages {
                let pid = String(p.page_id)
                let isDirtyOpen = (editor?.openPageId == pid) && (editor?.isDirty(pid) ?? false)
                if pending.contains(pid) || isDirtyOpen {
                    // Lokal ungepushte Änderung (Outbox ODER dirty offene Seite) +
                    // neuerer Server-Stand → Divergenz. Nicht überschreiben und Basis
                    // NICHT vorrücken: der nächste Push läuft bewusst in ein 409 und
                    // löst per Block-Merge auf (Datenverlust-Schutz).
                    log.notice("Pull übersprungen (lokale Änderung offen): \(pid, privacy: .public)")
                    continue
                }
                // Ohne Server-`updated_at` gibt es keine gültige Konflikt-Basis
                // (PUT braucht den exakten ISO-String). Seite überspringen, statt
                // sie ohne Basis in den Store zu mergen.
                guard let serverUpdatedAt = p.updated_at else {
                    log.notice("Pull übersprungen (Seite ohne updated_at): \(pid, privacy: .public)")
                    continue
                }
                try ensureNotSuperseded()
                // Echo des eigenen, eben gepushten Edits: `/sync` liefert bewusst
                // auch eigene Edits zurück, und nach dem Push steht unsere Basis
                // bereits auf genau diesem Server-Stempel. Gleicher Stempel = kein
                // neuer Inhalt → NICHT erneut in den Store mergen und vor allem die
                // offene Seite NICHT neu laden. Sonst lädt jeder Auto-Save die Seite
                // einen Tick später unnötig neu und die Live-Statistik (Wortzahl/
                // „heute") flackert. Fremd-Edits (anderes Gerät/Session) tragen einen
                // ANDEREN updated_at und greifen darum weiterhin. Cursor rückt unten
                // trotzdem regulär vor.
                if stateStore.state.serverBaseISO[pid] == serverUpdatedAt { continue }

                // Unparsbarer Stempel → überspringen statt Epoch 0 (ans Listenende
                // rutschende Seite) in den Store zu schreiben. Der Cursor rückt
                // trotzdem darüber hinweg — die Seite kommt erst mit ihrer nächsten
                // Änderung wieder (ein Server-Datenfehler, kein Netzproblem).
                guard let ms = ISOTime.millis(serverUpdatedAt) else {
                    log.notice("Pull übersprungen (updated_at unparsbar): \(pid, privacy: .public)")
                    continue
                }

                let serverHtml = p.html ?? ""
                // Datenverlust-sicher übernehmen: der Outbox-Check läuft ATOMAR mit
                // dem Write (schliesst das TOCTOU-Fenster, falls seit dem `pending`-
                // Lesen oben ein Save einging). Dirty-offene Seite (Tippen ohne Save,
                // noch ohne Outbox-Eintrag) zusätzlich direkt vor dem Write erneut
                // prüfen — das GET oben hat suspendiert, der Zustand kann veraltet sein.
                if (editor?.openPageId == pid) && (editor?.isDirty(pid) ?? false) {
                    log.notice("Pull übersprungen (dirty offen, Re-Check): \(pid, privacy: .public)")
                    continue
                }
                let previous = await baseSnapshot(pid)
                let applied = try await store.applyServerPageIfClean(id: pid,
                                                                     html: serverHtml,
                                                                     pageName: p.page_name,
                                                                     bookId: bookId,
                                                                     chapterId: p.chapter_id,
                                                                     serverUpdatedAtMillis: ms)
                guard applied else {
                    // Zwischenzeitlich doch eine Outbox-Änderung → nicht überschreiben,
                    // Basis NICHT vorrücken; der Push läuft bewusst in ein 409 → Merge.
                    log.notice("Pull übersprungen (Outbox zwischenzeitlich, atomar erkannt): \(pid, privacy: .public)")
                    continue
                }
                // Erst nach erfolgreicher Übernahme: ISO als Push-Basis + HTML als
                // Merge-Ancestor mitführen (sonst stünde die Basis auf einem Stand,
                // den der Store gar nicht übernommen hat).
                // Ancestor VOR der ISO-Basis setzen, damit die Basis nie auf einen
                // Stand zeigt, zu dem der Ancestor noch fehlt (ein 409 dazwischen
                // fiele sonst auf einen älteren Vorfahren zurück).
                try? await store.setServerBaseHtml(serverHtml, id: pid)
                stateStore.mutate { $0.serverBaseISO[pid] = serverUpdatedAt }
                // Saubere, offene Seite still in der WebView neu laden (clean reload);
                // lehnt der Editor ab (inzwischen getippt), Basis zurückdrehen.
                await reloadOpenPageOrRevertBase(pid, html: serverHtml, ms: ms, previous: previous)
            }

            // Cursor vorrücken + persistieren (robust gegen Abbruch mittendrin).
            try ensureNotSuperseded()
            let previous = cursor
            stateStore.mutate { $0.cursors[bookId] = resp.cursor }

            // Schutz gegen Endlosschleife, falls der Cursor nicht vorrückt.
            if !resp.has_more || resp.pages.isEmpty { break }
            // Server meldet `has_more`, liefert aber denselben Cursor zurück
            // (Server-Bug) → nicht ewig pagen, beim nächsten Tick neu ansetzen.
            if resp.cursor == previous {
                log.notice("Pull Buch \(bookId, privacy: .public): Cursor rückt nicht vor — Schleife abgebrochen")
                break
            }
            cursor = resp.cursor
        }
    }

    /// Baut `/content/books/:id/sync?…` mit korrekt kodiertem Cursor.
    private func syncPath(bookId: Int, cursor: SyncCursorDTO) -> String {
        var path = "/content/books/\(bookId)/sync?limit=200"
        if let since = cursor.since,
           let encoded = since.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            path += "&since=\(encoded)&since_id=\(cursor.since_id)"
        }
        return path
    }

    // MARK: - Delete-Reconcile

    /// Entfernt lokal Seiten, die der Server nicht mehr kennt. `/sync` meldet
    /// keine Löschungen (CLAUDE.md) — der Soll-Bestand kommt aus dem Buch-Tree.
    /// Gedrosselt (≤ 1×/`reconcileInterval`), da je Buch ein Tree-Fetch anfällt.
    func reconcileDeletesIfDue() async {
        let now = Date()
        if let last = lastReconcileAt, now.timeIntervalSince(last) < reconcileInterval { return }
        lastReconcileAt = now

        // Verwaiste Seiten (bookId == nil) einmal ermitteln — der Buch-Abgleich
        // unten trägt ihr Buch nach, sobald ein Tree sie als seine Seite ausweist.
        let orphans = Set((try? await store.pageIdsWithoutBook()) ?? [])

        for bookId in stateStore.state.bookIds {
            do {
                try await reconcileBookDeletes(bookId, orphans: orphans)
            } catch {
                // Ein Tree-Fehler (offline/Serverproblem) darf die anderen Bücher
                // nicht blockieren und nichts löschen — beim nächsten Mal erneut.
                log.notice("Reconcile Buch \(bookId, privacy: .public) übersprungen: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func reconcileBookDeletes(_ bookId: Int, orphans: Set<String>) async throws {
        // Zeitpunkt VOR dem Tree-Abruf: eine Seite, die lokal danach angelegt oder
        // gezogen wurde (z. B. „Neue Seite" während des Abrufs), kann der Tree noch
        // gar nicht kennen — sie wäre sonst sofort wieder gelöscht.
        let treeRequestedAt = Date().timeIntervalSince1970 * 1000
        // Buch-Tree EINMAL holen → Soll-IDs (Delete-Reconcile) + Kapitel-Zuordnung
        // (Waisen-Backfill) aus derselben Antwort.
        let treePages = ContentAPI.flattenTreePages(try await content.tree(bookId: bookId))
        guard !isSuperseded else { return }
        // Soll: alle Seiten, die der Server-Tree für das Buch kennt.
        let soll = Set(treePages.map { String($0.id) })

        // Datenverlust-Schutz: Ein leerer Tree ist verdächtig (transienter
        // Server-200 mit leerem Array, halb-deployter Endpoint, frische Buch-ID)
        // und würde JEDE lokale, saubere Seite löschen — die der cursor-
        // inkrementelle Pull NICHT von selbst zurückbringt. In dem Fall lieber
        // nichts tun und beim nächsten Lauf erneut prüfen.
        guard !soll.isEmpty else {
            log.notice("Reconcile Buch \(bookId, privacy: .public) übersprungen: leerer Server-Tree")
            return
        }

        // Waisen-Backfill: Seiten ohne Buch, die dieser Tree als seine ausweist,
        // ihr Buch (+ Kapitel) nachtragen. Reine Metadaten — kein Datenverlust,
        // greift auch bei dirty/ungepushten Seiten, die der Pull überspringt.
        // (Ursache: `/content/pages/:id` im Bridge-Nachladen liefert kein book_id.)
        if !orphans.isEmpty {
            let chapterOf = Dictionary(treePages.map { (String($0.id), $0.chapterId) },
                                       uniquingKeysWith: { first, _ in first })
            for pid in orphans where soll.contains(pid) {
                try await store.assignBook(pageId: pid, bookId: bookId, chapterId: chapterOf[pid] ?? nil)
                log.info("Reconcile: verwaiste Seite \(pid, privacy: .public) Buch \(bookId, privacy: .public) zugeordnet")
            }
        }

        // Ist: lokal gespiegelte Seiten dieses Buchs (nach dem Backfill, damit
        // eben zugeordnete Waisen mit erfasst sind).
        let ist = try await store.list(bookId: bookId)
        guard !ist.isEmpty else { return }

        for summary in ist where !soll.contains(summary.id) {
            let pid = summary.id
            if summary.updatedAt > treeRequestedAt {
                log.notice("Reconcile: \(pid, privacy: .public) jünger als der Tree — behalten")
                continue
            }
            // Datenverlust-Schutz: nie löschen, wenn die Seite gerade dirty im
            // Editor liegt …
            if editor?.openPageId == pid, editor?.isDirty(pid) == true {
                log.notice("Reconcile: \(pid, privacy: .public) serverseitig weg, aber dirty im Editor — behalten")
                continue
            }
            // … oder eine lokale Änderung ungepusht ist. Die Outbox-Prüfung läuft
            // in DERSELBEN Transaktion wie das Löschen — eine einmal vorab gelesene
            // Liste veraltete über die awaits dieser Schleife hinweg, und ein Save,
            // der dazwischen einging, wäre samt Outbox-Eintrag mit gelöscht worden.
            // `deletePage…` nimmt den Merge-Ancestor als Spalte der Seite mit weg.
            guard try await store.deletePageIfClean(id: pid) else {
                log.notice("Reconcile: \(pid, privacy: .public) serverseitig weg, aber Outbox offen — behalten")
                continue
            }
            stateStore.mutate { $0.serverBaseISO[pid] = nil }
            log.info("Reconcile: lokale Seite \(pid, privacy: .public) entfernt (serverseitig gelöscht)")
        }
    }

    // MARK: - Offene Seite neu laden

    /// Basis einer Seite vor der Übernahme eines Server-Stands — zum
    /// Zurückdrehen, falls der Editor den Reload ablehnt.
    struct BaseSnapshot {
        let iso: String?
        let ancestor: String?
    }

    func baseSnapshot(_ pid: String) async -> BaseSnapshot {
        BaseSnapshot(iso: stateStore.state.serverBaseISO[pid],
                     ancestor: (try? await store.serverBaseHtml(id: pid)) ?? nil)
    }

    /// Nach Übernahme eines Server-Stands (Basis + Ancestor schon vorgerückt):
    /// die offene Seite still neu laden. Swifts Sicht „offen + sauber" ist über
    /// die IPC immer etwas alt — der Editor prüft darum selbst und lehnt ab, wenn
    /// inzwischen getippt wurde. Dann (oder wenn inzwischen ein Save in der
    /// Outbox liegt, der noch auf dem ALTEN Stand beruht) die Basis zurückdrehen:
    /// der nächste Push läuft so in ein 409 und merged die Server-Änderung ein,
    /// statt sie ohne Merge zu überschreiben. Zurückdrehen ist immer sicher —
    /// schlimmstenfalls kostet es einen Merge-Roundtrip oder einen erneuten Pull.
    func reloadOpenPageOrRevertBase(_ pid: String, html: String, ms: Double,
                                    previous: BaseSnapshot) async {
        var declined = false
        if let editor, editor.openPageId == pid {
            declined = !(await editor.reloadPage(pageId: pid, html: html,
                                                 baseUpdatedAt: ms, force: false))
        }
        let pendingNow = ((try? await store.pendingOutbox()) ?? []).contains { $0.pageId == pid }
        guard declined || pendingNow else { return }
        try? await store.setServerBaseHtml(previous.ancestor, id: pid)
        stateStore.mutate { $0.serverBaseISO[pid] = previous.iso }
        log.notice("Reload der offenen Seite abgelehnt/überholt — Basis zurückgedreht: \(pid, privacy: .public)")
    }
}
