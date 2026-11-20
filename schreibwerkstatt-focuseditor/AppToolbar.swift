//
//  AppToolbar.swift
//  schreibwerkstatt-focuseditor
//
//  Eigene, markengerechte Toolbar-Leiste — eine schlanke Papier-Leiste mit
//  feiner Trennlinie. Sie wird als natives Titelleisten-Accessory gehostet
//  (s. `WindowChromeController`), als vollbreiter Streifen direkt unter den
//  Ampel-Buttons — NICHT mehr als oberste Content-Leiste (das verschluckte im
//  Vollbild die Klicks auf die Icons). Geteilter Zustand mit dem Editor-Host
//  läuft über `ToolbarUIState` (getrennte SwiftUI-Bäume über die AppKit-Grenze).
//
//  Inhalt: Buch-Picker (links), Öffnen (⌘O), Sync-Status und ein Überlauf-Menü
//  rechts. Im Fenster immer sichtbar; im Vollbild blendet macOS sie samt
//  Titelleiste aus und zeigt sie beim Hochfahren der Maus wieder.
//
//  Diese Datei trägt die Shell (`ToolbarUIState` + `AppToolbar`); die Sub-Views
//  liegen ausgelagert: Bedien-Elemente in `AppToolbar+Controls.swift`, der
//  Status-Cluster (Save/Stats/Sync) in `AppToolbar+Status.swift`.
//

import SwiftUI
import AppKit
import Combine

/// Geteilter UI-Zustand der Toolbar, seit sie als natives Titelleisten-Accessory
/// (statt als Content-Leiste) gehostet wird: Der Editor-Host und die im
/// `NSTitlebarAccessoryViewController` gehostete `AppToolbar` leben in getrennten
/// SwiftUI-Bäumen — gemeinsamer Zustand (offener Seiten-Picker, zu prüfender
/// Konflikt) läuft darum über dieses geteilte ObservableObject statt über
/// `@State`/`@Binding`.
@MainActor
final class ToolbarUIState: ObservableObject {
    /// Sichtbarkeit des beschwörbaren Seiten-Pickers (⌘O).
    @Published var pickerOpen = false
    /// Aktuell im Auflösungs-Sheet geprüfter Konflikt (`nil` = zu).
    @Published var inspectingConflict: SyncEngine.Conflict?
    /// Sichtbarkeit des Revisions-Sheets („Frühere Fassungen …", ⌘⇧R).
    @Published var revisionsOpen = false
    /// Sichtbarkeit des „Neue Seite"-Dialogs (⌘N).
    @Published var newPageOpen = false
    /// Seite, die gerade umbenannt wird (`nil` = kein Dialog offen).
    @Published var renamingPage: PagePickerRow?
    /// Seite, deren Löschung bestätigt werden soll.
    @Published var deletingPage: PagePickerRow?
    /// Steht der Editor (Fenster offen, angemeldet, Bundle bereit)? Die Sheets
    /// hängen am Editor-Host — ohne ihn merkten sich die Menübefehle (⌘N, ⌘⇧R)
    /// ihr Sheet nur und liessen es nach dem nächsten Login ungefragt aufspringen.
    @Published var editorAvailable = false

    /// Editor-Host verschwindet (Abmelden, Fenster zu, Bundle-Fehler): offene
    /// Dialoge und den Picker zurücksetzen, statt sie beim Wiederkehren
    /// unvermittelt erneut zu zeigen.
    func resetTransient() {
        pickerOpen = false
        inspectingConflict = nil
        revisionsOpen = false
        newPageOpen = false
        renamingPage = nil
        deletingPage = nil
    }
}

struct AppToolbar: View {
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var sync: SyncEngine
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var writingStats: WritingStatsStore
    /// Schreibzeit-Tracker — liefert die heute geschriebene Zeit für den Überlauf
    /// (die Daten wurden bisher nur an den Server gemeldet, nie lokal gezeigt).
    @EnvironmentObject private var writingTime: WritingTimeTracker
    /// Geteilter UI-Zustand mit dem Editor-Host (Seiten-Picker + Konflikt-Sheet) —
    /// nötig, weil die Toolbar jetzt in einem eigenen, vom Host getrennten
    /// SwiftUI-Baum (Titelleisten-Accessory) lebt.
    @EnvironmentObject private var toolbarUI: ToolbarUIState
    /// Laufendes Lektorat — sein Knopf bleibt auch nach dem Schliessen der
    /// Seite stehen, damit der Lauf abbrechbar bleibt.
    @EnvironmentObject private var lektorat: LektoratJobStore

    /// Hover-Zustand des Überlauf-Menüs (Material-Highlight).
    @State private var overflowHover = false

    /// Synonym-Hilfe lokal an/aus (Einstellungen → Schreiben) — steuert die
    /// Sichtbarkeit des Synonym-Knopfs, damit kein wirkungsloses Icon steht.
    @AppStorage(SynonymPrefs.enabledKey) private var synonymsEnabled = true

    /// Gemessene Breite der Leiste — treibt das responsive Zusammenfalten des
    /// Breadcrumbs auf schmalen Fenstern (s. `showChapter`).
    @State private var toolbarWidth: CGFloat = 0

    /// Das Kapitel-Segment des Breadcrumbs nur zeigen, wenn die Leiste breit
    /// genug ist — sonst kollidiert es auf schmalen Fenstern mit dem
    /// Status-Cluster und wird hart abgeschnitten. Der Seitenname (wichtiger)
    /// bleibt immer. `0` = noch nicht gemessen → zunächst zeigen.
    private var showChapter: Bool { toolbarWidth == 0 || toolbarWidth >= 900 }

    var body: some View {
        HStack(spacing: 14) {
            BookPicker()

            if showChapter, let chapter = library.openChapterName {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(BrandColor.faint)
                    .accessibilityHidden(true)   // dekorativer Breadcrumb-Trenner
                Text(chapter)
                    .font(BrandFont.sans(12))
                    .foregroundStyle(BrandColor.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
            }

            if let page = library.openPageName {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(BrandColor.faint)
                    .accessibilityHidden(true)   // dekorativer Breadcrumb-Trenner
                Text(page)
                    .font(BrandFont.sans(12))
                    .foregroundStyle(BrandColor.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(2)
            }

            Spacer(minLength: 12)

            // ⌘O liegt am Menübefehl „Seite öffnen" (Ablage) — die kanonische,
            // im Menü sichtbare Stelle. Hier nur der Klick-Einstieg, kein zweiter
            // (kollidierender) Shortcut.
            ToolbarIconButton(systemName: "doc.text.magnifyingglass",
                              help: t("toolbar.openPageHelp"),
                              accessibilityLabel: t("toolbar.openPage")) {
                toolbarUI.pickerOpen.toggle()
            }

            // Seiten-bezogene Aktionen — nur sichtbar, wenn eine Seite offen ist.
            if library.openPageId != nil {
                // Synonyme (⌘⇧S) als Klick-Einstieg: der Hotkey ist nicht
                // sichtbar, der Knopf schon. Nur wenn die Synonym-Hilfe lokal
                // aktiv ist (Einstellungen → Schreiben) — sonst wäre der Klick
                // wirkungslos.
                if synonymsEnabled {
                    ToolbarIconButton(systemName: "text.book.closed",
                                      help: t("toolbar.synonymsHelp"),
                                      accessibilityLabel: t("toolbar.synonyms")) {
                        library.openSynonyms()
                    }
                }

                // Anführungszeichen normalisieren: zieht gerade/gemischte Quotes
                // der offenen Seite auf den Buch-Stil (de-CH → «», de-DE → „" …).
                // Häufig gebraucht → direkt in der Leiste statt im Überlauf.
                ToolbarIconButton(systemName: "quote.opening",
                                  help: t("toolbar.normalizeQuotesHelp"),
                                  accessibilityLabel: t("toolbar.normalizeQuotes")) {
                    library.normalizeQuotes()
                }

                // Lektorat der offenen Seite serverseitig starten (KI-Job). Eigene
                // View, weil der Knopf einen Zustand trägt (Spinner während des
                // Laufs, Klick = Abbrechen) — anders als die zustandslosen Icons.
                LektoratToolbarButton()

                // Seite schliessen — sichert lokal und öffnet den Picker für die
                // nächste Wahl.
                ToolbarIconButton(systemName: "xmark",
                                  help: t("toolbar.closePageHelp"),
                                  accessibilityLabel: t("toolbar.closePage")) {
                    library.closePage()
                }
            }

            // ── Status-Cluster (rechts) — von den Navigations-/Aktionselementen
            // durch einen feinen Trenner abgesetzt: links „wo bin ich / was tue
            // ich", rechts „Zustand" (gesichert / Wörter / Sync). Save-Indikator
            // und Schreibstatistik beziehen sich auf die offene Seite — ohne Seite
            // sind sie sinnlos („0 Wörter") und bleiben darum ausgeblendet; nur der
            // (globale) Sync-Status steht dann rechts. Der Trenner erscheint nur,
            // wenn links davon ein seitenbezogenes Element sitzt.
            if library.openPageId != nil {
                ToolbarSeparator()

                SaveStateLabel(dirty: library.openPageDirty)

                if writingStats.showStats {
                    WritingStatsLabel(words: writingStats.words,
                                      characters: writingStats.characters,
                                      wordsToday: writingStats.wordsToday,
                                      charactersToday: writingStats.charactersToday,
                                      readingMinutes: writingStats.readingMinutes,
                                      goal: writingStats.pageGoalWords,
                                      progress: writingStats.goalProgress)
                }
            }

            // Abschnitt während eines Lektorats geschlossen: der Knopf (Spinner,
            // Klick = Abbrechen) bleibt, sonst liefe der Job unabbrechbar weiter.
            if library.openPageId == nil && lektorat.isBusy {
                LektoratToolbarButton()
            }

            SyncStatusLabel(status: sync.status,
                            conflicts: sync.conflicts,
                            lastSyncedAt: sync.lastSyncedAt,
                            pendingCount: sync.pendingCount,
                            lastError: sync.lastError,
                            onInspect: { toolbarUI.inspectingConflict = $0 })

            // Fokus-Stufe + Darstellung direkt in der Leiste (statt zwei Klicks
            // tief im Überlauf): immer sichtbar — auch im nativen Vollbild, wo die
            // Menüleiste weg ist. Direktwahl per Inline-Picker mit Häkchen.
            FocusMenuButton()
            AppearanceMenuButton()

            overflowMenu
        }
        .padding(.leading, 16)
        .padding(.trailing, 16)
        .frame(height: 50)
        .frame(maxWidth: .infinity)
        // Pfeil-Cursor über der ganzen Leiste erzwingen — sonst drückt die
        // darunterliegende Editor-WebView am unteren Rand ihren I-Beam durch
        // (sichtbar, wenn man von der Schreibfläche hochfährt). An die View
        // gebunden, daher zuverlässiger als ein transientes `NSCursor.set()`.
        .pointerDefault()
        // Breite messen (treibt `showChapter`); Color.clear ist unsichtbar.
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: ToolbarWidthKey.self, value: geo.size.width)
            }
        )
        .onPreferenceChange(ToolbarWidthKey.self) { toolbarWidth = $0 }
        // Leere Flächen ziehen das Fenster (auch im Titelleisten-Accessory).
        .background(WindowDragArea())
        // Nur eine dezente Marken-Papier-Tönung — KEIN `.regularMaterial`-Frosted
        // mehr: die Toolbar sitzt jetzt im nativen Titelleisten-Bereich
        // (NSTitlebarAccessory), der schon eine eigene Vibrancy mitbringt; eine
        // zweite Materialschicht wirkte doppelt/zu schwer. Im Vollbild blendet
        // macOS die Leiste samt Titelleiste automatisch aus.
        .background(BrandColor.surface.opacity(0.35))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(BrandColor.faint.opacity(0.9))
                .frame(height: 1)
        }
    }

    /// Heute geschriebene Zeit als lokalisierte, minutengenaue Kurzform
    /// („1 Std 20 Min" / „45 Min").
    private var formattedWritingTime: String {
        let total = writingTime.todaySeconds
        let h = total / 3600
        let m = (total % 3600) / 60
        return h > 0
            ? t("writingtime.hm", ["h": "\(h)", "m": "\(m)"])
            : t("writingtime.m", ["m": "\(m)"])
    }

    /// Überlauf: selten gebrauchte Aktionen gebündelt — hält die Leiste ruhig.
    /// Darstellung + Fokus sitzen jetzt als eigene Inline-Knöpfe in der Leiste
    /// (direkt erreichbar, auch im Vollbild) — der Überlauf trägt nur noch die
    /// selten gebrauchten Einstiege (Einstellungen, manueller Sync, Abmelden).
    private var overflowMenu: some View {
        Menu {
            // Heute geschriebene Zeit — informativ (nicht anklickbar). Nur ab einer
            // vollen Minute, sonst ist die Zeile Rauschen. Die Daten kommen aus dem
            // WritingTimeTracker (bisher nur serverseitig, jetzt auch lokal sichtbar).
            if writingTime.todaySeconds >= 60 {
                Label(t("menu.writingTimeToday", ["time": formattedWritingTime]),
                      systemImage: "clock")
                    .disabled(true)
                Divider()
            }

            // Natives Einstellungen-Fenster (⌘,). `SettingsLink` öffnet die
            // `Settings`-Scene direkt — ohne Selector-Gefrickel.
            SettingsLink {
                Label(t("toolbar.settings"), systemImage: "gearshape")
            }

            Divider()

            // Manueller Sync — sitzt bewusst neben der Sync-Status-Anzeige.
            Button(t("menu.syncNow")) { sync.syncManually() }

            Divider()

            Button(t("general.signOut")) { SignOutConfirmation.run(auth) }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 14))
                .foregroundStyle(BrandColor.muted)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(overflowHover ? BrandColor.faint.opacity(0.25) : .clear)
                )
                .animation(.easeOut(duration: 0.12), value: overflowHover)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { overflowHover = $0 }
        .help(t("toolbar.moreOptions"))
        .accessibilityLabel(t("toolbar.moreOptions"))
    }
}
