//
//  SyncEngine.swift
//  schreibwerkstatt-focuseditor
//
//  Sync-Engine auf dem Auth-`APIClient`. Getrieben durch die Scene-Phase:
//  Solange das Fenster aktiv ist, wird periodisch (~5 s) gepollt; im
//  Hintergrund pausiert der Loop (Energie), beim Reaktivieren gibt es sofort
//  einen Tick. Zusätzlicher Trigger: Reachability (Netz wieder da → Tick).
//   • Push: drainiert die Outbox des LocalStore → `PUT /content/pages/:id`
//     mit `expected_updated_at` (exakte Server-ISO-Basis). 200 → Basis
//     vorrücken; 409 → Konflikt erfassen (Block-Merge folgt, kein
//     Last-Write-Wins); 404/423 → defensiv überspringen.
//   • Pull: je Buch `GET /content/books/:id/sync` mit Keyset-Cursor, bis
//     `has_more=false`. Server-Seiten landen im Store — ABER niemals über
//     lokal ungepushte Änderungen (die löst der Push/Merge auf).
//
//  Datenverlust-Schutz (CLAUDE.md): Es wird nie automatisch verworfen oder
//  ohne Merge überschrieben. Bei Auth-Fehlern (401) beendet der APIClient die
//  Session; lokale Inhalte bleiben.
//
//  Aufteilung: Der Push-Pfad liegt in SyncEngine+Push.swift, der Pull- und
//  Delete-Reconcile-Pfad in SyncEngine+Pull.swift. Diese Datei hält Typen,
//  State, Lifecycle/Polling, den Durchlauf (`syncNow`) und die Konflikt-UI.
//

import Foundation
import Combine
import OSLog

@MainActor
final class SyncEngine: ObservableObject {

    enum Status: Equatable {
        case idle               // bereit, nichts zu tun
        case syncing            // Push/Pull läuft
        case offline            // kein Netz (Reachability-Pfad nicht erreichbar)
        case serverUnreachable  // Netz da, aber der Server antwortet nicht
                                // (Verbindung abgelehnt/Timeout) — Server gekappt o. Ä.
    }

    /// Ein erfasster, noch nicht aufgelöster Server-Konflikt (409).
    struct Conflict: Identifiable, Equatable {
        var id: String { pageId }
        let pageId: String
        /// Anzeigename der Seite (für die Konflikt-UI) — lokaler `pageName`/Titel.
        let pageName: String?
        let serverUpdatedAt: String?
        let serverEditorName: String?
    }

    /// Seiten-ID der UI-Platzhalter-Seite („Neue Seite", Boot-Fallback bei
    /// leerem/ungesynctem Buch). Kein echter Datensatz — wird nie gepusht und
    /// beim Push-Tick getilgt, falls sie aus einem früheren Build zurückblieb.
    /// Muss mit dem Boot-Fallback in WebAssets.indexHTML übereinstimmen.
    static let placeholderPageId = "default"

    @Published private(set) var status: Status = .idle
    @Published private(set) var lastSyncedAt: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var conflicts: [Conflict] = []
    /// Anzahl lokal noch nicht gepushter Seiten (Outbox) — für die Status-UI.
    @Published private(set) var pendingCount: Int = 0
    /// Netzlage, gespiegelt aus dem `Reachability`-Monitor. Die UI hängt an der
    /// SyncEngine (nicht am Monitor selbst) — sonst bräuchte jede Ansicht, die
    /// nur „ist Netz da" wissen will, ein zweites ObservableObject. Bekannt
    /// flaky bei VPN/Captive-Portal, darum nur für HINWEISE benutzen, nie um
    /// eine Aktion zu sperren (der echte Request klärt es ohnehin).
    @Published private(set) var isOnline: Bool = false

    /// Poll-Kadenz (persistiert). Änderung startet den Loop passend neu.
    @Published var pollMode: SyncPollMode {
        didSet {
            guard pollMode != oldValue else { return }
            UserDefaults.standard.set(pollMode.rawValue, forKey: SyncPollMode.storageKey)
            restartPolling()
        }
    }

    /// Transientes Pausieren des Auto-Polls (nur diese Sitzung). Manueller Sync
    /// bleibt möglich; Pushes gehen so beim nächsten manuellen Tick raus.
    @Published var isPaused: Bool = false {
        didSet {
            guard isPaused != oldValue else { return }
            restartPolling()
        }
    }

    // Hinweis: Mehrere Member sind `internal` (kein `private`), weil der Push- und
    // der Pull-Pfad in eigene Dateien ausgelagert sind (SyncEngine+Push.swift,
    // SyncEngine+Pull.swift). `private` ist in Swift dateiweit — diese Extensions
    // brauchen Zugriff auf den geteilten Engine-State. Single-Module: nichts
    // außerhalb referenziert SyncEngine, die Kapselung bleibt praktisch erhalten.
    let api: APIClient
    let content: ContentAPI
    let store: any LocalStore
    private let reachability: Reachability
    let stateStore: SyncStateStore
    /// Editor-Kopplung (Open-Page-Reload, Block-Merge). Schwach: AppCore besitzt
    /// die Bridge. `nil` solange keine WebView läuft → Merge fällt auf Konflikt zurück.
    weak var editor: EditorCoordinating?
    /// Liefert, ob synchronisiert werden darf (z. B. nur bei `signedIn`).
    private let shouldSync: () -> Bool
    let log = AppLog.sync

    /// Signal „Server in dieser Sitzung erreicht" — feuert am Ende JEDES
    /// erfolgreichen `syncNow`-Durchlaufs (jede HTTP-Antwort, egal welcher
    /// Status, beweist schon Erreichbarkeit). Treibt das verzögerte Nachziehen
    /// der LanguageTool-Initialisierung (Boot war offline → Spellcheck nie
    /// mounted; nachfolgende Konnektivität holt das nach). Bewusst einschüssig
    /// pro Tick ohne eigenes Flag: die Empfänger (`AppCore` →
    /// `bridge.pushDeferredSpellcheckInit`) sind idempotent (JS-Guard
    /// `if (window.__spellcheck) return`; Swift-Flag `spellcheckDeferredDone`
    /// verhindert Retry-Spam).
    var onServerReached: (@MainActor () -> Void)?

    /// Aktive Poll-Periode aus dem gewählten Modus (`nil` = manuell, kein Loop).
    private var pollInterval: Duration? { isPaused ? nil : pollMode.interval }
    /// Soll der Auto-Poll laufen? (Aktives Fenster + Modus ≠ manuell + nicht pausiert.)
    private var autoPollEnabled: Bool { isActive && !isPaused && pollMode.interval != nil }
    /// Delete-Reconcile ist teurer (ein Tree-Fetch je Buch) → seltener als der
    /// Poll. Mindestabstand zwischen zwei Reconcile-Durchläufen.
    let reconcileInterval: TimeInterval = 60
    var lastReconcileAt: Date?
    /// Die Bücherliste wird (anders als früher) nicht nur einmal gebootstrappt,
    /// sondern gedrosselt aufgefrischt — sonst würden in der Web-App neu
    /// angelegte Bücher nie gepullt. Gleiche Kadenz wie der Reconcile.
    let booksRefreshInterval: TimeInterval = 60
    var lastBooksRefreshAt: Date?
    /// Serverseitig gesperrte Seiten (423 PAGE_LOCKED): nicht bei jedem Tick
    /// erneut pushen, sondern bis zum Ablauf der Sperrfrist überspringen
    /// (vermeidet Dauer-PUTs + Log-Spam bei langem Lektorats-Lock).
    let lockBackoff: TimeInterval = 60
    var lockedUntil: [String: Date] = [:]
    /// Wie oft ein Auto-Merge in Folge erneut am 409-Rennen scheitern darf, bevor
    /// die Seite als SICHTBARER Konflikt erfasst wird (statt jeden Tick einen
    /// vollen Merge-Roundtrip zu fahren, der nie konvergiert → Live-Lock-Schutz).
    let maxAutoMergeRetries = 3
    var autoMergeRe409: [String: Int] = [:]

    private var isRunning = false
    private var isActive = false
    private var pollTask: Task<Void, Never>?
    /// Wurde der Server im laufenden Sync-Durchlauf (transport-seitig) erreicht?
    /// Jede HTTP-Antwort (auch 4xx/5xx/401) zählt als erreichbar, nur ein echter
    /// Transport-Fehler (`AuthError.network`: Verbindung abgelehnt/Timeout/TLS)
    /// lässt das Flag false — daraus leitet `syncNow()` `.serverUnreachable` ab,
    /// unterscheidet also „Server weg" von „kein Netz" (`.offline`).
    private var serverReachedThisRun = false

    init(api: APIClient,
         content: ContentAPI,
         store: any LocalStore,
         reachability: Reachability? = nil,
         shouldSync: @escaping () -> Bool) {
        self.api = api
        self.content = content
        self.store = store
        self.reachability = reachability ?? Reachability()
        self.shouldSync = shouldSync
        self.stateStore = SyncStateStore()
        self.pollMode = SyncPollMode.current
        // Offene Konflikte aus dem persistierten Zustand wiederherstellen —
        // ein Neustart darf die Konflikt-Markierung nicht verlieren (sonst würde
        // die Seite blind neu gepusht und liefe wieder ins 409).
        restoreConflicts()
    }

    // MARK: - Lifecycle

    /// Startet die Reachability-Beobachtung. Das Polling selbst hängt an der
    /// Scene-Phase und wird über `setActive(_:)` ein-/ausgeschaltet.
    func start() {
        reachability.onChange = { [weak self] online in
            guard let self else { return }
            self.isOnline = online
            if online {
                // Netz wieder da: noch NICHT blind auf `.idle` — ob der Server
                // antwortet, klärt erst der folgende Tick (sonst „grün", obwohl
                // der Server weg ist). Mit Auto-Poll sofort ein Tick; sonst den
                // bisherigen Stand halten (der nächste manuelle Sync prüft).
                if self.autoPollEnabled { self.requestSync() }
            } else {
                self.status = .offline
            }
        }
        reachability.start()
        isOnline = reachability.isOnline
        Task { await migrateLegacyAncestors() }
    }

    /// Einmal-Migration: schiebt die Merge-Ancestor aus dem alten
    /// `SyncState.serverBaseHtml`-Dictionary in die Store-Spalte
    /// `page.serverBaseHtml` und leert das Alt-Feld.
    ///
    /// Warum überhaupt migrieren statt einfach zu verwerfen: ohne Ancestor kann ein
    /// 409 nur noch in der Konflikt-UI landen statt still zu mergen. Die Werte sind
    /// da — sie einmal umzuziehen kostet einen Durchlauf, sie wegzuwerfen kostet den
    /// Nutzer bei jedem Parallel-Edit ein Modal.
    ///
    /// Der abschliessende `mutate` leert das Feld; weil `encode(to:)` es nicht mehr
    /// schreibt, schrumpft der Snapshot damit dauerhaft (gemessen 20 MB → ~0,7 MB).
    func migrateLegacyAncestors() async {
        let legacy = stateStore.state.legacyServerBaseHtml
        guard !legacy.isEmpty else { return }
        log.notice("Migriere \(legacy.count, privacy: .public) Merge-Ancestor aus dem SyncState-Snapshot in den Store")
        for (pid, html) in legacy {
            // Best-effort: eine inzwischen gelöschte Seite ist ein No-op (der
            // Ancestor hängt an der Zeile), ein Schreibfehler kostet nur den
            // stillen Auto-Merge dieser einen Seite.
            try? await store.setServerBaseHtml(html, id: pid)
        }
        stateStore.mutate { $0.legacyServerBaseHtml = [:] }
        log.info("Merge-Ancestor-Migration abgeschlossen — Snapshot ohne HTML-Ballast")
    }

    func stop() {
        stopPolling()
        reachability.stop()
    }

    /// Hält den Sync VOR einem Server-Wechsel an: stoppt den Poll-Loop und wartet
    /// (gedeckelt) auf das Ende eines laufenden Durchlaufs. Ohne das könnte ein
    /// in-flight DB-Write (`await store.…` ist suspendiert) noch in die ALTE
    /// Namespace-DB committen, während `GRDBLocalStore` bereits auf die neue
    /// getauscht hat → der Write fiele für den neuen Server lautlos weg.
    /// Der Aufrufer (AppCore.switchServer) ruft danach `reloadForCurrentServer()`.
    func suspendForServerSwitch() async {
        stopPolling()
        var waited = 0
        while isRunning && waited < 100 {        // max. ~2 s
            try? await Task.sleep(for: .milliseconds(20))
            waited += 1
        }
    }

    /// Server-Wechsel: den persistenten Sync-Zustand (Buch-IDs/Cursor/Basen) auf
    /// den Namespace des aktuellen Servers umladen und alle transienten Spuren des
    /// alten Servers verwerfen. Ohne das würde der Loop weiter die Buch-IDs des
    /// alten Servers pollen (→ `NO_BOOK_ACCESS` am neuen Server). Den Poll-Loop
    /// danach passend neu aufsetzen.
    func reloadForCurrentServer() {
        stopPolling()
        stateStore.reloadForCurrentServer()
        // Der Snapshot des Zielservers kann noch Alt-Ancestor tragen.
        Task { await migrateLegacyAncestors() }
        // Konflikte des NEUEN Servers aus dessen persistiertem Zustand laden
        // (nicht blind leeren — ein offener Konflikt am Zielserver bleibt sichtbar).
        restoreConflicts()
        pendingCount = 0
        lastReconcileAt = nil
        // Bücherliste beim nächsten Tick zwingend neu (autoritativ) ziehen, damit
        // evtl. aus dem alten Server migrierte/fremde Buch-IDs sofort gekürzt
        // werden — nicht erst nach Ablauf des Refresh-Intervalls.
        lastBooksRefreshAt = nil
        // Lektorats-Sperren + Auto-Merge-Re-Zähler des alten Servers verwerfen.
        lockedUntil = [:]
        autoMergeRe409 = [:]
        lastError = nil
        status = .idle
        if isActive {
            if autoPollEnabled { requestSync() }
            startPolling()
        }
    }

    /// Vom Scene-Phasen-Wechsel getrieben: aktiv → sofortiger Tick + 5 s-Poll;
    /// inaktiv/Hintergrund → Poll pausieren (CLAUDE.md: nur solange Fenster aktiv).
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active {
            if autoPollEnabled { requestSync() }   // sofortiger Tick beim Reaktivieren
            startPolling()
        } else {
            stopPolling()
        }
    }

    /// Stößt einen Sync-Durchlauf an (Scene-aktiv, Online-Wechsel, lokaler Save).
    func requestSync() {
        Task { await syncNow() }
    }

    /// Manueller Sync-Auslöser (Menü/Toolbar/Settings) — wirkt auch bei
    /// pausiertem oder manuellem Modus UND wenn der Reachability-Monitor
    /// (`NWPathMonitor`) fälschlich „offline" meldet (bekannt flaky bei VPN/
    /// Captive-Portal): der echte Request klärt die Erreichbarkeit ohnehin, der
    /// Nutzer darf den einzigen Ausweg bei hängendem Sync nicht verlieren.
    func syncManually() {
        // Erst den offenen Draft sofort sichern (der Editor-Autosave läuft
        // entprellt → ein frischer Tastenanschlag liegt evtl. noch nicht im
        // LocalStore), DANN pushen/pullen. So speichert ⌘S (und der Toolbar-/
        // Settings-Knopf) wirklich UND synchronisiert — kein Verlust des
        // jüngsten Tippstands. Nur der manuelle Pfad flusht; der Auto-Poll
        // überlässt das Persistieren bewusst dem Editor-Autosave.
        Task {
            await editor?.flushDraftSave()
            await syncNow(manual: true)
        }
    }

    /// Setzt die Sync-Basis (ISO + Merge-Ancestor) für eine Seite, die bereits
    /// im LocalStore liegt, aber noch keine Basis hat. Notwendig, wenn die Seite
    /// über `fetchAndMirror` (Bridge-Nachladen) in den Store kam — dieser Pfad
    /// schreibt den Inhalt, aber setzte früher keine Basis. Ohne Basis würde der
    /// Push die Seite ewig überspringen ("keine Server-Basis, noch nicht gepullt"),
    /// während der Pull sie ebenfalls überspringt (Outbox-Eintrag vorhanden) —
    /// ein Deadlock.
    ///
    /// Nur wirksam, wenn die Seite noch KEINE Basis hat (idempotent: setzt keine
    /// vorhandene Basis zurück). Wird von `EditorBridge.onSetSyncBase` aufgerufen.
    func setSyncBase(pageId: String, serverUpdatedAt: String, html: String) async {
        guard stateStore.state.serverBaseISO[pageId] == nil else { return }
        try? await store.setServerBaseHtml(html, id: pageId)
        stateStore.mutate { $0.serverBaseISO[pageId] = serverUpdatedAt }
        log.info("Sync-Basis nachgesetzt (fetchAndMirror): \(pageId, privacy: .public)")
    }

    /// Gezielter Einzelseiten-Pull beim ÖFFNEN einer Seite („sicherheitshalber"):
    /// holt sofort den frischen Server-Stand genau dieser Seite, statt aufs
    /// Poll-Intervall (~5 s) zu warten — und unabhängig von Pause/manuellem Modus
    /// (Frische beim Öffnen ist eine bewusste Nutzeraktion). Gleiche Guards wie
    /// `pullBook`: eine lokal ungepushte Änderung (Outbox ODER dirty offene Seite)
    /// wird NIE überschrieben (Datenverlust-Schutz), das Echo des eigenen Edits
    /// (gleiche Basis) wird übersprungen (kein Flackern). Best-effort und still:
    /// kein Status-Spinner; offline/404/Transport-Fehler werden nur geloggt
    /// (der reguläre Poll holt die Seite ohnehin nach).
    func pullPage(pageId pid: String) async {
        // `isRunning` mit `syncNow` teilen: ein Einzel-Pull und ein Poll-Tick dürfen
        // nicht gleichzeitig denselben `stateStore`/Store mutieren (Read-modify-write
        // über `await` hinweg → Basis-Race). Läuft schon ein Durchlauf, überspringen —
        // der laufende Pull erfasst die Seite ohnehin.
        guard shouldSync(), reachability.isOnline, !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        // Lokal ungepushte Änderung → nicht anfassen; die Divergenz löst der
        // nächste Push per 409/Block-Merge auf.
        let pending = (try? await store.pendingOutbox().map(\.pageId)) ?? []
        let isDirtyOpen = (editor?.openPageId == pid) && (editor?.isDirty(pid) ?? false)
        if pending.contains(pid) || isDirtyOpen { return }

        // pid kommt aus der (nicht vertrauenswürdigen) WebView → für den URL-Pfad
        // kodieren (sonst könnten `/`, `?`, `#`, `..` den Pfad verbiegen).
        guard let encodedId = pid.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return }
        let resp: PushResponse
        do {
            resp = try await reachableSend {
                try await api.send("/content/pages/\(encodedId)", method: .GET, decode: PushResponse.self)
            }
        } catch {
            // offline/404/Transport → still degradieren; der reguläre Poll erfasst
            // die Seite. 401 beendet die Session ohnehin im APIClient.
            log.info("Einzel-Pull \(pid, privacy: .public) übersprungen: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard let html = resp.html else { return }

        // Echo: gleiche Basis = kein neuer Inhalt → nicht erneut mergen/neu laden.
        let serverUpdatedAt = resp.updated_at
        if stateStore.state.serverBaseISO[pid] == serverUpdatedAt { return }

        // Unparsbarer Stempel → überspringen statt Epoch 0 zu schreiben.
        guard let ms = ISOTime.millis(serverUpdatedAt) else {
            log.notice("Einzel-Pull übersprungen (updated_at unparsbar): \(pid, privacy: .public)")
            return
        }

        // Re-Check direkt vor dem Write: das GET oben hat suspendiert, der Nutzer
        // kann in genau diese (eben geöffnete) Seite getippt haben. Outbox-Check
        // läuft atomar im Store, die Dirty-offene-Seite zusätzlich hier.
        if (editor?.openPageId == pid) && (editor?.isDirty(pid) ?? false) { return }
        // bookId/chapterId liefert `GET /content/pages/:id` ggf. nicht — nil lässt
        // den vorhandenen Wert stehen (keine Waise), der Reconcile-Backfill trägt es
        // sonst über den Buch-Tree nach.
        let applied = (try? await store.applyServerPageIfClean(id: pid, html: html,
                                                               pageName: resp.name,
                                                               bookId: resp.book_id, chapterId: resp.chapter_id,
                                                               serverUpdatedAtMillis: ms)) ?? false
        guard applied else { return }
        // ISO als Push-Basis + HTML als Merge-Ancestor mitführen (wie `pullBook`).
        try? await store.setServerBaseHtml(html, id: pid)
        stateStore.mutate { $0.serverBaseISO[pid] = serverUpdatedAt }
        // Ist die Seite (weiterhin) sauber offen, still in der WebView neu laden.
        if editor?.openPageId == pid {
            await editor?.reloadPage(pageId: pid, html: html, baseUpdatedAt: ms)
        }
    }

    /// Startet den Poll-Loop, sofern der Auto-Poll erlaubt ist; sonst No-op
    /// (manueller Modus/pausiert → kein automatischer Tick).
    private func startPolling() {
        pollTask?.cancel()
        pollTask = nil
        guard autoPollEnabled, let interval = pollInterval else { return }
        pollTask = Task { [weak self] in
            guard let self else { return }
            // Erster Tick kommt über requestSync(); der Loop ergänzt Folge-Ticks.
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                await self.syncNow()
            }
        }
    }

    /// Loop nach einer Modus-/Pause-Änderung neu aufsetzen (nur im aktiven Fenster).
    private func restartPolling() {
        guard isActive else { return }
        stopPolling()
        if autoPollEnabled { requestSync() }
        startPolling()
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Durchlauf

    func syncNow(manual: Bool = false) async {
        // Auto-Tick: nur bei aktivem Fenster + gemeldeter Erreichbarkeit. Manueller
        // Auslöser umgeht beide Gates (Reachability klärt der Request selbst), nur
        // `shouldSync()` (signedIn) und der Reentrancy-Schutz bleiben verbindlich.
        guard shouldSync(), !isRunning else { return }
        guard manual || (isActive && reachability.isOnline) else { return }
        isRunning = true
        status = .syncing
        serverReachedThisRun = false
        defer {
            isRunning = false
            // Status aus dem Lauf neu ableiten: kein Netz → offline; Netz da,
            // aber kein einziger Request hat den Server erreicht → serverUnreachable;
            // sonst idle. (Konflikte zeigt die UI unabhängig vom Status.)
            if !reachability.isOnline {
                status = .offline
            } else if !serverReachedThisRun {
                status = .serverUnreachable
            } else {
                status = .idle
            }
            // Server antwortet → Empfängerseitig idempotentes Hook feuern, das
            // ggf. den Spellcheck-Controller nachträglich mountet (Offline-Boot-
            // Lücke). Siehe `onServerReached`-Dokumentation oben.
            if serverReachedThisRun { onServerReached?() }
        }

        do {
            await repairStalledSyncBases()
            try await pushOutbox()
            try await pullDeltas()
            await reconcileDeletesIfDue()
            pendingCount = (try? await store.pendingOutbox().count) ?? pendingCount
            lastSyncedAt = Date()
            lastError = nil
        } catch AuthError.unauthorized {
            // Session beendet der APIClient bereits; hier nichts erzwingen.
            log.info("Sync abgebrochen: nicht autorisiert")
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            log.error("Sync-Fehler: \(self.lastError ?? "?", privacy: .public)")
        }
    }

    /// Führt einen Server-Aufruf aus und merkt sich für `serverReachedThisRun`,
    /// ob der Server antwortete. Jede HTTP-Antwort (Erfolg ODER 4xx/5xx/401)
    /// gilt als erreichbar; nur `AuthError.network` (Transport-Fehler) lässt das
    /// Flag unverändert. Der Fehler wird unverändert weitergereicht — die
    /// bestehende Fehlerbehandlung (409-Merge, 404/423-Skip, 401-Abbruch) bleibt.
    @discardableResult
    func reachableSend<T>(_ call: () async throws -> T) async throws -> T {
        do {
            let result = try await call()
            serverReachedThisRun = true
            return result
        } catch {
            if case AuthError.network = error {
                // Transport-Fehler → Server NICHT erreicht; Flag bleibt false.
            } else {
                serverReachedThisRun = true   // Server hat geantwortet (nur Status ≠ 2xx)
            }
            throw error
        }
    }

    // MARK: - Konflikte

    func recordConflict(pageId: String, serverUpdatedAt: String?, serverEditorName: String?) async {
        let stored = (try? await store.page(id: pageId)) ?? nil
        let c = Conflict(pageId: pageId,
                         pageName: stored?.pageName ?? stored?.title,
                         serverUpdatedAt: serverUpdatedAt,
                         serverEditorName: serverEditorName)
        if let idx = conflicts.firstIndex(where: { $0.pageId == pageId }) {
            conflicts[idx] = c
        } else {
            conflicts.append(c)
        }
        persistConflicts()
    }

    /// Markiert einen Konflikt als aufgelöst (nach erfolgreichem Block-Merge).
    /// Der nächste Push nimmt die Seite dann wieder mit.
    func clearConflict(pageId: String) {
        let before = conflicts.count
        conflicts.removeAll { $0.pageId == pageId }
        if conflicts.count != before { persistConflicts() }
    }

    /// Stellt die offenen Konflikte aus dem persistierten Sync-Zustand her
    /// (Boot + Server-Wechsel). Spiegelt `PersistedConflict` → `Conflict`.
    private func restoreConflicts() {
        conflicts = stateStore.state.conflicts.map {
            Conflict(pageId: $0.pageId, pageName: $0.pageName,
                     serverUpdatedAt: $0.serverUpdatedAt, serverEditorName: $0.serverEditorName)
        }
    }

    /// Schreibt die aktuelle Konfliktliste in den persistierten Sync-Zustand,
    /// sodass sie einen Neustart übersteht. `Conflict` → `PersistedConflict`.
    private func persistConflicts() {
        let dtos = conflicts.map {
            PersistedConflict(pageId: $0.pageId, pageName: $0.pageName,
                              serverUpdatedAt: $0.serverUpdatedAt, serverEditorName: $0.serverEditorName)
        }
        stateStore.mutate { $0.conflicts = dtos }
    }

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
            // Server-Stand übernehmen, lokale Änderung verwerfen.
            let serverHtml = serverPage.html ?? ""
            let ms = ISOTime.millis(serverPage.updated_at) ?? 0
            // Erst lokal übernehmen + Outbox droppen, DANN die Basis vorrücken.
            // Sonst bliebe bei einem fehlgeschlagenen Write der alte lokale Stand
            // mit bereits vorgerückter Basis zurück und käme über einen 409-Re-Merge
            // wieder hoch — obwohl der Nutzer „Server übernehmen" gewählt hat.
            do {
                try await store.applyServerPage(id: pid, html: serverHtml,
                                                pageName: nil, bookId: nil, chapterId: nil,
                                                serverUpdatedAtMillis: ms)
                // Outbox-Eintrag droppen (falls unverändert seit dem Lesen oben).
                if let entry {
                    try await store.markPushed(id: pid, queuedAt: entry.queuedAt, serverUpdatedAtMillis: ms)
                }
            } catch {
                lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                log.error("Konflikt-Auflösung \(pid, privacy: .public): Server-Stand lokal übernehmen fehlgeschlagen: \(self.lastError ?? "?", privacy: .public)")
                return
            }
            try? await store.setServerBaseHtml(serverHtml, id: pid)
            stateStore.mutate { $0.serverBaseISO[pid] = serverPage.updated_at }
            clearConflict(pageId: pid)
            lastError = nil
            // Offene Seite mit dem übernommenen Server-Stand neu laden (Nutzer hat
            // „Server übernehmen" gewählt → auch eine dirty Seite wird ersetzt).
            if editor?.openPageId == pid {
                await editor?.reloadPage(pageId: pid, html: serverHtml, baseUpdatedAt: ms)
            }
            log.info("Konflikt aufgelöst (Server-Stand übernommen): \(pid, privacy: .public)")
        }

        pendingCount = (try? await store.pendingOutbox().count) ?? pendingCount
    }
}
