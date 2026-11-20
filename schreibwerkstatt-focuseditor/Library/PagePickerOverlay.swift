//
//  PagePickerOverlay.swift
//  schreibwerkstatt-focuseditor
//
//  Beschwörbarer Seiten-Picker (⌘O) — ein schwebendes Such-/Listen-Overlay über
//  dem Editor, das nach der Auswahl wieder verschwindet. Maximal ablenkungsfrei:
//  keine dauerhafte Sidebar, kein Chrome beim Schreiben.
//
//  Bedienung: Tippen filtert, ⏎ öffnet den ersten Treffer, ⎋ oder Klick auf den
//  Hintergrund schliesst. Die Auswahl hebt die Seite über die Bridge (`openPage`)
//  in die WebView.
//
//  Gliederung: Ganz oben die Gruppe „Zuletzt geöffnet" (bis zu fünf Seiten des
//  aktiven Buchs in MRU-Reihenfolge, gerätelokal gemerkt — s.
//  `EditorBridge.recentPageIds` / `LibraryStore.recentPageRows`), darunter der
//  Kapitelbaum. Eine Seite kann darum ZWEIMAL in der Liste stehen; die Zeilen-
//  Identität ist entsprechend sektions-qualifiziert (`RowKey`).
//
//  Aufteilung (Vorbild `AppToolbar+Controls`):
//    • hier                          State, `body`, Suchfeld, Liste, Aktionen
//    • [+Rows](PagePickerOverlay+Rows.swift)          Zeile, Header, Breadcrumb, Leerzustand
//    • [+Keyboard](PagePickerOverlay+Keyboard.swift)  NSEvent-Monitor, Fokus, Hover, Auswahl
//    • [PagePickerModel](PagePickerModel.swift)       PURE Filter-/Gruppierungs-Logik (getestet)
//
//  Die von den Extensions gelesenen Properties sind darum modul-intern (nicht
//  `private`) — `private` gilt in Swift datei-, nicht typ-weit.
//

import SwiftUI
import AppKit

struct PagePickerOverlay: View {
    /// Anzeigemodell-Typen (Definition + Warum in `PagePickerModel`) — als
    /// Aliase, damit der View-Code kurz bleibt.
    typealias RowKey = PagePickerModel.RowKey
    typealias IndexedRow = PagePickerModel.IndexedRow
    typealias PickerGroup = PagePickerModel.Group

    /// Ein Scroll-Auftrag: Zielzeile + Laufnummer (s. `scrollRequest`).
    struct ScrollRequest: Equatable {
        let key: RowKey
        let seq: Int
    }

    @EnvironmentObject var library: LibraryStore
    /// Geteilter UI-Zustand — der Picker beschwört von hier aus die Dialoge
    /// „Neue Seite" / „Umbenennen" / „Löschen" (die Arbeit macht der
    /// PageAdminController, die Dialoge hängen am Editor-Host).
    @EnvironmentObject var toolbarUI: ToolbarUIState
    @Binding var isOpen: Bool

    @State var query = ""
    @FocusState var searchFocused: Bool
    /// Welcher Zählwert an der Zeile steht (Einstellungen → Schreiben). Wirkt
    /// sofort — die Zahlen liegen ohnehin im `LibraryStore`, es ist reine Anzeige.
    @AppStorage(PagePickerMetric.defaultsKey) var pickerMetric = PagePickerMetric.chars
    /// Index der per Tastatur/Hover markierten Zeile in `filtered`.
    @State var selected = 0
    /// Ziel für den Auto-Scroll — der `RowKey` der anzusteuernden Zeile (gleiche
    /// Identität wie die `ForEach`-Zeilen), NICHT der Lauf-Index. Wird NUR von der
    /// Tastatur-Navigation/Vorauswahl gesetzt, nicht vom Hover — sonst entsteht eine
    /// Rückkopplung (Hover → Scroll → Zeilen rutschen unter den Cursor → neuer
    /// Hover → …), die als Flackern sichtbar ist.
    ///
    /// Trägt eine Laufnummer, damit auch ein Ziel, das dem letzten GLEICHT, wieder
    /// anrollt: bei einem Struktur-Umbau (s. `structureID`) baut SwiftUI den
    /// Scroll-Teilbaum neu auf und beginnt oben — ohne Laufnummer bliebe die Liste
    /// dort stehen, weil `onChange` bei unverändertem Wert nicht feuert.
    @State var scrollRequest: ScrollRequest?
    /// Laufnummern-Zähler für `scrollRequest`.
    @State var scrollSeq = 0
    /// Stempel der aktuellen Gliederung (aus `PagePickerModel.Result`) — hängt als
    /// `.id` an der Ergebnisliste und erzwingt bei einem Umbau einen frischen
    /// Scroll-Teilbaum, statt Zeilen recyceln zu lassen (s. dort das Warum).
    @State var structureID = 0
    /// Lokaler Key-Monitor für ↑/↓/⏎ — fängt die Tasten ab, bevor das fokussierte
    /// Suchfeld sie als Cursor-Bewegung/Submit schluckt.
    @State var keyMonitor: Any?
    /// Letzte Cursor-Position (Screen-Koordinaten), bei der ein Hover die Auswahl
    /// gesetzt hat. Dient dazu, ECHTE Mausbewegung von „Zeilen rutschen beim
    /// Scrollen unter den ruhenden Cursor" zu unterscheiden — s. `handleHover`.
    @State var lastHoverLocation: NSPoint = .zero

    /// Memoisierte Trefferliste + Kapitel-Gruppierung. BEWUSST in `@State`, NICHT
    /// als computed property: bei einem grossen Buch (Tausende Seiten) wäre die
    /// Filterung + Gruppierung sonst bei JEDER Body-Neuberechnung fällig — und die
    /// triggert schon jeder Hover (`selected` ändert sich). Stattdessen nur bei
    /// echter Eingabe (`query`) oder neuer Seitenliste neu rechnen (`recompute()`),
    /// sodass Hover/Tastatur-Navigation rein über `selected` läuft.
    /// `filtered` ist die flache Zeilenfolge in Anzeige-Reihenfolge (Gruppe
    /// „Zuletzt geöffnet" zuerst, dann der Kapitelbaum) — die Brücke zur
    /// Tastatur-Auswahl (`selected` ist ein Index hierin).
    @State var filtered: [IndexedRow] = []
    @State var groups: [PickerGroup] = []
    /// Zahl der ECHTEN Treffer im Kapitelbaum (ohne die Zuletzt-Geöffnet-Kopien) —
    /// speist die Trefferzahl im Suchfeld, die sonst durch die Duplikate zu hoch wäre.
    @State var matchCount = 0
    /// Umfang der Trefferliste (Seiten/Wörter/Zeichen) für die Summenzeile —
    /// memoisiert wie `filtered`: die Summe über Tausende Zeilen darf nicht an
    /// jedem Hover-Render hängen.
    @State var summary = PagePickerModel.Summary.empty
    /// Seiten-IDs, deren INHALT (Body, nicht nur Name) zur aktuellen Suche passt —
    /// async aus dem lokalen Volltext-Index (`library.searchContentIds`) gespeist.
    /// Erweitert die rein synchrone Namens-/Kapitelsuche.
    @State var contentMatches: Set<Int> = []
    /// Lief `recompute()` schon mindestens einmal? `filtered`/`groups` sind im
    /// ALLERERSTEN Body-Render noch leer (SwiftUI rendert einmal VOR `onAppear`,
    /// wo recompute läuft) — obwohl der Cache `library.pages` schon gefüllt ist.
    /// Ohne dieses Flag fiele dieser eine Frame auf den `filtered.isEmpty`-Branch
    /// und liesse beim Öffnen kurz den Leerzustand aufblitzen (sichtbares Flackern,
    /// v. a. bei einem gefüllten Buch). Bis zum ersten Rechnen darum NICHT den
    /// Leerzustand zeigen, sondern einen ruhigen leeren Platzhalter — die
    /// Einblend-Transition (opacity+scale) kaschiert ihn vollständig.
    @State var hasComputed = false

    /// Rechnet Trefferliste (`filtered`) + Gruppierung (`groups`) neu und legt sie
    /// im State ab. Nur bei echter Änderung der Eingabe/Seitenliste aufrufen
    /// (s. `filtered`-Doku) — NICHT bei jedem Render. Die Logik selbst steht als
    /// pure Funktion in [PagePickerModel](PagePickerModel.swift).
    func recompute() {
        let result = PagePickerModel.build(pages: library.pages,
                                          recents: library.recentPageRows(),
                                          query: query,
                                          contentMatches: contentMatches,
                                          stats: library.pageStats)
        filtered = result.rows
        groups = result.groups
        matchCount = result.matchCount
        summary = result.summary
        structureID = result.structureID
        hasComputed = true
        // Genau EIN Treffer → sogleich selektieren, sodass ⏎ direkt öffnet.
        // Fängt auch den asynchronen Volltext-Pfad ab (`runContentSearch`), der kein
        // nachfolgendes `selected = 0` aus `onChange(query)` erhält — dort bliebe
        // der Scroll-Auftrag sonst leer, obwohl die Liste auf genau eine Zeile schrumpft.
        if result.matchCount == 1, let firstKey = result.rows.first?.key {
            selected = 0
            requestScroll(to: firstKey)   // erstes Vorkommen (Recent-Kopie oder Baum-Zeile)
        }
    }

    /// Wunschmass des Overlays. Breiter als früher (460 pt), weil in der Zeile jetzt
    /// Name, Badge, Umfang UND Relativ-Zeit stehen — lange Seitennamen wurden sonst
    /// abgeschnitten. Bei einem kleineren Fenster klemmt `frame(maxWidth:)` das
    /// Mass auf die verfügbare Breite (minus Rand), damit das Overlay nie über den
    /// Fensterrand hinausläuft.
    private static let preferredWidth: CGFloat = 620
    private static let preferredHeight: CGFloat = 460

    var body: some View {
        GeometryReader { geo in
            picker(available: geo.size)
        }
    }

    private func picker(available: CGSize) -> some View {
        ZStack {
            // Abdunkelnder Hintergrund — Klick schliesst.
            Color.black.opacity(0.25)
                .ignoresSafeArea()
                .onTapGesture { close() }
                .accessibilityHidden(true)   // rein dekorativ (⎋ schliesst ebenfalls)

            VStack(spacing: 0) {
                searchField
                Divider()
                content
                // Summenzeile nur, wenn auch Zeilen stehen — im Leer-/Ladezustand
                // wäre „0 Seiten · 0 Zeichen" nur Lärm.
                if hasComputed && !filtered.isEmpty {
                    Divider()
                    summaryBar
                }
            }
            .frame(width: min(Self.preferredWidth, max(320, available.width - 48)),
                   height: min(Self.preferredHeight, max(240, available.height - 48)))
            // Pfeil-Cursor für das GANZE Overlay erzwingen. An die View gebunden
            // (nicht das transiente `NSCursor.set()`) → gewinnt zuverlässig über
            // die darunterliegende WebView, die sonst ihren I-Beam durchdrückt
            // (sichtbar v. a. wenn man aus dem Editor in die Liste fährt). Das
            // Suchfeld setzt seinen eigenen Text-Cursor lokal (s. `searchField`).
            .pointerDefault()
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(BrandColor.muted.opacity(0.2))
            )
            .shadow(radius: 30, y: 8)
            // Modal: VoiceOver soll nicht in den Editor dahinter wandern, solange
            // der Picker offen ist.
            .accessibilityElement(children: .contain)
            .accessibilityLabel(t("picker.a11y.dialog"))
            .accessibilityAddTraits(.isModal)
        }
        .onExitCommand { close() }               // ⎋
        .onAppear {
            // Cursor wird über `.pointerStyle(.default)` am Overlay erzwungen —
            // kein manuelles `NSCursor.set()` mehr nötig (war unzuverlässig, die
            // WebView überschrieb es wieder).
            focusSearchField()
            installKeyMonitor()
            recompute()                           // Trefferliste/Gruppen aus dem Cache
            selectOpenPage()                      // falls Seiten schon im Cache stehen
            Task { await library.refreshPages() } // beim Öffnen frisch ziehen
        }
        .onDisappear { removeKeyMonitor() }
        .onChange(of: library.pages) { _, _ in          // async nachgeladen → springen
            recompute()                                 // neue Liste → Treffer/Gruppen neu
            selectOpenPage()
        }
        // Zählwerte kommen aus dem lokalen Spiegel und treffen nach der Seitenliste
        // ein → Summenzeile (memoisiert) nachrechnen. Die Zahlen an den Zeilen
        // selbst lesen direkt aus `library.pageStats` und brauchen das nicht.
        .onChange(of: library.pageStats) { _, _ in recompute() }
        .onChange(of: query) { _, newQuery in           // neue Suche → oben anfangen
            recompute()                                 // sofort: Namens-/Kapiteltreffer
            selected = 0
            requestScroll(to: filtered.first?.key)      // erste Trefferzeile
            runContentSearch(for: newQuery)             // async: Inhaltstreffer nachladen
        }
    }

    /// Stösst die Volltextsuche über den Seiteninhalt an (async, lokaler Index) und
    /// führt nach Eintreffen ein erneutes `recompute()` aus. Die Such-Policy
    /// (Trimming + Mindestlänge) sitzt in `LibraryStore.searchContentIds` — eine
    /// zu kurze Eingabe liefert dort einfach die leere Menge, was hier korrekt die
    /// bisherigen Inhaltstreffer löscht.
    /// Staleness-Schutz: ein Ergebnis wird nur übernommen, wenn die Eingabe seither
    /// unverändert ist (sonst überschriebe ein langsamer Lauf eine neuere Suche).
    private func runContentSearch(for q: String) {
        Task {
            let ids = await library.searchContentIds(query: q)
            guard q == query else { return }   // Eingabe inzwischen weiter → verwerfen
            // Nur bei echter Änderung neu rechnen — sonst rechnet jede Eingabe
            // ohne Inhaltstreffer die ganze Liste ein zweites Mal durch.
            guard ids != contentMatches else { return }
            contentMatches = ids
            recompute()
            // Die nachgezogenen Treffer verschieben ALLE Lauf-Indizes. Eine
            // Markierung von vorher zeigte danach auf eine fremde Zeile — ⏎ würde
            // eine andere Seite öffnen als markiert. Darum wieder auf den ersten
            // Treffer, wie nach jedem Tastendruck (`onChange(query)`).
            selected = 0
            requestScroll(to: filtered.first?.key)
        }
    }

    // MARK: Teile

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(BrandColor.muted)
                .accessibilityHidden(true)   // dekorativ; das Textfeld trägt das Label
            TextField(t("picker.searchPage"), text: $query)
                .textFieldStyle(.plain)
                .font(BrandFont.sans(14))
                .focused($searchFocused)
                .onSubmit(openSelected)         // ⏎ (Fallback; Monitor fängt i. d. R. ab)
                // Text-Cursor nur hier — übersteuert das `.default` des Overlays.
                .pointerHorizontalText()
                .accessibilityLabel(t("picker.searchPage"))
                .accessibilityHint(t("picker.a11y.searchHint"))

            if !library.pages.isEmpty {
                Text("\(matchCount)")
                    .font(BrandFont.sans(11))
                    .monospacedDigit()
                    .foregroundStyle(BrandColor.muted)
                    // Nackte Zahl wäre ohne Kontext vorgelesen.
                    .accessibilityLabel(tn(matchCount, "picker.a11y.matchCount"))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        if !hasComputed {
            // Erster Frame vor dem ersten recompute() — ruhig leer lassen statt
            // den Leerzustand aufblitzen zu lassen (s. `hasComputed`).
            Color.clear
        } else if library.isLoadingPages && library.pages.isEmpty {
            centered {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(t("picker.loadingPages"))
                        .font(BrandFont.sans(12))
                        .foregroundStyle(BrandColor.muted)
                }
            }
        } else if filtered.isEmpty {
            centered { emptyState }
        } else {
            resultList
        }
    }

    /// Die gruppierte Trefferliste mit gepinnten Kapitel-Überschriften.
    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.rows) { entry in
                                // KEINE explizite `.id(entry.index)` — der
                                // Lauf-Index wird über Filterungen wiederverwendet
                                // und liess SwiftUI alte Zeilen recyceln (falscher
                                // Seitenname unter richtigem Kapitel). Die `ForEach`-
                                // Identität ist `IndexedRow.id` = `RowKey` (stabil);
                                // der Auto-Scroll zielt darum ebenfalls auf den RowKey.
                                rowButton(entry.row, isSelected: entry.index == selected,
                                          // In der Zuletzt-Gruppe ohne Kapitel-Einzug —
                                          // die Zeilen stehen dort nicht im Baum.
                                          indent: group.isRecent ? 0 : entry.row.depth)
                                    // Hover markiert die Zeile (entprellt, s. +Keyboard).
                                    // Der Zeigehand-Cursor kommt vom `.pointerStyle(.link)`
                                    // an der Zeile.
                                    .onHover { handleHover(entry, hovering: $0) }
                                Divider().opacity(0.4)
                            }
                        } header: {
                            if group.isRecent {
                                recentHeader()
                            } else if !group.path.isEmpty {
                                chapterHeader(group.path)
                            } else {
                                // Kapitellose Top-Level-Seiten: eigener Header,
                                // sonst kleben sie ohne sichtbare Grenze unter der
                                // gepinnten Zuletzt-Gruppe (s. `topLevelHeader`).
                                topLevelHeader()
                            }
                        }
                    }
                }
            }
            .onChange(of: scrollRequest) { _, new in
                guard let new else { return }
                withAnimation(.easeOut(duration: 0.1)) {
                    proxy.scrollTo(new.key, anchor: .center)
                }
            }
            // Jeder Umbau der Gliederung (neue Suche, nachgezogene Volltext-Treffer,
            // Buchwechsel) wirft den Scroll-Teilbaum weg und baut ihn frisch auf.
            // Die `LazyVStack` mit gepinnten Sektionen recycelt sonst Zeilen quer
            // über Sektionsgrenzen: sichtbare Zeile und ihr Datensatz driften
            // auseinander (Klick/Hover/Markierung zielen an der Zeile vorbei, ganze
            // Kapitel-Gruppen wirken „nicht selektierbar" — s. `structureID`).
            // Feuert NUR bei echtem Umbau, nicht bei Hover/Tippen ohne
            // Trefferwechsel → keine Scroll-Performance-Kosten.
            .id(structureID)
        }
    }

    // MARK: Aktionen

    /// Setzt einen Scroll-Auftrag mit frischer Laufnummer (s. `scrollRequest`);
    /// `nil` löscht ihn (leere Liste). Jeder Aufruf feuert `onChange` — auch bei
    /// gleichem Ziel, damit ein neu aufgebauter Teilbaum wieder an die Zeile rollt.
    func requestScroll(to key: RowKey?) {
        guard let key else { scrollRequest = nil; return }
        scrollSeq &+= 1
        scrollRequest = ScrollRequest(key: key, seq: scrollSeq)
    }

    func open(_ row: PagePickerRow) {
        library.openPage(row)
        close()
    }

    func close() {
        isOpen = false
        // Der Picker hat der WebView beim Öffnen den First Responder genommen
        // (`focusSearchField`) — zurückgeben, sonst gingen die Anschläge nach
        // ⎋ ins Leere.
        library.focusEditor()
    }
}
