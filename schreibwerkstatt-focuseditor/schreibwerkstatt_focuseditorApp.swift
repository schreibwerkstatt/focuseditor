//
//  schreibwerkstatt_focuseditorApp.swift
//  schreibwerkstatt-focuseditor
//
//  Created by David Berger on 14.06.2026.
//

import SwiftUI
import AppKit
import WebKit

@main
struct schreibwerkstatt_focuseditorApp: App {
    init() {
        // Native Fenster-Tabs komplett abschalten — und zwar VOR der ersten
        // Fenstererzeugung. Spät gesetzt (im WindowChromeController, nach
        // Fensteraufbau) installiert AppKit den „Tab-Leiste einblenden"-
        // Menüpunkt und das automatische Tabbing bereits → Tabs tauchen wieder
        // auf. Im App-`init` greift es früh genug, damit die View-Menüpunkte
        // („Tab-Leiste einblenden", „Alle Tabs zeigen", „Fenster zusammenführen")
        // gar nicht erst erscheinen. Ablenkungsfreies Schreiben auf genau einer
        // Seite (CLAUDE.md) verträgt keine Tab-Leiste.
        NSWindow.allowsAutomaticWindowTabbing = false

        // Tooltip-Verzögerung verkürzen. Die SwiftUI-`.help(…)`-Tooltips hängen am
        // AppKit-`toolTip`-Mechanismus, dessen initiale Verzögerung system-weit bei
        // ~2–3 s liegt — in der schmalen Toolbar fühlt sich das träge an. Der
        // (private, aber seit Jahren stabile) Default `NSInitialToolTipDelay` steuert
        // die Verzögerung in Millisekunden; früh im App-`init` registriert greift er,
        // bevor der erste Tooltip aufgebaut wird. `register` statt `set`, damit eine
        // explizite Nutzer-/System-Einstellung Vorrang behält.
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 400])

        // macOS „intelligente Anführungszeichen" in der editierbaren WKWebView
        // abschalten. Die Anführungszeichen sind Sache des gebündelten
        // Buch-Stil-Normalizers (quote-normalize.js, de-CH «» / de-DE „" / fr « »).
        // Läuft die OS-Ersetzung parallel, transformieren zwei Schichten dieselben
        // Zeichen: die System-Ersetzung schiebt (locale-abhängig) Innen-Spaces in
        // die Guillemets, und wo beide am selben Quote greifen, entstehen doppelte
        // Zeichen. WebKit liest diesen App-Domain-Default für editierbare Inhalte;
        // `register` statt `set`, konsistent mit dem Tooltip-Default oben. Nur die
        // Quote-Ersetzung — Bindestrich-/Text-Ersetzung + Rechtschreibung bleiben,
        // da der Normalizer sie nicht abdeckt (Bindestriche liefert nur die OS).
        UserDefaults.standard.register(defaults: ["WebAutomaticQuoteSubstitutionEnabled": false])
    }

    /// Szenen-ID des Hauptfensters — geteilt zwischen `Window`-Szene und dem
    /// Fenster-Menü-Eintrag, der es nach dem Schliessen wieder öffnet.
    static let mainWindowID = "main"
    /// Szenen-ID der Tastaturkürzel-Hilfe (Help-Menü **und** Fenster-Menü).
    static let shortcutsWindowID = "shortcuts-help"

    /// Fängt ⌘Q ab und sichert den offenen Draft, bevor der Prozess geht
    /// (der Autosave läuft entprellt — s. AppTerminationGuard.swift).
    @NSApplicationDelegateAdaptor(AppTerminationGuard.self) private var terminationGuard

    @StateObject private var core = AppCore()
    @StateObject private var windowChrome = WindowChromeController()
    @StateObject private var appearance = AppearanceController()
    @StateObject private var focus = FocusController()
    @StateObject private var typography = TypographyController()
    @StateObject private var writingStats = WritingStatsStore()
    @StateObject private var loc = LocalizationController()
    // Sparkle nur im DMG-Target — im App-Store-Build (kein `SPARKLE`) übernimmt
    // der Store die Updates, s. Update/UpdaterController.swift.
    #if SPARKLE
    @StateObject private var updater = UpdaterController()
    #endif
    /// Geteilter UI-Zustand zwischen Editor-Host und der im Titelleisten-Accessory
    /// gehosteten Toolbar (Seiten-Picker + Konflikt-Sheet).
    @StateObject private var toolbarUI = ToolbarUIState()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow

    /// Baut die SwiftUI-`AppToolbar` als AppKit-`NSView` für das Titelleisten-
    /// Accessory. Die App-`@StateObject`s sind hier direkt greifbar und werden
    /// dem isolierten Hosting-Baum als Environment mitgegeben — über die
    /// SwiftUI↔AppKit-Grenze fließen sie sonst NICHT (anders als im normalen
    /// View-Baum der WindowGroup). `windowChrome` braucht die Toolbar nicht mehr.
    @MainActor
    private func makeToolbarHost() -> NSView {
        let root = AppToolbar()
            .environmentObject(core.auth)
            .environmentObject(core.sync)
            .environmentObject(core.library)
            .environmentObject(appearance)
            .environmentObject(focus)
            .environmentObject(writingStats)
            .environmentObject(core.writingTime)
            .environmentObject(core.lektorat)
            .environmentObject(toolbarUI)
            .environmentObject(loc)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 50)   // Höhe = AppToolbar.frame(height:)
        host.autoresizingMask = [.width]
        return host
    }

    var body: some Scene {
        // Bewusst `Window` statt `WindowGroup`: die App ist eine Ein-Fenster-
        // Schreib-Shell (kein Dokumentmodell, „Neues Fenster" ist ersatzlos
        // gestrichen). Ein `WindowGroup` ohne `.newItem`-Befehl liess sich
        // schliessen, ohne dass es einen Weg zurück gab — App-Review-Befund
        // (Guideline 4, „no menu item to re-open it"). Eine `Window`-Szene
        // hängt dagegen einen festen Eintrag ins Fenster-Menü, der das Fenster
        // auch nach dem Schliessen wieder öffnet (s. `MainWindowCommands` für
        // den zusätzlichen expliziten Eintrag samt ⌘0).
        Window(t("window.mainTitle"), id: Self.mainWindowID) {
            ContentView()
                .environmentObject(core)
                .environmentObject(core.auth)
                .environmentObject(core.sync)
                .environmentObject(core.library)
                .environmentObject(core.editorBundle)
                .environmentObject(core.lektorat)
                .environmentObject(core.bookExport)
                .environmentObject(core.pageAdmin)
                .environmentObject(core.revisions)
                .environmentObject(windowChrome)
                .environmentObject(appearance)
                .environmentObject(focus)
                .environmentObject(typography)
                .environmentObject(writingStats)
                .environmentObject(loc)
                .environmentObject(toolbarUI)
                .background(WindowAccessor { window in
                    windowChrome.bind(window, toolbarHost: makeToolbarHost())
                })
                .task {
                    // Schliesst der Nutzer das Fenster (Ampel-Knopf), stirbt die
                    // WKWebView mit — den offenen Draft vorher local-first sichern
                    // (best effort: der Flush läuft über die Bridge in LocalStore +
                    // Outbox). Der Weg zurück ist „Fenster ▸ Schreibfenster" (⌘0).
                    windowChrome.onWillClose = { [core] in
                        Task { await core.bridge.flushDraftSave() }
                    }
                    // ⌘Q: dasselbe local-first, aber AWAITBAR — AppKit hält das
                    // Beenden dafür an (`.terminateLater`), sonst verlöre der
                    // letzte Tastenanschlag gegen den entprellten Autosave.
                    terminationGuard.flushBeforeQuit = { [core] in
                        await core.bridge.flushDraftSave(timeout: EditorBridge.quitFlushTimeout)
                    }
                    // Fokus- + Typografie-Controller an die app-weite Bridge
                    // koppeln (Push der Live-Umschaltung), Stats-Kanal anhängen,
                    // dann Auth/Sync hochfahren.
                    focus.bind(core.bridge)
                    typography.bind(core.bridge)
                    loc.bind(core.bridge)
                    writingStats.attach(to: core.bridge)
                    await core.bootstrap()
                }
                // Nach dem Anmelden den Server-Default der Fokus-Stufe ziehen
                // (solange lokal nichts gewählt ist). `onReceive` abonniert den
                // Publisher direkt → greift zuverlässig bei Start-mit-Token UND
                // frischem Login (der `/config`-Request braucht das Token).
                .onReceive(core.auth.$state) { state in
                    if state == .signedIn {
                        Task {
                            // Falls die Server-URL im Login geändert wurde: Stores
                            // auf den neuen Namespace umschalten, BEVOR der Sync
                            // (bzw. die Server-Seeds) loslaufen — sonst pollt er die
                            // Buch-IDs des alten Servers (→ `NO_BOOK_ACCESS`).
                            await core.switchServerIfNeeded()
                            await focus.seedFromServerIfNeeded()
                            await loc.seedFromServerIfNeeded()
                        }
                    }
                }
        }
        // Polling nur solange das Fenster aktiv ist; im Hintergrund pausieren,
        // beim Reaktivieren sofort ein Tick (CLAUDE.md, Cross-Session-Frische).
        .onChange(of: scenePhase, initial: true) { _, phase in
            core.sync.setActive(phase == .active)
            // Schreibzeit zählt nur im aktiven Fenster (wie der Sync-Poll).
            core.writingTime.setActive(phase == .active)
        }
        .commands {
            // „Über …" — Standard-Panel mit eigenem Credits-Text: Kurzbeschreibung
            // der App + klickbare Repo-Links (Mutterprojekt + dieser Client).
            // Name/Version/Copyright zieht das Panel weiter aus der Info.plist.
            // „Über …" plus „Nach Updates suchen…" in derselben App-Menü-Sektion
            // (Standard-Platz direkt unter „Über …"). Beides in EINER CommandGroup,
            // weil der @CommandsBuilder nur 10 Top-Level-Gruppen fasst.
            // `disabled`, solange Sparkle keinen Check zulässt (z. B. während schon
            // einer läuft); Hintergrund-Checks laufen unabhängig (SUEnableAutomaticChecks).
            CommandGroup(replacing: .appInfo) {
                Button(t("menu.about")) {
                    AboutPanel.show()
                }
                #if SPARKLE
                Button(t("menu.checkForUpdates")) {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)
                #endif

                // Abmelden im App-Menü (Konto-Aktion) — bisher nur im Toolbar-
                // Überlauf. Eigene Sektion, damit es nicht mit „Über …" verschmilzt.
                Divider()
                Button(t("general.signOut")) {
                    core.auth.signOut()
                }
            }

            // „Neu/Neues Fenster" ergibt für eine Ein-Seiten-Schreib-Shell keinen
            // Sinn (kein Dokumentmodell). Die Gruppe stattdessen mit der Seiten-/
            // Buch-Navigation belegen, die sonst nur in der Toolbar sitzt — so ist
            // sie auch über die Menüleiste erreichbar (mit sichtbarem ⌘O). Eigene
            // View, weil die Buchliste/„Seite schliessen"-Aktivierung mitlaufen
            // muss (`AppCore.library` ist ein `let` und republiziert nicht selbst).
            CommandGroup(replacing: .newItem) {
                PageMenuCommands(library: core.library,
                                 sync: core.sync,
                                 toolbarUI: toolbarUI,
                                 bookExport: core.bookExport,
                                 bridge: core.bridge,
                                 revisions: core.revisions)
            }
            CommandGroup(replacing: .saveItem) {}       // Sichern / Sichern unter…
            CommandGroup(replacing: .importExport) {}   // Import / Export
            CommandGroup(replacing: .sidebar) {}        // Seitenleiste ein-/ausblenden

            // Widerrufen/Wiederherstellen (Bearbeiten-Menü): MUSS ersetzt werden.
            // Die Standardeinträge von AppKit fahren WebKits eigenen Undo-Stack —
            // und der ist im contenteditable unbrauchbar grob (gemessen: alles
            // seit dem letzten Mausklick ist EIN Schritt). Der gebündelte Editor
            // führt stattdessen seine eigene, entprellte Snapshot-Historie
            // (SSoT `shared/edit-history.js`); erreichbar ist sie hier nur über
            // die Bridge, weil das Menü-Kürzel app-weit VOR der WebView greift.
            CommandGroup(replacing: .undoRedo) {
                HistoryMenuCommands(bridge: core.bridge)
            }

            // Format-Menü (Edit-Menü, nach Ausschneiden/Kopieren/Einfügen): die
            // Inline-Formatierung des Editors (Fett/Kursiv/Unterstrichen) auch über
            // die Menüleiste, mit sichtbaren ⌘B/⌘I/⌘U. Die Befehle laufen über die
            // Bridge (`applyFormat` → `document.execCommand`) — dieselbe Wirkung wie
            // die nativen contenteditable-Shortcuts, nur jetzt menü-getrieben (das
            // Menü fängt das Tastenkürzel vor der WebView ab, darum MUSS die Aktion
            // selbst formatieren). Eigene View für die reaktive „kein-Seite"-Sperre.
            CommandGroup(after: .pasteboard) {
                FormatMenuCommands(library: core.library, bridge: core.bridge)
            }

            // Alle „Darstellung/Editor"-Menüpunkte in EINER Gruppe (nach `.toolbar`):
            // Darstellung, Fokus und Vollbild. Bewusst gebündelt — der
            // @CommandsBuilder fasst nur 10 Top-Level-Gruppen; Divider erhalten
            // die optische Trennung wie zuvor. (Manueller Sync sitzt im Ablage-
            // Menü bei der Seiten-Navigation, s. `PageMenuCommands`.)
            CommandGroup(after: .toolbar) {
                // Manueller Light/Dark/System-Umschalter. Inline-Picker rendert
                // als Menüpunkte mit Häkchen beim aktiven Modus.
                Picker(t("menu.appearance"), selection: $appearance.mode) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.inline)

                Divider()

                // Fokus-Granularität — bestimmt, wie stark der Editor die Umgebung
                // des aktiven Absatzes abblendet. Wirkt sofort bei offenem Editor.
                Picker(t("menu.focus"), selection: $focus.granularity) {
                    ForEach(FocusGranularity.allCases) { g in
                        Text(g.label).tag(g)
                    }
                }
                .pickerStyle(.inline)

                Divider()

                // Vollbild ein/aus. Eigener Menüpunkt als zuverlässiger Einstieg:
                // im Vollbild blendet macOS Ampel-Buttons und Titelleiste (samt
                // Toolbar) aus — ein Menüpunkt ist der verlässliche Rückweg.
                // Label folgt dem Zustand, damit der Rückweg klar benannt ist.
                Button(windowChrome.isNativeFullscreen
                       ? t("menu.exitFullscreen")
                       : t("menu.enterFullscreen")) {
                    windowChrome.toggleFullscreen()
                }
                .keyboardShortcut(Shortcuts.fullscreen)
            }

            // Fenster-Menü: expliziter Eintrag, der das Hauptfenster öffnet —
            // auch (und gerade) wenn es geschlossen ist. Genau der Rückweg, den
            // der App-Review vermisst hat (Guideline 4, „no menu item to re-open
            // it"). ⌘0 ist der übliche macOS-Platz für „Hauptfenster zeigen".
            // `replacing:` statt `before:`, weil SwiftUI in diese Sektion für
            // jede `Window`-Szene selbst einen Eintrag hängt — sonst stünde das
            // Hauptfenster doppelt („Schreibfenster" + Fenstertitel). Der
            // automatische Eintrag der Kürzel-Hilfe überlebt das Ersetzen
            // (nachgemessen im laufenden Build), bleibt also erreichbar.
            CommandGroup(replacing: .singleWindowList) {
                Button(t("menu.mainWindow")) {
                    openWindow(id: Self.mainWindowID)
                }
                .keyboardShortcut(Shortcuts.mainWindow)
            }

            // Help-Menü: die Standard-„App-Hilfe" (toter Help-Book-Eintrag)
            // durch unsere Tastaturkürzel-Hilfe ersetzen (⌘?).
            CommandGroup(replacing: .help) {
                Button(t("menu.shortcuts")) {
                    openWindow(id: Self.shortcutsWindowID)
                }
                .keyboardShortcut(Shortcuts.thisHelp)
            }
        }

        // Tastaturkürzel-Hilfe als eigenes, einfaches Fenster.
        Window(t("window.shortcutsTitle"), id: Self.shortcutsWindowID) {
            ShortcutsHelpView()
                .environmentObject(loc)
        }
        .windowResizability(.contentSize)

        // Natives Einstellungen-Fenster (⌘,). Environment-Objects fließen NICHT
        // automatisch aus der WindowGroup hierher → explizit weiterreichen.
        Settings {
            SettingsView()
                .environmentObject(core)
                .environmentObject(core.auth)
                .environmentObject(core.library)
                .environmentObject(core.editorBundle)
                .environmentObject(core.sync)
                .environmentObject(appearance)
                .environmentObject(focus)
                .environmentObject(typography)
                .environmentObject(writingStats)
                .environmentObject(loc)
                #if SPARKLE
                .environmentObject(updater)
                #endif
        }
    }
}

/// Ablage-Menü-Befehle: Seiten- und Buch-Navigation (sonst nur in der Toolbar)
/// auch über die Menüleiste, mit sichtbarem ⌘O. Eigene View mit `@ObservedObject`,
/// damit die Buchliste und die „Seite schliessen"-Aktivierung live mitlaufen —
/// der `@CommandsBuilder` im `App`-Scope bekäme sonst keine Änderungs-Pushes vom
/// `LibraryStore` (in `AppCore` nur ein `let`).
private struct PageMenuCommands: View {
    @ObservedObject var library: LibraryStore
    let sync: SyncEngine
    /// Geteilter UI-Zustand — das Menü schaltet nur Sheets frei, die Arbeit
    /// machen die Dialoge im Editor-Host.
    @ObservedObject var toolbarUI: ToolbarUIState
    @ObservedObject var bookExport: BookExportController
    let bridge: EditorBridge
    let revisions: PageRevisionStore

    var body: some View {
        // Neue Seite (⌘N) — braucht ein aktives Buch; das Anlegen selbst geht
        // an den Server (POST), s. PageAdminController.
        Button(t("menu.newPage")) {
            toolbarUI.newPageOpen = true
        }
        .keyboardShortcut(Shortcuts.newPage)
        .disabled(library.activeBookId == nil)

        Button(t("menu.openPage")) {
            library.requestPicker()
        }
        .keyboardShortcut(Shortcuts.openPage)

        Button(t("menu.closePage")) {
            library.closePage()
        }
        .disabled(library.openPageId == nil)

        Divider()

        // Frühere Fassungen der offenen Seite (⌘⇧R) — der Weg zurück, wenn
        // ⌘⇧Z nicht mehr greift (WebKit verwirft den Redo-Stack beim nächsten
        // Zeichen).
        Button(t("menu.revisions")) {
            guard let pageId = library.openPageId else { return }
            toolbarUI.revisionsOpen = true
            Task { await revisions.load(pageId: pageId) }
        }
        .keyboardShortcut(Shortcuts.revisions)
        .disabled(library.openPageId == nil)

        Divider()

        // Buch als Markdown sichern — Server-Export (online-only), vorher wird
        // gesichert + gepusht (s. BookExportController). BEWUSST OHNE Tastenkürzel: das naheliegende ⌘⇧E gehört der
        // Fokus-Umschaltung im Editor, und ein Menü-Kürzel würde ihr die Taste
        // vor der WebView wegnehmen. Ein seltener Befehl ist das nicht wert.
        Button(t("menu.exportBook")) {
            bookExport.exportActiveBook()
        }
        .disabled(!bookExport.canExport)

        Divider()

        // Manueller Sync (⌘S) — wirkt auch bei pausiertem/manuellem Modus.
        // ⌘S ist in den meisten Apps „Speichern": `syncManually()` flusht
        // darum zuerst den offenen Draft in den LocalStore und stösst erst
        // danach Push/Pull an → ⌘S speichert UND synchronisiert. Sitzt im
        // Ablage-Menü, weil „Speichern/Synchronisieren" dorthin gehört.
        Button(t("menu.syncNow")) {
            sync.syncManually()
        }
        .keyboardShortcut(Shortcuts.syncNow)

        Divider()

        Menu(t("menu.book")) {
            if library.books.isEmpty {
                Text(t("library.noBooks"))
            } else {
                ForEach(library.books, id: \.id) { book in
                    Button {
                        library.selectBook(book.id)
                    } label: {
                        let name = book.name ?? t("library.bookFallback", ["id": "\(book.id)"])
                        if book.id == library.activeBookId {
                            Label(name, systemImage: "checkmark")
                        } else {
                            Text(name)
                        }
                    }
                }
            }
        }
    }
}

/// Widerrufen/Wiederherstellen im Bearbeiten-Menü.
///
/// Routet bewusst nach dem First Responder, statt stur in den Editor zu
/// schiessen: das Kürzel ⌘Z gilt app-weit, es muss also auch im Suchfeld des
/// Seiten-Pickers und in den Einstellungen-Feldern funktionieren. Liegt der
/// Fokus in der Schreibfläche (WKWebView), geht die Aktion über die Bridge an
/// die Historie des gebündelten Editors; sonst an AppKit — genau dorthin, wo die
/// ersetzten Standardeinträge sie hingeschickt hätten (`undo:`/`redo:` über die
/// Responder-Kette, also der NSUndoManager des Feld-Editors).
///
/// Bewusst immer aktiv: ob etwas zu widerrufen ist, weiss erst die Historie in
/// der WebView (asynchron) bzw. der Feld-Editor. Ein deaktivierter Menüpunkt
/// würde das Kürzel dagegen NICHT verbrauchen — dann liefe ⌘Z wieder auf
/// WebKits groben Stack, also genau in den Datenverlust-Fall zurück.
private struct HistoryMenuCommands: View {
    let bridge: EditorBridge

    var body: some View {
        Button(t("menu.undo")) { route("undo", fallback: "undo:") }
            .keyboardShortcut(Shortcuts.undo)
        Button(t("menu.redo")) { route("redo", fallback: "redo:") }
            .keyboardShortcut(Shortcuts.redo)
    }

    private func route(_ action: String, fallback selector: String) {
        if editorHasFocus {
            Task { await bridge.applyHistory(action) }
        } else {
            NSApp.sendAction(Selector((selector)), to: nil, from: nil)
        }
    }

    /// Hat die Schreibfläche den Tastaturfokus? Der First Responder ist beim
    /// Tippen im Editor die `WKWebView` selbst (nachgemessen); ein Textfeld
    /// meldet dagegen seinen Feld-Editor (`NSText`).
    private var editorHasFocus: Bool {
        var responder = NSApp.keyWindow?.firstResponder
        while let current = responder {
            if current is WKWebView { return true }
            responder = current.nextResponder
        }
        return false
    }
}

/// Format-Menü-Befehle: die Inline-Formatierung des Editors (Fett/Kursiv/
/// Unterstrichen) über die Menüleiste, mit ⌘B/⌘I/⌘U. Die Aktion routet über die
/// Bridge in die WebView (`document.execCommand`) — dieselbe Wirkung wie die
/// nativen contenteditable-Shortcuts. Da das Menü das Tastenkürzel VOR der
/// WebView abfängt, muss die Aktion selbst formatieren. `@ObservedObject library`
/// nur für die reaktive Sperre, solange keine Seite offen ist.
private struct FormatMenuCommands: View {
    @ObservedObject var library: LibraryStore
    let bridge: EditorBridge

    var body: some View {
        Button(t("menu.bold")) { apply("bold") }
            .keyboardShortcut(Shortcuts.bold)
            .disabled(library.openPageId == nil)
        Button(t("menu.italic")) { apply("italic") }
            .keyboardShortcut(Shortcuts.italic)
            .disabled(library.openPageId == nil)
        Button(t("menu.underline")) { apply("underline") }
            .keyboardShortcut(Shortcuts.underline)
            .disabled(library.openPageId == nil)
    }

    private func apply(_ command: String) {
        Task { await bridge.applyFormat(command) }
    }
}

/// Eigenes „Über …"-Panel: nutzt das native macOS-About-Panel und reicht nur
/// einen Credits-Text nach (Kurzbeschreibung + klickbare Repo-Links). Name,
/// Version und Copyright kommen weiter aus der Info.plist (CFBundleName,
/// CFBundleShortVersionString, NSHumanReadableCopyright) — nicht hier doppeln.
enum AboutPanel {
    @MainActor
    static func show() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .credits: credits
        ])
    }

    private static var credits: NSAttributedString {
        let body = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let bold = NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.paragraphSpacing = 6

        let s = NSMutableAttributedString()

        func line(_ text: String, font: NSFont = body) {
            s.append(NSAttributedString(string: text + "\n", attributes: [
                .font: font,
                .paragraphStyle: para,
                .foregroundColor: NSColor.labelColor,
            ]))
        }
        func link(_ label: String, _ url: String) {
            s.append(NSAttributedString(string: label + "\n", attributes: [
                .font: body,
                .paragraphStyle: para,
                .link: url,
            ]))
        }

        line(t("about.tagline"), font: bold)
        line(t("about.body"))
        line(" ")
        line(t("about.motherProject"), font: bold)
        link("github.com/schreibwerkstatt/schreibwerkstatt",
             "https://github.com/schreibwerkstatt/schreibwerkstatt")

        return s
    }
}
