//
//  EditorBridge+Ops.swift
//  schreibwerkstatt-focuseditor
//
//  Der Dispatch JS → Swift: `route(op:params:)` und die Op-Implementierungen.
//  Aus `EditorBridge.swift` ausgelagert (eine Datei = eine Verantwortung, hält
//  beide unter dem Zeilen-Limit; Vorbild `SyncEngine[+Push/+Pull]`).
//
//  Nachrichtenvertrag (JS → Swift), je `{ op, params }`:
//    • load { pageId }                         → { id, html, updatedAt, baseUpdatedAt? }
//    • save { pageId, html, baseUpdatedAt? }   → { id, updatedAt }
//    • list { bookId? }                        → [ { id, title?, pageName?, bookId?, chapterId?, updatedAt } ]
//    • activeBook {}                           → { bookId }  (Toolbar-Buch, Boot-Pull)
//    • lastOpenPage { bookId? }                → { pageId }  (zuletzt geöffnet, gerätelokal)
//    • editorState { pageId, dirty, bookId? }  → null   (offene Seite + Dirty-Flag)
//    • log  { level?, message }                → null   (JS-Diagnose im Swift-Log)
//    • focusGranularity {}                     → { granularity }        (Boot-Pull)
//    • editorTypography {}                     → { fontSize, … }        (Boot-Pull)
//    • editorBehavior {}                       → { autosaveMs }         (Boot-Pull)
//    • reportStats { words, chars, pageId? }   → null
//    • resetUndo {}                            → null   (Undo-Stack der WebView leeren)
//    • historyEdit { kind, chars }             → null   (Widerrufen/Wiederherstellen gemeldet)
//
//  Proxy-Ops (Implementierung in `EditorBridge+Proxies.swift`, NIE direkter
//  `fetch` aus der WebView — HARTE REGEL):
//    • spellcheckConfig {} · languagetoolCheck {…} · dictionaryAdd {…}
//    • synonymConfig {} · synonymsThesaurus {…} · synonymsAi {…}
//
//  Härtung: `params` kommt aus der WebView und ist NICHT vertrauenswürdig. Jeder
//  Wert läuft über die Validierer in `EditorBridge+Params.swift` (Pflichtfelder,
//  Längen-Deckel, Zahlenbereiche, Seiten-ID-Form) — nie direkt in Store, URL,
//  UserDefaults oder Log.
//

import AppKit
import Foundation
import os

extension EditorBridge {

    /// Zentraler Dispatch der Bridge-Ops. `internal` (nicht `private`), damit das
    /// Logic-Test-Bundle die Ops ohne WebView/`WKScriptMessage` direkt treiben kann
    /// (`EditorBridgeTests`); der reguläre Einstieg bleibt der Message-Handler.
    func route(op: String, params: [String: Any]) async throws -> Any? {
        switch op {
        case "load":            return try await opLoad(params)
        case "save":            return try await opSave(params)
        case "list":            return try await opList(params)
        case "log":             opLog(params); return nil
        case "editorState":     opEditorState(params); return nil
        case "lastOpenPage":    return opLastOpenPage(params)
        case "activeBook":      return ["bookId": Self.activeBookId as Any]
        case "reportStats":     opReportStats(params); return nil
        case "resetUndo":       opResetUndo(); return nil
        case "historyEdit":     opHistoryEdit(params); return nil

        // Boot-Pull: lokale Editor-Einstellungen (kein Netz, kein Store).
        case "focusGranularity":  return ["granularity": focusGranularity]
        case "editorTypography":  return typography
        case "editorBehavior":    return ["autosaveMs": EditorBehaviorPrefs.autosaveMs]

        // Server-Proxys (EditorBridge+Proxies.swift)
        case "spellcheckConfig":
            return await spellcheckConfig()

        case "languagetoolCheck":
            let text = try requireString(params, "text", maxLength: Self.maxCheckTextLength)
            let language = optToken(params, "language", maxLength: 16) ?? "auto"
            return try await languagetoolCheck(text: text, language: language,
                                               pageId: optPageId(params, "pageId"),
                                               bookId: optBookId(params, "bookId"))

        case "dictionaryAdd":
            let word = try requireString(params, "word", maxLength: Self.maxWordLength)
            let lang = optToken(params, "lang", maxLength: 16) ?? "*"
            return try await dictionaryAdd(word: word, lang: lang,
                                           bookId: optBookId(params, "bookId") ?? 0)

        case "synonymConfig":
            return synonymConfig()

        case "synonymsThesaurus":
            let word = try requireString(params, "word", maxLength: Self.maxWordLength)
            return try await synonymsThesaurus(word: word, bookId: optBookId(params, "bookId"))

        case "synonymsAi":
            let wort = try requireString(params, "wort", maxLength: Self.maxWordLength)
            let satz = optString(params, "satz", maxLength: Self.maxSentenceLength) ?? wort
            return try await synonymsAi(wort: wort, satz: satz,
                                        bookId: optBookId(params, "bookId"),
                                        pageId: optPageId(params, "pageId"))

        default:
            throw BridgeError.unknownOp(op)
        }
    }

    // MARK: - Inhalte (local-first)

    /// Seite laden. Local-first: gespiegelte Seite mit Inhalt direkt liefern;
    /// fehlt der Spiegel (oder ist er ohne Body), online nachladen. Offline/
    /// unbekannt → `nil` (kein Fehler — der Editor zeigt dann eine leere Seite).
    private func opLoad(_ params: [String: Any]) async throws -> Any? {
        let pageId = try requirePageId(params)
        if let page = try await store.page(id: pageId), !page.html.isEmpty {
            return Self.encode(page)
        }
        if let page = await fetchAndMirror(pageId: pageId) {
            return Self.encode(page)
        }
        return nil
    }

    /// Seite speichern — local-first (LocalStore + Outbox), NIE direkt zum Server.
    private func opSave(_ params: [String: Any]) async throws -> Any? {
        let pageId = try requirePageId(params)
        // Leeres HTML ist erlaubt (geleerte Seite) — nur der Deckel gegen absurde
        // Bodies greift, sonst schrieben wir Megabyte-Müll in den Spiegel.
        let html = try requireString(params, "html", maxLength: Self.maxHtmlLength,
                                     allowEmpty: true)
        let base = optTimestamp(params, "baseUpdatedAt")
        guard !deletedPageIds.contains(pageId) else {
            log.info("Save für gelöschte Seite verworfen: \(pageId, privacy: .public)")
            return nil
        }
        do {
            let saved = try await store.save(id: pageId, html: html, baseUpdatedAt: base)
            // Erfolgreicher Save → einen zuvor gezeigten Save-Fehler-Banner lösen.
            onSaveResult?(nil)
            return ["id": saved.id, "updatedAt": saved.updatedAt]
        } catch {
            // Lokaler Save fehlgeschlagen = potenzieller Datenverlust → den
            // Nutzer warnen (sichtbarer Banner), nicht nur loggen. Fehler
            // trotzdem an die WebView durchreichen (Editor-Promise lehnt ab).
            onSaveResult?(error.localizedDescription)
            throw error
        }
    }

    /// Seitenliste aus dem Spiegel. Optionaler Buch-Filter: nil = alle Seiten
    /// (der Picker reicht `book_id` durch).
    private func opList(_ params: [String: Any]) async throws -> Any? {
        let summaries = try await store.list(bookId: optBookId(params, "bookId"))
        return summaries.map { ["id": $0.id,
                                "title": $0.title as Any,
                                "pageName": $0.pageName as Any,
                                "bookId": $0.bookId as Any,
                                "chapterId": $0.chapterId as Any,
                                "updatedAt": $0.updatedAt] }
    }

    // MARK: - Zustand & Diagnose

    /// JS-Diagnose ins Swift-Log. Härtung: Level auf `info`/`error` normalisiert,
    /// Nachricht gekürzt und einzeilig gemacht — der Text kommt aus der WebView
    /// (auch aus dem umgeleiteten `console.*`) und darf das Log weder fluten noch
    /// mit eingebetteten Zeilenumbrüchen fremde Einträge vortäuschen.
    private func opLog(_ params: [String: Any]) {
        let level = (params["level"] as? String) == "error" ? OSLogType.error : .info
        let msg = Self.sanitizedLogMessage(params["message"])
        log.log(level: level, "WebView: \(msg, privacy: .public)")
    }

    /// Editor meldet offene Seite + Dirty-Flag (für Open-Page-Reload/-Schutz).
    /// Merkt nebenbei die zuletzt geöffnete Seite gerätelokal — pro Buch (Boot-
    /// Restore ohne Buch-Verwechslung) und global (Legacy-Fallback) — sowie die
    /// MRU-Historie für die Gruppe „Zuletzt geöffnet" im Seiten-Picker.
    ///
    /// Härtung: nur formal gültige Seiten-IDs werden übernommen; eine kaputte ID
    /// (leer, überlang, Steuerzeichen, Pfadtrenner) gilt als „keine Seite offen"
    /// und landet nie in den UserDefaults-Merkern — sonst restaurierte der Boot
    /// dauerhaft eine Unsinns-ID.
    private func opEditorState(_ params: [String: Any]) {
        let pageId = optPageId(params, "pageId")
        let dirty = (params["dirty"] as? Bool) ?? false
        applyEditorState(pageId: pageId, dirty: dirty)
        guard let pageId else { return }
        UserDefaults.standard.set(pageId, forKey: Self.lastOpenPageKey)
        if let bookId = optBookId(params, "bookId") {
            Self.setLastOpenPageId(pageId, forBook: bookId)
            // Zusätzlich in die MRU-Historie (Gruppe „Zuletzt geöffnet" im
            // Picker); schreibt nur beim echten Seitenwechsel.
            Self.pushRecentPageId(pageId, forBook: bookId)
        }
    }

    /// Boot-Pull: zuletzt geöffnete Seite (gerätelokal). Mit `bookId` buch-skopiert
    /// (so öffnet der Restore nie eine Seite eines anderen Buchs); ohne `bookId`
    /// der globale Legacy-Wert. Der Editor-Glue bevorzugt sie in `loadPage`, fällt
    /// sonst auf die erste Seite zurück. `nil`, wenn (für dieses Buch) noch nie
    /// eine Seite geöffnet wurde.
    private func opLastOpenPage(_ params: [String: Any]) -> Any? {
        if let bookId = optBookId(params, "bookId") {
            return ["pageId": Self.lastOpenPageId(forBook: bookId) as Any]
        }
        return ["pageId": UserDefaults.standard.string(forKey: Self.lastOpenPageKey) as Any]
    }

    /// WebView meldet Wort-/Zeichenzahl der offenen Seite (Live-Stats + Ziel +
    /// Tages-Delta). Die pageId trägt den Seitenbezug für „heute geschrieben".
    /// Zahlen werden geklemmt (kein NaN/Negativ/Unsinn in die Statistik).
    private func opReportStats(_ params: [String: Any]) {
        let words = Self.clampedCount(params["words"])
        let chars = Self.clampedCount(params["chars"])
        // Fehlt das Flag (älterer Glue), wie bisher als Eingabe werten.
        let typed = (params["typed"] as? Bool) ?? true
        onStats?(optPageId(params, "pageId"), words, chars, typed)
        // Nur echte Eingabe ist ein Lebenszeichen → Idle-Uhr der Schreibzeit
        // zurück. Ein stiller Server-Refresh (Änderung von einem anderen Gerät)
        // hielte die Schreibzeit sonst endlos am Laufen.
        if typed { onActivity?() }
    }

    // MARK: - Widerrufen / Wiederherstellen (WebKit-Undo)

    /// Undo-Stack der WebView leeren. Ruft der Boot-Glue nach jedem `setPage`
    /// (Seitenwechsel, stiller Server-Refresh, Seite schliessen) auf.
    ///
    /// Warum: Der Editor rendert eine Seite per `innerHTML`. WebKits Undo-Stack
    /// hängt an der WebView, nicht am Inhalt — die Einträge der vorigen Seite
    /// bleiben also stehen. Sie greifen dann auf Knoten, die es nicht mehr gibt:
    /// gemessen verpufft so ein Undo wirkungslos, verbraucht aber den Eintrag und
    /// macht ein Redo scharf. Nach dem Leeren gilt „Widerrufen" immer nur für die
    /// offene Seite (und das Menü zeigt es korrekt grau, solange nichts getippt ist).
    private func opResetUndo() {
        webView?.undoManager?.removeAllActions()
    }

    /// Ein Widerrufen/Wiederherstellen hat gerade Text entfernt bzw. wieder
    /// eingesetzt (aus dem `input`-Event der WebView: `historyUndo`/`historyRedo`).
    ///
    /// Warum überhaupt gemeldet: WebKit fasst eine ganze Tippstrecke in EINEN
    /// Undo-Schritt zusammen (gemessen am echten Bundle: alles seit dem letzten
    /// Mausklick — Pfeiltasten, Enter, Auto-Save und Fokuswechsel trennen nicht).
    /// Ein versehentliches ⌘Z entfernt damit unter Umständen den ganzen
    /// Schreib-Abschnitt, und der Auto-Save persistiert das still. Der Hinweis
    /// macht es sichtbar und nennt den Rückweg (⌘⇧Z).
    private func opHistoryEdit(_ params: [String: Any]) {
        guard let kind = optToken(params, "kind", maxLength: 8),
              kind == "undo" || kind == "redo" else { return }
        onHistoryEdit?(kind == "undo", Self.clampedCount(params["chars"]))
    }

    // MARK: - Server-Nachladen (offline-first-Lücke)

    /// Lädt eine Seite direkt vom Server (`GET /content/pages/:id`, liefert
    /// immer den vollen HTML-Body) und spiegelt sie in den LocalStore. Fallback
    /// für `load`, wenn der Sync-Pull die Seite noch nicht (oder ohne Body)
    /// erfasst hat — der Picker listet alle Server-Seiten (Tree), der Inhalt
    /// kommt aber sonst nur aus dem Spiegel. Ohne API/offline → der lokale
    /// (ggf. leere) Stand; der nächste Pull holt die Seite regulär nach.
    ///
    /// Setzt die Sync-Basis (`serverBaseISO` + `serverBaseHtml`), damit der
    /// nächste Push gegen eine gültige Basis läuft. Ohne Basis würde der Push
    /// die Seite ewig überspringen ("keine Server-Basis, noch nicht gepullt"),
    /// während der Pull sie ebenfalls überspringt (Outbox-Eintrag vorhanden) —
    /// ein Deadlock. Verwirft NIE eine lokal anhängige Änderung (Datenverlust-
    /// Schutz): liegt für die Seite ein Outbox-Eintrag vor, bleibt der lokale
    /// Stand unangetastet.
    private func fetchAndMirror(pageId: String) async -> StoredPage? {
        guard let api else { return nil }
        if let pending = try? await store.pendingOutbox(),
           pending.contains(where: { $0.pageId == pageId }) {
            return try? await store.page(id: pageId)
        }
        // pageId kommt aus der (nicht vertrauenswürdigen) WebView → für den
        // URL-Pfad kodieren. `requirePageId` hat Pfadtrenner/Steuerzeichen schon
        // abgewiesen; das Encoding ist die zweite Schicht (Query-/Fragment-Zeichen).
        guard let encodedId = pageId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return try? await store.page(id: pageId)
        }
        guard let resp = try? await api.send("/content/pages/\(encodedId)",
                                             method: .GET,
                                             decode: PushResponse.self),
              let html = resp.html else {
            return try? await store.page(id: pageId)
        }
        let ms = ISOTime.millis(resp.updated_at) ?? 0
        // book_id/chapter_id liefert `/content/pages/:id` (noch) nicht zwingend
        // (anders als der Sync-Pull) → ggf. nil. Dann bleibt das Buch vorerst
        // ungesetzt; der Delete-Reconcile trägt es über den Buch-Tree nach
        // (LocalStore.assignBook), damit die Seite nicht als Waise unsichtbar wird.
        //
        // Datenverlust-Schutz: der `pending`-Check oben liegt VOR dem (suspendierenden)
        // GET — bis hierher kann ein lokaler Save einen Outbox-Eintrag angelegt haben.
        // Darum den Server-Stand ATOMAR-bedingt schreiben (`…IfClean` prüft die Outbox
        // in derselben Transaktion wie der Write, wie der Sync-Pull): liegt nun eine
        // lokale Änderung vor, bleibt sie unangetastet und wir liefern den lokalen
        // Stand zurück (der Push/409-Merge löst die Divergenz auf).
        let applied = try? await store.applyServerPageIfClean(id: pageId, html: html,
                                                              pageName: resp.name,
                                                              bookId: resp.book_id, chapterId: resp.chapter_id,
                                                              serverUpdatedAtMillis: ms)
        // Sync-Basis setzen (Merge-Ancestor + ISO-Basis), damit der nächste Push
        // gegen eine gültige Basis läuft — aber NUR, wenn der Server-Stand
        // wirklich übernommen wurde. Bei `applied == false` (inzwischen eine
        // lokale Änderung in der Outbox) wäre „Basis = Server jetzt" ein stilles
        // Last-Write-Wins: der Push ginge ohne 409 durch und überschriebe den
        // Server. Den Fall löst `SyncEngine.repairStalledSyncBases` sicher auf
        // (Basis nur bei unverändertem Server, sonst Merge).
        if applied == true {
            try? await store.setServerBaseHtml(html, id: pageId)
            await onSetSyncBase?(pageId, resp.updated_at, html)
        }
        return try? await store.page(id: pageId)
    }
}
