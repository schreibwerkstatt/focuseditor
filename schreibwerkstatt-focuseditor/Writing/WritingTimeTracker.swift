//
//  WritingTimeTracker.swift
//  schreibwerkstatt-focuseditor
//
//  Schreibzeit-Tracking: misst, wie lange der Nutzer im Editor verbringt, und
//  meldet die Sekunden an den Server (`POST /history/writing-time`, serverseitig
//  pro Buch/Tag aufaddiert). Das native Pendant zum Heartbeat der Web-Plattform
//  (`public/js/book/writing-time.js` im Hauptrepo).
//
//  Kontext-Bedingung wie dort: gezählt wird, solange das Fenster aktiv ist UND
//  eine Seite im aktiven Buch offen ist — das Analog zur Web-Bedingung
//  `(editMode||focusActive) && selectedBookId && visible`. (Dieser Client hat
//  keinen Buchorganizer; „in der App mit offener Seite" = „im Editor".)
//
//  ZUSÄTZLICH (anders als die Web-Plattform) eine Idle-Erkennung: liegt das
//  Tippen länger als `idleThreshold` (120 s) zurück, wird die Schreibzeit
//  pausiert. Anrechenbar ist nur Zeit bis `letzte Aktivität + idleThreshold`;
//  längere Tipp-Pausen (Lesen, Weglaufen) zählen nicht. „Aktivität" ist jede
//  `reportStats`-Meldung der WebView (debounced bei `input` → echtes Tippen),
//  geliefert über `bridge.onActivity` → `notifyActivity()`; ein frischer
//  Segment-Start (Seite geöffnet / Fenster aktiviert) zählt ebenfalls als
//  Aktivität, damit die Uhr nicht sofort abläuft.
//
//  Best-effort: nicht bestätigte Sekunden bleiben in `pending` (pro Buch) und
//  werden beim nächsten Tick erneut gesendet — eine kurze Offline-Phase geht so
//  nicht verloren. Der Puffer wird zusätzlich SERVER-SKOPIERT in den UserDefaults
//  persistiert (`writingtime.pending.<slug>`), damit ein Crash/Beenden ZWISCHEN
//  zwei Heartbeats die bereits gezählte Zeit nicht verliert — beim nächsten Start
//  (oder Server-Rückwechsel) wird sie geladen und gesendet. Inhalte/Outbox sind
//  nie betroffen; ein verlorener Ping kostet höchstens ein paar Sekunden Statistik.
//
//  Beim Beenden (`NSApplication.willTerminate`) wird das laufende Segment noch
//  abgeschlossen: `⌘Q` liefert keinen verlässlichen Scene-Phasen-Wechsel mehr, die
//  seit dem letzten Heartbeat gezählten Sekunden (bis zu 15 s) gingen sonst
//  verloren. `captureSegment` schreibt sie in `pending` → `didSet` persistiert
//  synchron, der nächste Start sendet sie.
//
//  Testbarkeit: Uhr (`now`) und `UserDefaults` sind injizierbar, und der
//  Heartbeat-Rumpf steckt in `heartbeatTick()` — so lässt sich die Idle-/Deckel-
//  Arithmetik ohne echtes Warten prüfen (WritingTimeTrackerTests).
//

import Foundation
import Combine
import AppKit
import os

@MainActor
final class WritingTimeTracker: ObservableObject {
    private let api: APIClient
    /// Nur melden, wenn angemeldet (sonst 401). Spiegelt `SyncEngine.shouldSync`.
    private let isSignedIn: () -> Bool
    /// Uhr — injizierbar, damit Tests die Idle-/Deckel-Arithmetik ohne echtes
    /// Warten durchspielen können. Produktiv immer `Date.init`.
    private let now: () -> Date
    /// Persistenz-Backend (injizierbar → hermetische Tests, produktiv `.standard`).
    private let defaults: UserDefaults
    /// Beobachter für `willTerminate` (im `deinit` wieder abgemeldet).
    private var terminateObserver: NSObjectProtocol?
    private let log = AppLog.writingTime

    /// Heartbeat-Kadenz — wie die Web-Seite (15 s).
    private let heartbeatInterval: Duration = .seconds(15)
    /// Der Server clampt jeden Ping auf 1 h (Schutz gegen Uhrsprünge); lokal
    /// genauso deckeln, damit ein Ping nie serverseitig beschnitten „verloren"
    /// scheint — Überhang drainiert über mehrere Ticks.
    private let maxSecondsPerPing = 3600
    /// Tipp-Pause, ab der die Schreibzeit als idle pausiert. Zeit über diese
    /// Schwelle hinaus (seit der letzten Aktivität) wird nicht angerechnet.
    private let idleThreshold: TimeInterval = 120

    // MARK: - Eingänge (gespiegelt)

    /// Fenster im Vordergrund (Scene-Phase `.active`) — wie beim Sync-Poll.
    private var isActive = false
    /// Ob eine Seite im Editor offen ist (vom LibraryStore gemeldet).
    private var hasOpenPage = false
    /// Aktives Buch — Verbuchungs-Schlüssel der gemeldeten Zeit.
    private var activeBookId: Int?

    // MARK: - Laufendes Segment

    /// Start des aktuell laufenden Zähl-Segments (`nil` = zählt gerade nicht).
    private var segmentStart: Date?
    /// Buch, unter dem das laufende Segment verbucht wird. Eingefroren beim Start,
    /// damit ein Buchwechsel die bereits gezählte Zeit nicht umbucht.
    private var segmentBookId: Int?
    /// Zeitpunkt der letzten Nutzer-Aktivität (Tippen / Segment-Start). Deckelt die
    /// anrechenbare Zeit (`+ idleThreshold`) und treibt das Idle-Aufwachen. `nil` =
    /// noch keine Aktivität in dieser Sitzung gesehen.
    private var lastActivityAt: Date?

    /// Noch nicht vom Server bestätigte Sekunden, pro Buch. Wächst bei Sende-
    /// Fehlern (offline) und wird beim nächsten Tick erneut versucht. Jede Änderung
    /// wird persistiert (server-skopiert), damit der Puffer einen Neustart übersteht.
    private var pending: [Int: Int] = [:] {
        didSet { persistPending() }
    }
    /// Server-Slug, zu dem der aktuelle `pending` gehört (Buch-IDs gelten nur am
    /// Server, der sie vergeben hat). Bestimmt den Persistenz-Schlüssel; bei einem
    /// Server-Wechsel über `reset()` umgebunden.
    private var slug: String
    /// Verhindert überlappende Sendeläufe (Heartbeat + Stop-Flush gleichzeitig).
    private var isFlushing = false

    // MARK: - Heute-Anzeige (lokal, für die UI)

    /// Heute (lokaler Kalendertag) insgesamt angerechnete Schreibsekunden — für
    /// die UI („heute X Min geschrieben"). Anders als `pending` wird dieser Wert
    /// beim Senden NICHT abgezogen; er summiert über den Tag und setzt sich beim
    /// Tageswechsel zurück. Server-skopiert persistiert (überlebt Neustart).
    @Published private(set) var todaySeconds: Int = 0
    /// Kalendertag (yyyy-MM-dd), zu dem `todaySeconds` gehört. Wechselt er, wird
    /// die Tages-Summe zurückgesetzt.
    private var todayStamp: String = WritingTimeTracker.dayStamp()

    private var heartbeat: Task<Void, Never>?

    init(api: APIClient,
         isSignedIn: @escaping () -> Bool,
         now: @escaping () -> Date = Date.init,
         defaults: UserDefaults = .standard,
         observeTermination: Bool = true) {
        self.api = api
        self.isSignedIn = isSignedIn
        self.now = now
        self.defaults = defaults
        // Puffer des aktuell konfigurierten Servers aus einer früheren Sitzung
        // laden. Initialer Set im Init → didSet feuert nicht (kein Rück-Schreiben).
        self.slug = ServerNamespace.currentSlug
        self.pending = Self.loadPersisted(slug: self.slug, defaults: defaults)
        loadToday()
        if observeTermination { observeTerminate() }
    }

    deinit {
        if let terminateObserver {
            NotificationCenter.default.removeObserver(terminateObserver)
        }
    }

    /// Beim App-Beenden das laufende Segment noch gutschreiben. `⌘Q` beendet den
    /// Prozess, ohne dass zuverlässig ein Scene-Phasen-Wechsel (`setActive(false)`)
    /// durchkommt — ohne diesen Hook verfielen die seit dem letzten Heartbeat
    /// gezählten Sekunden. Senden geht hier nicht mehr (async), aber `pending`
    /// wird über `didSet` synchron persistiert; der nächste Start flusht.
    private func observeTerminate() {
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.captureSegment(continueCounting: false)
                self.stopHeartbeat()
            }
        }
    }

    /// Koppelt den Tracker an den LibraryStore: jede Änderung am „wo schreibt der
    /// Nutzer"-Kontext (aktives Buch / offene Seite) bewertet das Zählen neu.
    func attach(to library: LibraryStore) {
        library.onWritingContextChange = { [weak self] bookId, hasOpenPage in
            self?.updateContext(bookId: bookId, hasOpenPage: hasOpenPage)
        }
        // Anfangszustand übernehmen (der Callback feuert nur bei Änderungen).
        updateContext(bookId: library.activeBookId, hasOpenPage: library.openPageId != nil)
    }

    /// Der „wo schreibt der Nutzer"-Kontext (aktives Buch + offene Seite). Vom
    /// `LibraryStore`-Callback getrieben; als eigener Einstieg geführt, damit die
    /// Zähl-Logik ohne LibraryStore testbar bleibt.
    func updateContext(bookId: Int?, hasOpenPage: Bool) {
        activeBookId = bookId
        self.hasOpenPage = hasOpenPage
        reevaluate()
    }

    /// Vom Scene-Phasen-Wechsel getrieben (parallel zu `SyncEngine.setActive`).
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        // Beim Aktivieren einen evtl. aus einer früheren Sitzung restaurierten
        // Puffer best-effort senden — auch ohne offene Seite. `flushPending` no-opt,
        // falls (noch) nicht angemeldet; sonst greift der nächste Heartbeat-Tick.
        if active && !pending.isEmpty { Task { await self.flushPending() } }
        reevaluate()
    }

    /// Server-Wechsel: laufendes Segment beenden und die In-Memory-Sicht auf den
    /// neuen Server umbinden. Buch-IDs gelten nur am Server, der sie vergeben hat —
    /// sonst würde die Zeit am neuen Server auf eine fremde Buch-ID gebucht. Der
    /// persistierte Puffer des ALTEN Servers bleibt unter dessen Slug liegen (kein
    /// `removeAll` → kein Lösch-Schreiben) und wird bei einem Rückwechsel erneut
    /// gesendet; geladen wird der Puffer des NEUEN Servers.
    func reset() {
        stopHeartbeat()
        segmentStart = nil
        segmentBookId = nil
        lastActivityAt = nil
        slug = ServerNamespace.currentSlug
        pending = Self.loadPersisted(slug: slug, defaults: defaults)
        loadToday()
    }

    // MARK: - Zähl-Logik

    /// Gezählt wird, solange Fenster aktiv, eine Seite offen, ein Buch gewählt und
    /// angemeldet — das native Pendant zur Web-Bedingung.
    private var shouldCount: Bool {
        isActive && hasOpenPage && activeBookId != nil && isSignedIn()
    }

    /// Liegt die letzte Aktivität länger als `idleThreshold` zurück? Ohne je
    /// gesehene Aktivität `false` (nicht spurios pausieren — der Segment-Start
    /// setzt `lastActivityAt` ohnehin sofort).
    private var isIdle: Bool {
        guard let last = lastActivityAt else { return false }
        return now().timeIntervalSince(last) > idleThreshold
    }

    /// Aktuell gepufferte, noch nicht bestätigte Sekunden je Buch — Lesezugriff
    /// für die Tests (produktiv liest niemand mit).
    var pendingSeconds: [Int: Int] { pending }

    /// Vom `bridge.onActivity`-Hook bei jeder `reportStats`-Meldung gerufen
    /// (debounced bei `input` → echtes Tippen). Setzt die Idle-Uhr zurück und
    /// nimmt ein idle-pausiertes Segment wieder auf (Kontext zählt, Segment ruht).
    func notifyActivity() {
        lastActivityAt = now()
        if shouldCount, segmentStart == nil, let book = activeBookId {
            segmentStart = now()
            segmentBookId = book
            startHeartbeat()
        }
    }

    /// Bewertet nach jeder Eingangs-Änderung, ob (und unter welchem Buch) gezählt
    /// wird: startet/stoppt das Segment und schaltet den Heartbeat entsprechend.
    private func reevaluate() {
        if shouldCount, let book = activeBookId {
            if segmentStart == nil {
                // Frischer Start (Seite geöffnet / Fenster aktiviert / Login, oder
                // Aufwachen aus Idle-Pause): zählt als Aktivität, damit die Idle-Uhr
                // nicht sofort wieder abläuft.
                lastActivityAt = now()
                segmentStart = now()
                segmentBookId = book
                startHeartbeat()
            } else if segmentBookId != book {
                // Buchwechsel bei laufendem Zählen → bisherige Zeit dem alten Buch
                // gutschreiben, dann frisch fürs neue Buch weiterzählen.
                captureSegment(continueCounting: false)
                segmentStart = now()
                segmentBookId = book
            }
        } else if segmentStart != nil {
            // Zähl-Bedingung entfallen → letztes Stück sichern + Heartbeat aus.
            captureSegment(continueCounting: false)
            stopHeartbeat()
            Task { await self.flushPending() }
        }
    }

    /// Schreibt die seit `segmentStart` verstrichene Zeit dem Segment-Buch gut.
    /// `continueCounting == true`: das Segment läuft ab jetzt weiter (Heartbeat);
    /// `false`: das Segment endet.
    private func captureSegment(continueCounting: Bool) {
        guard let start = segmentStart, let book = segmentBookId else { return }
        let now = self.now()
        // Idle-Deckel: anrechenbar nur bis `letzte Aktivität + idleThreshold`.
        // Eine längere Tipp-Pause (Idle) wird so nicht mitgezählt — auch wenn der
        // Heartbeat sie erst beim nächsten Tick bemerkt, bindet der Deckel hier.
        let deadline = (lastActivityAt ?? start).addingTimeInterval(idleThreshold)
        let creditUntil = min(now, deadline)
        // Uhrsprung-Schutz: negativ (Uhr zurückgestellt) → verwerfen; nach oben
        // auf das Server-Limit deckeln. `.rounded()` mittelt die Sub-Sekunden-
        // Reste über die Ticks aus (kein systematisches Unterzählen).
        let elapsed = Int(creditUntil.timeIntervalSince(start).rounded())
        let seconds = min(max(0, elapsed), maxSecondsPerPing)
        if continueCounting {
            segmentStart = now
        } else {
            segmentStart = nil
            segmentBookId = nil
        }
        if seconds > 0 {
            pending[book, default: 0] += seconds
            creditToday(seconds)
        }
    }

    /// Schreibt die angerechneten Sekunden der Tages-Summe gut (für die UI). Beim
    /// Tageswechsel wird zuvor auf 0 zurückgesetzt.
    private func creditToday(_ seconds: Int) {
        let today = Self.dayStamp(now())
        if today != todayStamp {
            todayStamp = today
            todaySeconds = 0
        }
        todaySeconds += seconds
        persistToday()
    }

    // MARK: - Heartbeat (Task-Loop wie SyncEngine.startPolling)

    private func startHeartbeat() {
        guard heartbeat == nil else { return }
        heartbeat = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: self.heartbeatInterval)
                if Task.isCancelled { break }
                if await self.heartbeatTick() == .paused { break }
            }
        }
    }

    /// Ergebnis eines Heartbeat-Ticks: läuft das Segment weiter, oder wurde es
    /// (idle) pausiert? Steuert das Verlassen der Heartbeat-Schleife.
    enum TickResult: Equatable { case counting, paused }

    /// EIN Heartbeat-Schritt — Rumpf der Schleife, ohne das Warten. Getrennt
    /// geführt, damit Tests ihn mit einer gestellten Uhr direkt treiben können
    /// (kein 15-s-Sleep im Test).
    @discardableResult
    func heartbeatTick() async -> TickResult {
        if isIdle {
            // Idle: das Reststück bis zur Deadline gutschreiben (greift im
            // Deckel von captureSegment), Segment schließen und pausieren.
            // `notifyActivity()` nimmt es beim nächsten Tippen wieder auf.
            captureSegment(continueCounting: false)
            stopHeartbeat()
            await flushPending()
            return .paused
        }
        captureSegment(continueCounting: true)
        await flushPending()
        return .counting
    }

    private func stopHeartbeat() {
        heartbeat?.cancel()
        heartbeat = nil
    }

    // MARK: - Senden

    /// Sendet die gepufferten Sekunden je Buch. Erfolg → abziehen; Fehler →
    /// behalten (nächster Tick versucht erneut). Pro Ping aufs Server-Limit
    /// gedeckelt; ein größerer Rückstand drainiert über mehrere Ticks.
    private func flushPending() async {
        guard !isFlushing, isSignedIn() else { return }
        isFlushing = true
        defer { isFlushing = false }

        // Server, zu dem die Buch-IDs dieses Durchlaufs gehören. Ein Server-
        // Wechsel (`reset()`) während des Requests tauscht `slug` und `pending`
        // aus — die Bestätigung gilt dann dem Puffer des ALTEN Servers.
        let flushSlug = slug
        let api = self.api
        // Über eine Schlüssel-Kopie iterieren — `pending` kann zwischen den
        // `await`s von anderen MainActor-Ticks verändert werden.
        for book in Array(pending.keys) {
            guard let secs = pending[book], secs > 0 else { continue }
            let toSend = min(secs, maxSecondsPerPing)
            do {
                // Eigener, unstrukturierter Task: `stopHeartbeat()` bricht den
                // Heartbeat-Task ab — auch mitten in diesem Request. Ein
                // abgebrochener Request, den der Server schon verbucht hat,
                // bliebe sonst im Puffer und würde doppelt gesendet; der
                // abschliessende Ping vor einer Idle-Pause scheiterte immer.
                try await Task {
                    try await api.sendVoid("/history/writing-time", method: .POST,
                                           body: WritingTimePing(bookId: book, seconds: toSend))
                }.value
                guard slug == flushSlug else {
                    Self.subtractPersisted(slug: flushSlug, book: book, seconds: toSend,
                                           defaults: defaults)
                    return
                }
                let rest = (pending[book] ?? 0) - toSend
                pending[book] = rest > 0 ? rest : nil
            } catch {
                // Best-effort: behalten und beim nächsten Tick erneut versuchen.
                // Keine Inhalte betroffen. Bei einem Fehler die übrigen Bücher
                // diesmal nicht weiterversuchen (meist offline → ohnehin alle).
                log.debug("Schreibzeit-Ping fehlgeschlagen (Buch \(book, privacy: .public), \(secs, privacy: .public)s) — gepuffert")
                break
            }
        }
    }

    // MARK: - Persistenz (server-skopiert, überlebt App-Neustart)

    private static let pendingKeyPrefix = ServerScopedKey.writingTimePending.rawValue + "."

    /// Schreibt `pending` in die UserDefaults — unter dem Slug des Servers, zu dem
    /// die Buch-IDs gehören. Leerer Puffer → Eintrag entfernen (kein Müll-Key).
    private func persistPending() {
        let key = Self.pendingKeyPrefix + slug
        if pending.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            // UserDefaults verlangt String-Keys → Buch-ID als String ablegen.
            let encoded = Dictionary(uniqueKeysWithValues: pending.map { (String($0.key), $0.value) })
            defaults.set(encoded, forKey: key)
        }
    }

    /// Zieht bestätigte Sekunden vom persistierten Puffer eines (inzwischen
    /// nicht mehr aktiven) Servers ab — sonst sendete ein Rückwechsel sie erneut.
    private static func subtractPersisted(slug: String, book: Int, seconds: Int,
                                          defaults: UserDefaults) {
        let key = pendingKeyPrefix + slug
        guard var raw = defaults.dictionary(forKey: key) as? [String: Int],
              let current = raw[String(book)] else { return }
        let rest = current - seconds
        raw[String(book)] = rest > 0 ? rest : nil
        if raw.isEmpty { defaults.removeObject(forKey: key) } else { defaults.set(raw, forKey: key) }
    }

    /// Liest den persistierten Puffer eines Servers zurück (defensiv: nur positive
    /// Sekunden, nur ganzzahlige Buch-IDs — Fremdformate werden verworfen).
    private static func loadPersisted(slug: String, defaults: UserDefaults) -> [Int: Int] {
        let key = pendingKeyPrefix + slug
        guard let raw = defaults.dictionary(forKey: key) as? [String: Int] else { return [:] }
        var out: [Int: Int] = [:]
        for (k, v) in raw where v > 0 {
            if let id = Int(k) { out[id] = v }
        }
        return out
    }

    // MARK: - Tages-Summe (server-skopiert, überlebt App-Neustart)

    private static let todayKeyPrefix = ServerScopedKey.writingTimeToday.rawValue + "."

    /// Lokaler Kalendertag als stabiler Schlüssel (locale-unabhängig, ISO-Datum).
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func dayStamp(_ date: Date = Date()) -> String {
        dayFormatter.string(from: date)
    }

    /// Persistiert die Tages-Summe (Tag + Sekunden) unter dem aktuellen Server-Slug.
    private func persistToday() {
        let key = Self.todayKeyPrefix + slug
        defaults.set(["day": todayStamp, "seconds": todaySeconds], forKey: key)
    }

    /// Lädt die Tages-Summe des aktuellen Servers zurück — aber nur, wenn sie zum
    /// heutigen Kalendertag gehört; sonst frisch bei 0 beginnen (Tageswechsel).
    private func loadToday() {
        let today = Self.dayStamp(now())
        let raw = defaults.dictionary(forKey: Self.todayKeyPrefix + slug)
        if let raw, raw["day"] as? String == today, let secs = raw["seconds"] as? Int, secs > 0 {
            todayStamp = today
            todaySeconds = secs
        } else {
            todayStamp = today
            todaySeconds = 0
        }
    }
}

/// Payload für `POST /history/writing-time` — `{ book_id, seconds }`.
private struct WritingTimePing: Encodable {
    let bookId: Int
    let seconds: Int
    enum CodingKeys: String, CodingKey {
        case bookId = "book_id"
        case seconds
    }
}
