//
//  LibraryStore.swift
//  schreibwerkstatt-focuseditor
//
//  Zustand für Buch- und Seitenauswahl. Hält die Bücherliste, das aktive Buch
//  (persistiert) und die Seiten des aktiven Buchs für den Picker. „Seite öffnen"
//  läuft über die WebView-Bridge (`openPage`).
//
//  Offline-first: Die Seitenliste kommt bevorzugt aus dem Server-Tree
//  (autoritative Reihenfolge + Kapitelnamen). Ist der Server nicht erreichbar,
//  fällt sie auf den lokalen Spiegel (`LocalStore.list(bookId:)`) zurück — was
//  schon gesynct wurde, bleibt auswählbar.
//
//  Das aktive Buch ist KEIN Geheimnis (nur eine ID) → Persistenz in
//  UserDefaults ist zulässig (im Gegensatz zum Device-Token, das nur in die
//  Keychain gehört).
//

import Foundation
import Combine
import OSLog

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var books: [BookDTO] = []
    @Published private(set) var activeBookId: Int? {
        didSet {
            guard activeBookId != oldValue else { return }
            onWritingContextChange?(activeBookId, openPageId != nil)
        }
    }
    @Published private(set) var pages: [PagePickerRow] = []
    /// Zählwerte (Zeichen/Wörter) je Seiten-ID des aktiven Buchs — aus dem lokalen
    /// Spiegel, weil der Server-Tree keine liefert. Speist die Zahl an der
    /// Picker-Zeile und die Summenzeile. Eine Seite, deren Inhalt nie gepullt
    /// wurde, FEHLT hier bewusst (der Picker zeigt „—" statt einer erfundenen 0).
    @Published private(set) var pageStats: [Int: PageStats] = [:]
    /// Seiten mit offenem Outbox-Eintrag (lokal geändert, noch nicht am Server) —
    /// treibt den dezenten Punkt an der Picker-Zeile („ist mein Text schon drüben?").
    @Published private(set) var unsavedPageIds: Set<Int> = []
    /// Aktuell im Editor geöffnete Seite (von der Bridge gemeldet bzw. per Picker
    /// gewählt) — treibt die Seiten-Anzeige in der Toolbar.
    @Published private(set) var openPageId: Int? {
        didSet {
            guard openPageId != oldValue else { return }
            onWritingContextChange?(activeBookId, openPageId != nil)
        }
    }
    /// Meldet Änderungen am „wo schreibt der Nutzer"-Kontext (aktives Buch + ob
    /// eine Seite offen ist) — Grundlage fürs Schreibzeit-Tracking
    /// ([WritingTimeTracker](../Writing/WritingTimeTracker.swift)). Bewusst ein
    /// schlichter Callback wie `bridge.onStats`/`onOpenPageChange` (kein Combine-
    /// Sink — das Projekt verdrahtet Stores durchweg über Callbacks).
    var onWritingContextChange: ((_ bookId: Int?, _ hasOpenPage: Bool) -> Void)?
    /// Hat die offene Seite ungespeicherte (lokale) Änderungen? Treibt den
    /// Save-Indikator in der Toolbar (von der Bridge via `editorState` gemeldet).
    @Published private(set) var openPageDirty = false
    /// Zähler, der hochzählt, wenn die View den Seiten-Picker öffnen soll —
    /// beim echten Buchwechsel und beim bewussten Schliessen der Seite (damit der
    /// Nutzer direkt die nächste Seite wählt). Reines Event-Signal, kein Zustand.
    @Published private(set) var pickerOpenRequest = 0
    /// Läuft ein echter Buchwechsel (offene Seite geschlossen, Seiten des neuen
    /// Buchs werden geladen)? Treibt den zentrierten Lade-Donut und blendet den
    /// Picker so lange aus — er öffnet erst wieder, wenn die Seiten geladen sind.
    @Published private(set) var isSwitchingBook = false
    @Published private(set) var isLoadingBooks = false
    @Published private(set) var isLoadingPages = false
    /// Wurde die Bücherliste schon mindestens einmal (erfolgreich) geladen?
    /// Unterscheidet „lädt noch / unbekannt" von „geladen, aber leer" — nur im
    /// zweiten Fall zeigt der Editor-Host den „keine Bücher"-Hinweis statt der
    /// generischen Leerfläche (sonst blitzte er beim Start kurz auf).
    @Published private(set) var booksLoaded = false
    @Published var lastError: String?
    /// Meldung eines fehlgeschlagenen LOKALEN Saves (Platte voll / DB-Fehler) —
    /// treibt einen sichtbaren Warn-Banner über dem Editor. `nil` = kein Fehler.
    /// Wird vom nächsten erfolgreichen Save automatisch wieder gelöst. Über die
    /// Bridge (`onSaveResult`) in `AppCore` gespeist.
    @Published var saveError: String?
    /// Zuletzt gemeldetes Widerrufen/Wiederherstellen im Editor (⌘Z / ⌘⇧Z) mit
    /// nennenswertem Umfang — treibt einen kurzen Hinweis über der Schreibfläche.
    /// `nil` = kein Hinweis offen. Über die Bridge (`onHistoryEdit`) in `AppCore`
    /// gespeist. Reiner Anzeige-Zustand; Inhalte bleiben unangetastet.
    @Published var historyNotice: HistoryNotice?

    /// Ein gemeldetes Widerrufen/Wiederherstellen (⌘Z / ⌘⇧Z) für den Hinweis
    /// über der Schreibfläche. `id` macht den Auto-Ausblender eindeutig, damit
    /// ein neuer Hinweis den alten Timer nicht mit sich wegräumt.
    struct HistoryNotice: Identifiable, Equatable {
        let id = UUID()
        /// `true` = Widerrufen (Text entfernt), `false` = Wiederherstellen.
        let isUndo: Bool
        /// Umfang in Zeichen (Betrag).
        let chars: Int
    }

    /// Ab diesem Umfang lohnt der Hinweis (kleinere Korrekturen bleiben still).
    private static let minNoticeChars = 40
    /// So lange bleibt der Hinweis stehen, wenn ihn niemand schliesst.
    private static let noticeSeconds = 9.0
    /// Auto-Ausblender des offenen Hinweises.
    private var noticeTask: Task<Void, Never>?

    private let content: ContentAPI
    private let store: any LocalStore
    private let bridge: EditorBridge
    /// Persistenz des aktiven Buchs — injizierbar, damit die Tests eine eigene
    /// Suite verwenden (produktiv immer `.standard`).
    private let defaults: UserDefaults
    private let log = AppLog.library

    /// Aktives Buch ist server-spezifisch (eine Buch-ID gilt nur am Server, der
    /// sie vergeben hat) → Key pro Server-Namespace. Sonst wählt der Client am
    /// neuen Server eine Buch-ID des alten (→ `NO_BOOK_ACCESS`). Prefix und
    /// Alt-Key kommen aus `ServerScopedKey`, damit sie nicht gegen die zweite
    /// lesende Stelle (`EditorBridge.activeBookKey`) driften können.
    private static func bookDefaultsKey() -> String { ServerScopedKey.activeBookId.key() }
    private var defaultsKey: String { Self.bookDefaultsKey() }
    private static let legacyDefaultsKey = ServerScopedKey.activeBookId.rawValue

    init(content: ContentAPI, store: any LocalStore, bridge: EditorBridge, defaults: UserDefaults = .standard) {
        self.content = content
        self.store = store
        self.bridge = bridge
        self.defaults = defaults
        // Alt-Key (global) einmalig in den Namespace des aktuellen Servers ziehen.
        Self.migrateLegacyBookKeyIfNeeded(defaults)
        // Aktives Buch wiederherstellen (0 = nicht gesetzt).
        let saved = defaults.integer(forKey: Self.bookDefaultsKey())
        self.activeBookId = saved == 0 ? nil : saved
        // Offene Seite vom Editor übernehmen (per Picker geöffnet oder beim Boot
        // wiederhergestellt) — hält die Toolbar-Anzeige aktuell.
        bridge.onOpenPageChange = { [weak self] pageId in
            guard let self else { return }
            // Der optimistische `openPage`-Write setzt `openPageId` bereits; die
            // spätere `editorState`-Bestätigung darf NICHT erneut publizieren, wenn
            // sich nichts ändert (sonst zweite View-Invalidierung → Flackern des
            // Leerzustands über `.animation(value: openPageId)`).
            let newValue = pageId.flatMap(Int.init)
            if self.openPageId != newValue { self.openPageId = newValue }
        }
        // Dirty-Zustand der offenen Seite → Save-Indikator in der Toolbar.
        bridge.onOpenDirtyChange = { [weak self] dirty in
            guard let self else { return }
            if self.openPageDirty != dirty { self.openPageDirty = dirty }
        }
    }

    /// Anzeigename des aktiven Buchs (für die Toolbar).
    var activeBookName: String? {
        guard let id = activeBookId else { return nil }
        return books.first { $0.id == id }?.name
    }

    /// Name der aktuell offenen Seite (für die Toolbar), aufgelöst über die
    /// Seitenliste des aktiven Buchs. `nil`, solange keine Seite offen ist oder
    /// die Seite (noch) nicht in der Liste steht.
    var openPageName: String? {
        guard let id = openPageId else { return nil }
        return pages.first { $0.id == id }?.name
    }

    /// Kapitelname der aktuell offenen Seite (für die Toolbar, als Kontext links
    /// neben dem Seitennamen). `nil`, wenn keine Seite offen ist oder die Seite
    /// keinem Kapitel zugeordnet ist (bzw. nur der lokale Fallback greift).
    var openChapterName: String? {
        guard let id = openPageId,
              let chapter = pages.first(where: { $0.id == id })?.chapterName,
              !chapter.isEmpty else { return nil }
        return chapter
    }

    /// Die zuletzt gerätelokal geöffnete Seite (pro Server), aufgelöst gegen die
    /// aktuelle Seitenliste — Grundlage für „Zuletzt fortsetzen" im Leerzustand.
    /// `nil`, wenn nie eine Seite geöffnet wurde oder sie nicht (mehr) im aktiven
    /// Buch liegt.
    var lastOpenPageRow: PagePickerRow? {
        // Buch-skopierte Erinnerung (pro aktivem Buch), Fallback auf den globalen
        // Legacy-Wert — beide werden gegen die Seitenliste des aktiven Buchs
        // aufgelöst, sodass nie eine Seite eines anderen Buchs erscheint.
        let raw = activeBookId.flatMap { EditorBridge.lastOpenPageId(forBook: $0) }
            ?? UserDefaults.standard.string(forKey: EditorBridge.lastOpenPageKey)
        guard let raw, let id = Int(raw) else { return nil }
        return pages.first { $0.id == id }
    }

    /// Die zuletzt geöffneten Seiten des aktiven Buchs (gerätelokal, MRU-Reihenfolge)
    /// — aufgelöst gegen die aktuelle Seitenliste, damit nie eine gelöschte oder
    /// verschobene Seite eines anderen Buchs erscheint. Speist die Gruppe „Zuletzt
    /// geöffnet" ganz oben im Seiten-Picker. Leer, solange nichts geöffnet wurde.
    func recentPageRows(limit: Int = EditorBridge.recentPagesLimit) -> [PagePickerRow] {
        guard let bookId = activeBookId else { return [] }
        let ids = EditorBridge.recentPageIds(forBook: bookId, defaults: defaults)
        let rows = ids.compactMap { raw -> PagePickerRow? in
            guard let id = Int(raw) else { return nil }
            return pages.first { $0.id == id }
        }
        return Array(rows.prefix(limit))
    }

    // MARK: - Laden

    /// Bücherliste vom Server holen. Ohne aktives Buch wird das erste gewählt.
    func loadBooks() async {
        isLoadingBooks = true
        defer { isLoadingBooks = false }
        do {
            let fetched = try await content.books()
            books = fetched
            booksLoaded = true
            lastError = nil
            // Aktives Buch validieren / Default setzen.
            if let id = activeBookId, fetched.contains(where: { $0.id == id }) {
                await refreshPages()
            } else if let first = fetched.first {
                selectBook(first.id)
            }
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            log.error("Bücher laden fehlgeschlagen: \(self.lastError ?? "?", privacy: .public)")
        }
    }

    /// Buch wählen: persistieren + Seitenliste neu laden.
    ///
    /// Bei einem echten Wechsel (vorher war schon ein Buch aktiv) wird die offene
    /// Seite zuerst geschlossen — der Editor soll nicht den Text des alten Buchs
    /// weiterzeigen — und anschliessend der Seiten-Picker geöffnet, damit der
    /// Nutzer direkt eine Seite des neuen Buchs wählt. Die initiale Auswahl beim
    /// Start (vorher kein Buch aktiv) lässt den Editor seine erste Seite normal
    /// laden, ohne Picker-Popup.
    func selectBook(_ id: Int) {
        guard id != activeBookId else { return }
        let isSwitch = activeBookId != nil
        activeBookId = id
        defaults.set(id, forKey: defaultsKey)
        guard isSwitch else {
            Task { await refreshPages() }
            return
        }
        // Offene Seite sofort schliessen (Toolbar leert sich), dann den Editor
        // leeren und den Picker mit den Seiten des neuen Buchs öffnen.
        openPageId = nil
        dismissHistoryNotice()
        // Seitenliste des alten Buchs sofort weg — sonst könnte ein Picker, der
        // vor dem Laden aufgeht, eine Seite des ALTEN Buchs öffnen.
        pages = []
        pageStats = [:]
        // Picker sofort ausblenden + Lade-Donut zeigen; erst nach geladener
        // Seitenliste den Picker des neuen Buchs wieder öffnen.
        isSwitchingBook = true
        Task {
            await bridge.closePage()
            await refreshPages()
            // Zwischenzeitlich schon das nächste Buch gewählt (A→B→C bei langsamem
            // Netz)? Dann gehört der Abschluss dem jüngsten Wechsel — sonst öffnete
            // dieser Task den Picker mit den Seiten von B, während C aktiv ist.
            guard activeBookId == id else { return }
            isSwitchingBook = false
            pickerOpenRequest &+= 1
        }
    }

    /// Seitenliste des aktiven Buchs aktualisieren (Server-Tree, sonst lokal).
    func refreshPages() async {
        guard let bookId = activeBookId else {
            pages = []
            pageStats = [:]
            unsavedPageIds = []
            return
        }
        isLoadingPages = true
        defer { isLoadingPages = false }
        do {
            let rows = try await content.pickerRows(bookId: bookId)
            // Buchwechsel-Race: Während dieses (evtl. langsamen) Tree-Loads kann der
            // Nutzer schon zum nächsten Buch gewechselt haben — eine späte Antwort
            // des ALTEN Buchs darf die Seiten des neuen nicht überschreiben.
            guard bookId == activeBookId else { return }
            pages = rows
            lastError = nil
        } catch {
            guard bookId == activeBookId else { return }
            // Offline / Serverfehler → lokalen Spiegel zeigen (kein Datenverlust,
            // nur ohne Kapitel-Gruppierung/Order).
            log.notice("Tree nicht erreichbar — lokaler Fallback für Buch \(bookId, privacy: .public)")
            pages = await localRows(bookId: bookId)
            // Greift der lokale Spiegel (Seiten vorhanden), still bleiben — der
            // Nutzer kann weiterarbeiten. Ist auch lokal nichts da, würde der
            // Picker fälschlich „keine Seiten“ zeigen → den Fehler vermerken,
            // damit der Leerzustand den wahren Grund (Verbindung) nennt.
            lastError = pages.isEmpty
                ? ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                : nil
        }
        // Zählwerte + Outbox-Zustand passend zur frischen Liste nachziehen. Läuft
        // in DEMSELBEN Aufruf, damit die Picker-Zeilen nicht erst ohne und dann
        // mit Zahl erscheinen (ein Umbau der Liste würde sonst flackern).
        await refreshPageStats()
    }

    /// Liest die Zählwerte des aktiven Buchs (lokaler Spiegel) und die Seiten mit
    /// offenem Outbox-Eintrag. Beides ist reine Anzeige — ein Fehler degradiert
    /// still zu „keine Zahlen" (die Picker-Zeile zeigt dann „—").
    func refreshPageStats() async {
        guard let bookId = activeBookId else {
            pageStats = [:]
            unsavedPageIds = []
            return
        }
        let raw = (try? await store.pageStats(bookId: bookId)) ?? [:]
        // Späte Antwort eines inzwischen abgewählten Buchs verwerfen (gleicher
        // Race-Schutz wie in `refreshPages`).
        guard bookId == activeBookId else { return }
        var mapped: [Int: PageStats] = [:]
        mapped.reserveCapacity(raw.count)
        for (id, stats) in raw {
            if let pid = Int(id) { mapped[pid] = stats }
        }
        pageStats = mapped
        // Outbox ist buch-übergreifend; auf die Seiten des Buchs zu filtern wäre
        // ein zweiter Store-Roundtrip ohne Nutzen — der Picker fragt nur nach IDs,
        // die er ohnehin anzeigt.
        let pending = (try? await store.pendingOutbox()) ?? []
        unsavedPageIds = Set(pending.compactMap { Int($0.pageId) })
    }

    /// Mindestlänge einer Volltextsuche. Ein einzelnes Zeichen zöge das halbe Buch
    /// als Inhaltstreffer in den Picker — die Namens-/Kapitelsuche greift dort
    /// ohnehin schon. EINE Stelle für die Regel (der Picker fragt nur noch).
    static let minContentSearchLength = 2

    /// Volltextsuche über den lokal gespiegelten Seiteninhalt des aktiven Buchs —
    /// liefert die IDs der Seiten, deren BODY (nicht nur Name) zur Eingabe passt.
    /// Speist die zusätzlichen Inhaltstreffer im Picker. Nur lokal vorhandener
    /// Inhalt ist durchsuchbar (offline-first); ein Suchfehler degradiert still
    /// (leere Menge → der Picker zeigt einfach nur die Namens-/Kapiteltreffer).
    /// Eine zu kurze (oder leere) Eingabe liefert die leere Menge, ohne den Store
    /// zu behelligen.
    func searchContentIds(query: String) async -> Set<Int> {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= Self.minContentSearchLength else { return [] }
        let ids = (try? await store.searchContent(query: trimmed, bookId: activeBookId)) ?? []
        return Set(ids.compactMap(Int.init))
    }

    /// Fallback: Picker-Zeilen aus dem lokalen Spiegel (ohne Kapitel/Order).
    private func localRows(bookId: Int) async -> [PagePickerRow] {
        let summaries = (try? await store.list(bookId: bookId)) ?? []
        return summaries.compactMap { s in
            guard let pid = Int(s.id) else { return nil }
            // `updatedAt` im Spiegel ist Epoch-Millis (s. PageSummary).
            return PagePickerRow(id: pid, name: s.displayName, chapterPath: [],
                                 updatedAt: Date(timeIntervalSince1970: s.updatedAt / 1000))
        }
    }

    // MARK: - Öffnen

    /// Hebt die gewählte Seite über die Bridge in den Editor.
    func openPage(_ row: PagePickerRow) {
        let previous = openPageId
        // Der ⌘Z/⌘⇧Z-Hinweis gehört zur bisherigen Seite: ihre Historie endet mit
        // dem Wechsel (setPage), ⌘⇧Z täte auf der neuen Seite nichts.
        if previous != row.id { dismissHistoryNotice() }
        openPageId = row.id   // sofortige Toolbar-Anzeige; editorState bestätigt später
        openPageDirty = false // frisch geöffnete Seite ist sauber
        Task {
            let ok = await bridge.openPage(pageId: String(row.id))
            if !ok {
                log.notice("openPage ohne WebView — Editor noch nicht bereit")
                // Die optimistische Anzeige zurücknehmen: ohne WebView kommt keine
                // `editorState`-Bestätigung, sonst zeigte die Toolbar dauerhaft eine
                // Seite als „offen", die der Editor nie geladen hat. Nur zurückrollen,
                // falls sich die Auswahl seither nicht schon weiterbewegt hat.
                if openPageId == row.id { openPageId = previous }
            }
        }
    }

    /// Die Seite wurde am Server gelöscht: späte Saves dafür verwerfen und sie,
    /// falls offen, im Editor schliessen. VOR dem lokalen Löschen aufrufen —
    /// der Close-Handler des Editors sichert noch einmal, und dieser Save käme
    /// sonst erst nach dem Löschen an und legte die Seite wieder an.
    func forgetDeletedPage(id: Int) {
        bridge.markPageDeleted(String(id))
        if openPageId == id { closePage() }
    }

    /// Schliesst die offene Seite (Toolbar-Aktion „Seite schliessen"). Die WebView
    /// sichert lokal (local-first), leert die Schreibfläche und zeigt die ruhige
    /// Leerfläche; danach öffnen wir den Picker, damit der Nutzer direkt die
    /// nächste Seite wählen kann. Kein Datenverlust — der Stand wurde vor dem
    /// Leeren gespeichert.
    func closePage() {
        guard openPageId != nil else { return }
        dismissHistoryNotice()    // der Hinweis gehört zur geschlossenen Seite
        openPageId = nil          // Toolbar sofort leeren
        Task {
            await bridge.closePage()
            pickerOpenRequest &+= 1
        }
    }

    /// Normalisiert die typografischen Anführungszeichen der offenen Seite auf
    /// den Buch-Stil (Toolbar-Aktion). No-op ohne offene Seite. Die eigentliche
    /// Normalisierung läuft in der WebView (gebündeltes `quote-normalize.js` aus
    /// dem Hauptrepo, kein Fork); die Buch-Locale (→ Quote-Stil) holt der
    /// Swift-Kern serverseitig. Local-first — der Glue sichert direkt nach der
    /// Änderung.
    func normalizeQuotes() {
        guard openPageId != nil else { return }
        Task { await bridge.normalizeQuotes() }
    }

    /// Öffnet die Synonym-Hilfe für das Wort unter Auswahl/Caret (Toolbar-
    /// Aktion) — der klickbare Zwilling zu ⌘⇧S, für alle, die den Hotkey nicht
    /// kennen. No-op ohne offene Seite. Die Auswahl-Logik und das Menü liefert
    /// der gebündelte Synonym-Controller aus dem Hauptrepo (kein Fork).
    func openSynonyms() {
        guard openPageId != nil else { return }
        Task { await bridge.openSynonyms() }
    }

    /// Bittet die View, den Seiten-Picker einzublenden (Menü-/Toolbar-Einstieg
    /// „Seite öffnen"). Reines Event-Signal über `pickerOpenRequest`, das
    /// [ContentView](../ContentView.swift) beobachtet — der Menübefehl im
    /// `App`-Scope hat keinen Zugriff auf den `pickerOpen`-State der View.
    func requestPicker() {
        pickerOpenRequest &+= 1
    }

    /// Ergebnis eines lokalen Saves aus der Bridge: `nil` = erfolgreich (löst einen
    /// etwaigen Warn-Banner), sonst die Fehlermeldung (zeigt den Banner). Nur bei
    /// echter Änderung publizieren — der Erfolgsfall feuert bei JEDEM Auto-Save.
    func reportSaveResult(_ message: String?) {
        if saveError != message { saveError = message }
    }

    /// Verwirft eine offene Save-Fehler-Meldung (Banner-Schliessen durch den Nutzer).
    func dismissSaveError() {
        if saveError != nil { saveError = nil }
    }

    // MARK: - Widerrufen / Wiederherstellen

    /// Ein Widerrufen (`undo == true`) bzw. Wiederherstellen im Editor hat gerade
    /// `chars` Zeichen entfernt bzw. wieder eingesetzt.
    ///
    /// Gezeigt wird nur, was ins Gewicht fällt (`minNoticeChars`): ein einzelnes
    /// Wort zurückzunehmen braucht keinen Hinweis. Grund für den Hinweis
    /// überhaupt: WebKit fasst eine ganze Tippstrecke in EINEN Undo-Schritt
    /// zusammen (alles seit dem letzten Mausklick), ein versehentliches ⌘Z
    /// entfernt also unter Umständen den ganzen Abschnitt — und der Auto-Save
    /// persistiert das still. Der Hinweis nennt den Rückweg (⌘⇧Z), solange er
    /// noch offen ist (WebKits Redo verfällt beim nächsten Tastendruck).
    func reportHistoryEdit(undo: Bool, chars: Int) {
        guard chars >= Self.minNoticeChars else { return }
        let notice = HistoryNotice(isUndo: undo, chars: chars)
        historyNotice = notice
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.noticeSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard let self, self.historyNotice?.id == notice.id else { return }
            self.historyNotice = nil
        }
    }

    /// Verwirft den Hinweis (Schliessen durch den Nutzer oder Seitenwechsel).
    func dismissHistoryNotice() {
        noticeTask?.cancel()
        noticeTask = nil
        if historyNotice != nil { historyNotice = nil }
    }

    // MARK: - Server-Wechsel

    /// Server-Wechsel: Buch-/Seiten-Zustand des alten Servers verwerfen, das
    /// aktive Buch aus dem Namespace des neuen Servers laden und die Bücherliste
    /// neu ziehen. So zeigt der Picker keine Bücher des alten Servers mehr.
    func reloadForCurrentServer() {
        books = []
        booksLoaded = false
        pages = []
        pageStats = [:]
        unsavedPageIds = []
        openPageId = nil
        openPageDirty = false
        lastError = nil
        saveError = nil
        dismissHistoryNotice()
        let saved = defaults.integer(forKey: defaultsKey)
        activeBookId = saved == 0 ? nil : saved
        Task { await loadBooks() }
    }

    /// Einmal-Migration: den globalen Alt-Key in den Namespace des aktuell
    /// konfigurierten Servers übertragen, falls dort noch nichts steht. Danach den
    /// Alt-Key entfernen, damit er nicht erneut auf einen anderen Server „leakt".
    private static func migrateLegacyBookKeyIfNeeded(_ defaults: UserDefaults) {
        let legacy = defaults.integer(forKey: legacyDefaultsKey)
        guard legacy != 0 else { return }
        let targetKey = bookDefaultsKey()
        if defaults.integer(forKey: targetKey) == 0 {
            defaults.set(legacy, forKey: targetKey)
        }
        defaults.removeObject(forKey: legacyDefaultsKey)
    }
}
