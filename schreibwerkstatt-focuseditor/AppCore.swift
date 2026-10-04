//
//  AppCore.swift
//  schreibwerkstatt-focuseditor
//
//  App-weiter Wurzel-Container: besitzt genau eine Instanz von AuthStore,
//  LocalStore und SyncEngine. Wichtig — der LocalStore ist app-weit (nicht
//  pro Fenster), damit Editor-Bridge und SyncEngine denselben Spiegel sehen.
//

import Foundation
import Combine
import os

@MainActor
final class AppCore: ObservableObject {
    let auth: AuthStore
    /// App-weiter Inhalts-Spiegel — GRDB/SQLite, mit In-Memory-Fallback falls
    /// die DB nicht geöffnet werden kann (App startet trotzdem).
    let store: any LocalStore
    /// App-weite WebView-Bridge — geteilt zwischen FocusWebView und SyncEngine
    /// (Open-Page-Reload, Block-Merge laufen über dieselbe Instanz).
    let bridge: EditorBridge
    let sync: SyncEngine
    /// Lese-Zugriff auf Buch-/Seiten-Struktur (Buch- + Seitenauswahl).
    let content: ContentAPI
    /// Buch-/Seitenauswahl-Zustand (aktives Buch persistiert, treibt den Picker).
    let library: LibraryStore
    /// OTA-Bundle des Focus-Editors (lädt/cacht die Editor-Assets vom Server).
    let editorBundle: EditorBundleStore
    /// OTA-Override der Oberflächen-Strings (macclient.*); gebündelte Kataloge
    /// bleiben der Offline-Fallback.
    let i18n: I18nBundleStore
    /// Misst die im Editor verbrachte Zeit und meldet sie an den Server
    /// (`POST /history/writing-time`) — das native Pendant zum Schreibzeit-
    /// Heartbeat der Web-Plattform. Scene-Phase über `setActive(_:)`.
    let writingTime: WritingTimeTracker
    /// Serverseitiges Seiten-Lektorat (`POST /jobs/check` + Poll) — Start über
    /// den Toolbar-Knopf, Ergebnis als Banner über der Schreibfläche.
    let lektorat: LektoratJobStore
    /// Konto-Löschung aus der App (`DELETE /me/account`, Guideline 5.1.1(v)) —
    /// räumt nach bestätigter Server-Löschung auch lokal auf.
    let accountDeletion: AccountDeletionController
    /// Buch-Export als Markdown (Ablage ▸ „Buch exportieren …") aus dem lokalen
    /// Spiegel — funktioniert offline.
    let bookExport: BookExportController
    /// Seiten anlegen/umbenennen/löschen (`POST`/`PUT`/`DELETE /content/pages`).
    /// Online-Pfad: eine Seite entsteht am Server, damit sie eine echte ID hat.
    let pageAdmin: PageAdminController
    /// Frühere Fassungen der offenen Seite (`GET/POST …/revisions`) — der
    /// Notausgang, wenn ⌘⇧Z nicht mehr greift.
    let revisions: PageRevisionStore

    /// Server-Namespace, auf den die Stores aktuell zeigen. Erkennt einen Wechsel
    /// (Settings ODER URL-Edit im Login) gegen `ServerNamespace.currentSlug`.
    /// `internal` statt `private`, weil der Namespace-Wechsel in
    /// AppCore+ServerSwitch.swift liegt (Swift kennt kein `private` über
    /// Dateigrenzen hinweg — auch nicht für Extensions desselben Typs).
    var boundSlug: String
    /// Reentrancy-Schutz: der Sign-in-Status-Publisher kann mehrfach feuern
    /// (Start-mit-Token UND Login) → einen laufenden Wechsel nicht doppelt fahren.
    var switchInFlight = false

    init() {
        self.boundSlug = ServerNamespace.currentSlug
        let auth = AuthStore()
        let store: any LocalStore
        do {
            store = try GRDBLocalStore()
        } catch {
            // DB-Öffnen fehlgeschlagen → In-Memory-Fallback. Lokale, noch nicht
            // gepushte Inhalte sind dann flüchtig; der Sync re-hydratisiert aus
            // dem Server. Kein Crash beim Start.
            AppLog.store
                .error("GRDB-Store nicht öffenbar, In-Memory-Fallback: \(error.localizedDescription, privacy: .public)")
            store = InMemoryLocalStore()
        }
        let bridge = EditorBridge(store: store, api: auth.api)
        let content = ContentAPI(api: auth.api)
        self.auth = auth
        self.store = store
        self.bridge = bridge
        self.content = content
        let library = LibraryStore(content: content, store: store, bridge: bridge)
        self.library = library
        self.editorBundle = EditorBundleStore(api: auth.api)
        self.i18n = I18nBundleStore(api: auth.api)
        let writingTime = WritingTimeTracker(api: auth.api,
                                             isSignedIn: { auth.state == .signedIn })
        self.writingTime = writingTime
        writingTime.attach(to: library)
        // Tippaktivität der WebView (eigener Hook neben `onStats`) speist die
        // Idle-Erkennung der Schreibzeit — pausiert bei längerer Tipp-Pause.
        bridge.onActivity = { [weak writingTime] in writingTime?.notifyActivity() }
        // Ergebnis eines lokalen Saves → Warn-Banner (Fehler) bzw. dessen Auflösung
        // (Erfolg). Ein fehlgeschlagener Save ist ein echter Datenverlust-Pfad und
        // darf nicht nur im Log stehen.
        bridge.onSaveResult = { [weak library] message in library?.reportSaveResult(message) }
        // Widerrufen/Wiederherstellen im Editor sichtbar machen (⌘Z fasst in
        // WebKit eine ganze Tippstrecke zu EINEM Schritt zusammen).
        bridge.onHistoryEdit = { [weak library] isUndo, chars in
            library?.reportHistoryEdit(undo: isUndo, chars: chars)
        }
        let sync = SyncEngine(api: auth.api,
                              content: content,
                              store: store,
                              shouldSync: { auth.state == .signedIn })
        sync.editor = bridge   // SyncEngine ↔ Editor-Kopplung (schwach gehalten)
        self.sync = sync
        // Offline-Boot-Lücke: startete die App ohne erreichbaren Server, lief
        // `spellcheckConfig` beim Boot leer zurück → der Spellcheck-Controller
        // wurde nie mounted. Sobald der Server im Sync-Tick antwortet, gibt
        // die Bridge der WebView die Chance, die Initialisierung idempotent
        // nachzuholen (`bridge.pushDeferredSpellcheckInit`).
        sync.onServerReached = { [weak bridge] in
            guard let bridge else { return }
            Task { await bridge.pushDeferredSpellcheckInit() }
        }
        // Beim Öffnen einer Seite gezielt deren frischen Server-Stand ziehen
        // („sicherheitshalber"), statt aufs Poll-Intervall zu warten. Best-effort
        // und still; respektiert den Datenverlust-Schutz (dirty/Outbox bleibt).
        bridge.onPageOpened = { [weak sync] pid in
            Task { await sync?.pullPage(pageId: pid) }
        }
        // Sync-Basis setzen, wenn `fetchAndMirror` eine Seite vom Server holt.
        // Verhindert den Deadlock: Seite im Store (via fetchAndMirror) + Outbox-
        // Eintrag → Pull überspringt → Basis würde nie gesetzt → Push überspringt
        // ewig. Nur wirksam, wenn noch keine Basis existiert (idempotent).
        // Das serverHtml wird direkt übergeben (nicht aus dem Store gelesen),
        // weil bei `applied == false` der Store das lokale HTML hält.
        bridge.onSetSyncBase = { [weak sync] pageId, serverUpdatedAt, serverHtml in
            await sync?.setSyncBase(pageId: pageId, serverUpdatedAt: serverUpdatedAt, html: serverHtml)
        }
        // Lektorats-Job: der Server prüft den SERVER-Stand der Seite → vor dem
        // Anlegen den offenen Draft sichern (Bridge) und pushen (Sync), sonst
        // lektoriert er einen veralteten Text. Genau die ⌘S-Semantik, nur
        // awaitbar — darum hier verdrahtet statt `syncManually()`.
        self.lektorat = LektoratJobStore(api: auth.api) { [weak bridge, weak sync] in
            await bridge?.flushDraftSave()
            await sync?.syncNow(manual: true)
        }
        // Buch-Export: der Server exportiert seinen Stand → derselbe Vorlauf.
        self.bookExport = BookExportController(api: auth.api, store: store, library: library) { [weak bridge, weak sync] in
            await bridge?.flushDraftSave()
            await sync?.syncNow(manual: true)
        }
        self.pageAdmin = PageAdminController(api: auth.api, store: store, library: library)
        self.revisions = PageRevisionStore(api: auth.api)
        self.accountDeletion = AccountDeletionController(api: auth.api)
        // Erst NACH bestätigter Server-Löschung lokal aufräumen: Spiegel/Sync-
        // Zustand dieses Servers verwerfen, dann abmelden (→ Login-Screen).
        // Reihenfolge zählt — `signOut()` zuerst würde die UI umschalten, während
        // der Store noch auf die gelöschten Dateien zeigt.
        self.accountDeletion.onDeleted = { [weak self] in
            guard let self else { return }
            await self.purgeLocalDataForCurrentServer()
            self.auth.signOut()
        }
    }

    /// Beim App-Start: Token prüfen, dann Sync hochfahren.
    func bootstrap() async {
        await auth.bootstrap()
        sync.start()
        // String-Override still im Hintergrund ziehen (greift beim nächsten
        // Start; gebündelte Kataloge bleiben der Offline-Fallback).
        Task { await i18n.refresh() }
    }
}
