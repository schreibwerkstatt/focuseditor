//
//  EditorBridge+Events.swift
//  schreibwerkstatt-focuseditor
//
//  Der Kanal Swift → JS: der Event-Bus der Facade
//  (`window.__focusBridge._receive(event, payload)`) plus die zwei awaitbaren
//  Direktaufrufe (Draft-Flush für ⌘S, 3-Wege-Block-Merge beim 409-Push).
//
//  Events:
//    • serverUpdate { pageId, html, baseUpdatedAt }  (offene Seite serverseitig aktualisiert)
//    • openPage     { pageId, html?, baseUpdatedAt? } (nativer Picker öffnet Seite)
//    • closePage    {}                               (offene Seite schliessen → ruhige Leerfläche)
//    • focusGranularity { granularity }              (Fokus-Stufe live umgeschaltet)
//    • editorTypography { … }                        (Typografie live umgeschaltet)
//    • format       { command }                      (⌘B/⌘I/⌘U aus dem Format-Menü)
//    • history      { action }                       (⌘Z/⌘⇧Z aus dem Bearbeiten-Menü)
//    • normalizeQuotes { language, region }           (Anführungszeichen auf Buch-Stil)
//    • synonyms     { x?, y? }                       (Synonym-Hilfe öffnen)
//
//  Härtung — alles läuft über `evaluateJS`/`emit`:
//   1. TIMEOUT für jeden Aufruf. `callAsyncJavaScript` wartet sonst unbegrenzt;
//      ein hängendes JS (stockender dynamischer Import, blockierter Main-Thread)
//      hätte den awaitenden Swift-Pfad — ⌘S-Flush, Lektorats-Vorlauf, 409-Merge —
//      dauerhaft eingefroren.
//   2. Optional-Chaining im Skript: ist das Dokument noch nicht gebootet (Facade
//      fehlt), ist der Aufruf ein stilles No-op statt eines JS-TypeErrors.
//   3. KEINE `nil`-Argumente an `callAsyncJavaScript` — erlaubt sind nur
//      JSON-Werte; ein durchgereichtes `Optional.none` liess den Aufruf mit einer
//      ObjC-Ausnahme scheitern. `emit` filtert `nil`-Felder heraus.
//   4. Rein visuelle Events dürfen scheitern (nur Log) — Datenverlust ist keiner
//      möglich, der Autosave/Pull holt den Stand ohnehin nach.
//

import Foundation
import os
import WebKit

extension EditorBridge {

    /// Standard-Deckel für einen Swift→JS-Aufruf. Grosszügig gegenüber einem
    /// beschäftigten Renderer, aber endlich. `nonisolated`, weil er als
    /// Default-Argument (also aus nonisolated Kontext) gelesen wird — eine
    /// Konstante braucht keine Isolation.
    nonisolated static let jsCallTimeout: Duration = .seconds(5)
    /// Deckel für den Block-Merge: der macht ein dynamisches `import()` des
    /// gebündelten `block-merge.js` und darf länger brauchen.
    nonisolated static let mergeTimeout: Duration = .seconds(8)

    // MARK: - Transport

    /// Führt JS in der Seite aus und liefert das Ergebnis. Wirft
    /// `BridgeError.webViewUnavailable` ohne WebView bzw. `timeoutError` bei
    /// Zeitüberschreitung.
    ///
    /// Bewusst KEINE Task-Group: die wartet beim Verlassen auf ALLE Kinder, und
    /// `callAsyncJavaScript` reagiert nicht auf Abbruch — ein nie erfüllendes
    /// JS-Promise hielte den Aufrufer trotz Timeout fest (⌘Q-Frist, ⌘S-Vorlauf,
    /// 409-Merge). Stattdessen zwei freie Tasks, von denen der erste die
    /// Continuation genau einmal erfüllt; der JS-Aufruf darf danach ins Leere
    /// weiterlaufen.
    func evaluateJS(_ script: String, arguments: [String: Any] = [:],
                    timeout: Duration = EditorBridge.jsCallTimeout,
                    timeoutError: BridgeError = .jsTimedOut("JS")) async throws -> Any? {
        guard let webView else { throw BridgeError.webViewUnavailable }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
            let gate = ResumeOnce(continuation)
            let timer = Task {
                try? await Task.sleep(for: timeout)
                gate.resume(with: .failure(timeoutError))
            }
            Task {
                do {
                    let value = try await webView.callAsyncJavaScript(script, arguments: arguments,
                                                                      in: nil, contentWorld: .page)
                    gate.resume(with: .success(value))
                } catch {
                    gate.resume(with: .failure(error))
                }
                timer.cancel()
            }
        }
    }

    /// Wie `evaluateJS`, aber ohne Wurf: loggt den Fehler unter `label` und
    /// liefert `nil`. Für alle Aufrufe, die scheitern DÜRFEN.
    @discardableResult
    func callJS(_ label: String, _ script: String, arguments: [String: Any] = [:],
                timeout: Duration = EditorBridge.jsCallTimeout) async -> Any? {
        do {
            return try await evaluateJS(script, arguments: arguments, timeout: timeout,
                                        timeoutError: .jsTimedOut(label))
        } catch BridgeError.webViewUnavailable {
            return nil   // noch keine WebView verbunden → stilles No-op
        } catch {
            log.error("\(label, privacy: .public) fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Feuert ein Event auf dem JS-Event-Bus. `nil`-Felder des Payloads werden
    /// ausgelassen (JS sieht `undefined`, der Glue behandelt es wie „nicht
    /// mitgeliefert"). Liefert `true`, wenn der Aufruf die Seite erreicht hat.
    @discardableResult
    func emit(_ event: String, _ payload: [String: Any?] = [:],
              timeout: Duration = EditorBridge.jsCallTimeout) async -> Bool {
        let clean: [String: Any] = payload.compactMapValues { $0 }
        let result = await callJS("Event '\(event)'",
                                 "window.__focusBridge?._receive?.(event, payload); return true;",
                                 arguments: ["event": event, "payload": clean],
                                 timeout: timeout)
        return result != nil
    }

    // MARK: - Seiten-Events

    /// Lädt die offene Seite still in der WebView neu (`_serverUpdate`). Der
    /// Editor prüft dabei SELBST, ob die Seite noch offen und unberührt ist —
    /// Swifts `openPageId`/`isDirty` kommen über die IPC und sind immer etwas
    /// alt. Liefert `true` nur, wenn der Reload wirklich übernommen wurde; bei
    /// `false` (inzwischen getippt, andere Seite, keine WebView, Timeout) muss
    /// der Aufrufer die Sync-Basis zurückdrehen, sonst überschriebe der nächste
    /// Push den Server-Stand ohne Merge. `force` (Konflikt „Server übernehmen")
    /// ersetzt auch eine dirty Seite — aber nur, wenn sie noch offen ist.
    @discardableResult
    func reloadPage(pageId: String, html: String, baseUpdatedAt: Double, force: Bool) async -> Bool {
        guard webView != nil else { return false }
        let result = await callJS("serverUpdate", """
            const fb = window.__focusBridge;
            if (!fb || typeof fb._serverUpdate !== 'function') { return false; }
            return (await fb._serverUpdate(payload)) === true;
            """,
            arguments: ["payload": ["pageId": pageId, "html": html,
                                    "baseUpdatedAt": baseUpdatedAt, "force": force]])
        return (result as? Bool) ?? false
    }

    /// Öffnet eine (beliebige) Seite im Editor — vom nativen Picker getrieben.
    /// Lädt den lokalen Stand aus dem Store (offline-first) und schickt ihn als
    /// `openPage`-Event an den Editor-Host. Liefert `false`, wenn keine WebView
    /// verfügbar ist bzw. der Aufruf scheiterte (Aufrufer zeigt dann eine
    /// Hinweis-UI / nimmt die optimistische Anzeige zurück).
    @discardableResult
    func openPage(pageId: String) async -> Bool {
        guard webView != nil else { return false }
        let page = try? await store.page(id: pageId)
        return await emit("openPage", ["pageId": pageId,
                                       "html": page?.html,
                                       "baseUpdatedAt": page?.baseUpdatedAt])
    }

    /// Schliesst die aktuell offene Seite im Editor (`closePage`-Event) — beim
    /// Buchwechsel ODER bewusst über die Toolbar. Der Editor-Glue sichert zuerst
    /// den aktuellen Stand (local-first), leert dann die Schreibfläche und blendet
    /// eine ruhige Leerfläche ein. Setzt die offene Seite zurück (Toolbar leert
    /// sich). No-op ohne WebView; Fehler werden nur geloggt (kein Datenverlust —
    /// der Stand wurde JS-seitig vor dem Leeren gesichert).
    func closePage() async {
        guard webView != nil else { return }
        applyEditorState(pageId: nil, dirty: false)
        await emit("closePage")
    }

    // MARK: - Darstellungs-Events

    /// Schaltet die Fokus-Granularität live in der WebView um. No-op, solange noch
    /// keine WebView verbunden ist (der Boot-Pull liest dann ohnehin
    /// `focusGranularity`). Rein visuell → Fehler nur geloggt.
    func pushFocusGranularity() async {
        await emit("focusGranularity", ["granularity": focusGranularity])
    }

    /// Schaltet die Editor-Typografie live in der WebView um. No-op ohne WebView
    /// (der Boot-Pull liest dann ohnehin `typography`). Rein visuell → Fehler nur
    /// geloggt. `NSNull`-Werte bleiben erhalten (JS `null` = „kein Override").
    func pushTypography() async {
        await emit("editorTypography", typography.mapValues { $0 as Any? })
    }

    /// Erlaubte Inline-Formatierungen (`document.execCommand`-Namen). Whitelist,
    /// damit über diesen Weg nie ein beliebiger execCommand in die Seite gerät —
    /// der Glue reicht den Wert unbesehen durch.
    static let allowedFormatCommands: Set<String> = ["bold", "italic", "underline"]

    /// Wendet eine Inline-Formatierung auf die aktuelle Auswahl im Editor an
    /// (`format`-Event). Native Entsprechung zu den ⌘B/⌘I/⌘U des contenteditable-
    /// Editors, jetzt auch über das Format-Menü erreichbar. No-op ohne WebView
    /// oder bei unbekanntem Befehl; rein visuell → Fehler nur geloggt.
    func applyFormat(_ command: String) async {
        guard Self.allowedFormatCommands.contains(command) else {
            log.error("applyFormat: unbekannter Befehl \(command, privacy: .public)")
            return
        }
        await emit("format", ["command": command])
    }

    /// Erlaubte History-Aktionen. Whitelist wie bei den Formatbefehlen — der
    /// Glue reicht den Wert unbesehen an das Standalone-Handle durch.
    static let allowedHistoryActions: Set<String> = ["undo", "redo"]

    /// Widerrufen/Wiederherstellen im Editor (`history`-Event).
    ///
    /// Warum über die Bridge und nicht über WebKits Undo-Stack: Der gebündelte
    /// Focus-Editor führt seit dem Hauptrepo-Commit „undo/redo" eine EIGENE
    /// Snapshot-Historie (`shared/edit-history.js`, entprellt → satzweise
    /// Schritte) und fängt ⌘Z in der Seite selbst ab. In diesem Client erreicht
    /// die Taste die WebView aber nie: ein Menü-Kürzel greift app-weit VOR der
    /// WKWebView. Der Menüpunkt muss die Aktion darum selbst auslösen — genau
    /// wie beim Format-Menü (⌘B/⌘I/⌘U).
    ///
    /// WebKits eigener (grober) Undo-Stack wird damit nie mehr angesprochen; er
    /// wird beim Seitenwechsel zusätzlich geleert (`resetUndo`).
    func applyHistory(_ action: String) async {
        guard Self.allowedHistoryActions.contains(action) else {
            log.error("applyHistory: unbekannte Aktion \(action, privacy: .public)")
            return
        }
        await emit("history", ["action": action])
    }

    // MARK: - Text-Aktionen

    /// Normalisiert die typografischen Anführungszeichen der offenen Seite auf
    /// den Buch-Stil (`normalizeQuotes`-Event; Toolbar-Aktion). Der Quote-Stil
    /// hängt an der Buch-Locale (de-CH → «», de-DE → „" …), die der Swift-Kern
    /// serverseitig aus `/booksettings/:id` liest — der modulinterne `fetch` im
    /// gebündelten `quote-normalize.js` liefe in der lokalen WebView (swk-app://)
    /// ins Leere. Der Glue nutzt darum nur die fetch-freien Exports
    /// (`resolveQuoteStyle` + `normalizeQuotes`) und sichert danach local-first.
    /// Buch aus UserDefaults (wie die `activeBook`-Op); ohne Server-Antwort fällt
    /// der Glue auf de/CH zurück. No-op ohne WebView; Fehler nur geloggt (rein
    /// textverändernd, der Autosave holt den Stand ohnehin nach).
    func normalizeQuotes() async {
        guard webView != nil else { return }
        let locale = await bookQuoteLocale(bookId: Self.activeBookId)
        await emit("normalizeQuotes", ["language": locale.language ?? "de",
                                       "region": locale.region ?? "CH"])
    }

    /// Öffnet die Synonym-Hilfe für das Wort unter Auswahl/Caret (`synonyms`-
    /// Event; Toolbar-Knopf und Kontextmenü-Eintrag). Fachlich identisch zu ⌘⇧S
    /// im Editor — der Glue feuert genau dieses Tastenereignis synthetisch am
    /// Editor-Root, damit die Wort-/Selektions-Logik des gebündelten Controllers
    /// (SSoT, kein Fork) unverändert greift. Der Klick in der Titelleiste nimmt
    /// der WebView den Fokus → vorher wieder zum First Responder machen, sonst
    /// steht kein Caret/keine Auswahl mehr zur Verfügung.
    ///
    /// `point` (CSS-Viewport-Koordinaten) kommt vom Kontextmenü: der Rechtsklick
    /// setzt in einem contenteditable nicht zuverlässig den Caret, darum bestimmt
    /// der Glue das Wort über `caretRangeFromPoint`. Nicht-endliche oder negative
    /// Koordinaten werden verworfen (dann gilt die bestehende Auswahl). No-op ohne
    /// WebView; rein UI-öffnend → Fehler nur geloggt.
    func openSynonyms(at point: CGPoint? = nil) async {
        guard let webView else { return }
        webView.window?.makeFirstResponder(webView)
        var payload: [String: Any?] = [:]
        if let point, point.x.isFinite, point.y.isFinite, point.x >= 0, point.y >= 0 {
            payload = ["x": Double(point.x), "y": Double(point.y)]
        }
        await emit("synonyms", payload)
    }

    // MARK: - Awaitbare Direktaufrufe

    /// Persistiert den offenen Draft sofort (`_flushSave`) und WARTET darauf —
    /// für ⌘S, das vor dem manuellen Sync den aktuellen Stand sichern soll
    /// (der Editor-Autosave läuft entprellt). Awaitable im Gegensatz zum
    /// Event-Bus (`_receive`), damit der Outbox-Eintrag garantiert vor dem
    /// Push liegt. No-op ohne WebView/offenen Editor; Fehler/Timeout werden nur
    /// geloggt (der Autosave holt den Stand ohnehin nach → kein Datenverlust),
    /// aber der wartende Aufrufer (Sync, Lektorats-Vorlauf) kommt garantiert frei.
    func flushDraftSave() async {
        await flushDraftSave(timeout: EditorBridge.jsCallTimeout)
    }

    /// Wie `flushDraftSave()`, aber mit eigener Frist. Eigene Überladung statt
    /// eines Default-Arguments: `EditorCoordinating` verlangt die parameterlose
    /// Signatur, und ein Default-Argument erfüllt sie nicht.
    func flushDraftSave(timeout: Duration) async {
        await callJS("flushDraftSave", """
            const fb = window.__focusBridge;
            if (fb && typeof fb._flushSave === 'function') { return await fb._flushSave(); }
            return null;
            """,
            timeout: timeout)
    }

    /// Knapper bemessener Flush für den Beenden-Pfad (`applicationShouldTerminate`).
    /// Beenden darf nicht am hängenden JS kleben — 2 s reichen für den einen
    /// `save()`-Roundtrip (LocalStore-Write, kein Netz) und halten ⌘Q flott.
    nonisolated static let quitFlushTimeout: Duration = .seconds(2)

    /// Ruft `block-merge.js` in der WebView (3-Wege-Merge). Wirft, wenn keine
    /// WebView/kein Bundle verfügbar ist oder der Merge nicht rechtzeitig
    /// antwortet → der Aufrufer behandelt das als Konflikt.
    func merge3(base: String?, local: String, server: String) async throws -> MergeOutcome {
        let result = try await evaluateJS("""
            const fb = window.__focusBridge;
            if (!fb || typeof fb._merge3 !== 'function') { return null; }
            return await fb._merge3(base, local, server);
            """,
            arguments: ["base": base ?? "", "local": local, "server": server],
            timeout: Self.mergeTimeout,
            timeoutError: .mergeTimedOut)
        guard let dict = result as? [String: Any],
              let merged = dict["merged"] as? String else {
            throw BridgeError.mergeFailed
        }
        let count = Self.clampedCount(dict["conflictCount"])
        return MergeOutcome(merged: merged, conflictCount: count)
    }
}

/// Erfüllt eine Continuation genau einmal — der Wettlauf zwischen JS-Antwort und
/// Timeout in `evaluateJS` darf nicht doppelt resumen (Absturz).
@MainActor
private final class ResumeOnce {
    private var continuation: CheckedContinuation<Any?, Error>?

    init(_ continuation: CheckedContinuation<Any?, Error>) {
        self.continuation = continuation
    }

    func resume(with result: Result<Any?, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}
