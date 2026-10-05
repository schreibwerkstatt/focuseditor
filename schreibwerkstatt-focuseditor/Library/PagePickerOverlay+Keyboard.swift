//
//  PagePickerOverlay+Keyboard.swift
//  schreibwerkstatt-focuseditor
//
//  Auswahl-Steuerung des Pickers und das AppKit-Plumbing darunter: Tastatur-Fokus
//  (der `WKWebView` gibt den First Responder nicht freiwillig her), der lokale
//  NSEvent-Monitor für ↑/↓/⏎ und die Hover-Entprellung über die Maus-Position.
//
//  Bewusst getrennt von der Darstellung ([+Rows](PagePickerOverlay+Rows.swift)):
//  hier steckt das plattformnahe Verhalten, dort reines Layout.
//

import SwiftUI
import AppKit

extension PagePickerOverlay {

    // MARK: - Auswahl

    /// Markiert die aktuell geöffnete Seite und scrollt sie ins Bild — damit ein
    /// grosses Buch dort aufgeht, „wo man ist", statt immer oben. Nur ohne aktive
    /// Suche; sobald gefiltert wird, gewinnt der erste Treffer (`onChange(query)`).
    func selectOpenPage() {
        guard query.isEmpty, !filtered.isEmpty else { return }
        if let openId = library.openPageId,
           // Erstes Vorkommen: steht die offene Seite in der Zuletzt-Gruppe (der
           // Normalfall — sie ist die jüngste), bleibt die Liste damit oben und
           // zeigt die Gruppe „Zuletzt geöffnet"; sonst wird ihre Zeile im
           // Kapitelbaum angesteuert.
           let entry = filtered.first(where: { $0.row.id == openId }) {
            selected = entry.index
            requestScroll(to: entry.key)   // RowKey (Scroll-Identität), nicht der Index
        } else {
            // Offene Seite gehört nicht in dieses Buch (Buchwechsel) oder es ist
            // keine offen → auf die erste Zeile, statt auf einer veralteten Scroll-
            // Identität des alten Buchs hängenzubleiben (Liste bliebe sonst oben).
            selected = 0
            requestScroll(to: filtered.first?.key)
        }
    }

    /// Öffnet die aktuell markierte Zeile (Tastatur/Hover); fällt auf den ersten
    /// Treffer zurück, falls der Index durch eine neue Filterung verrutscht ist.
    func openSelected() {
        guard !filtered.isEmpty else { return }
        let entry = filtered.indices.contains(selected) ? filtered[selected] : filtered[0]
        open(entry.row)
    }

    /// Bewegt die Markierung um `delta`, begrenzt auf die Trefferliste.
    func moveSelection(_ delta: Int) {
        guard !filtered.isEmpty else { return }
        selected = max(0, min(filtered.count - 1, selected + delta))
        requestScroll(to: filtered[selected].key)   // RowKey; nur Tastatur-Nav scrollt mit
    }

    /// Hover auf einer Zeile → Markierung nachziehen, aber nur bei ECHTER
    /// Mausbewegung. Beim Scrollen ruht der Cursor, während die Zeilen unter ihm
    /// durchrutschen → `onHover` feuert reihenweise mit GLEICHER `mouseLocation`.
    /// Würde das `selected` setzen, wanderte die Markierung flackernd durch die
    /// Liste (sichtbar genau beim Scrollen). Position unverändert → ignorieren.
    func handleHover(_ entry: IndexedRow, hovering: Bool) {
        guard hovering else { return }
        let loc = NSEvent.mouseLocation
        guard loc != lastHoverLocation else { return }
        lastHoverLocation = loc
        selected = entry.index
    }

    // MARK: - Tastatur

    /// Holt den Tastatur-Fokus aufs Suchfeld. Der Editor-`WKWebView` klammert sich
    /// an den First Responder des Fensters; setzt man `searchFocused` nur synchron
    /// im `onAppear`, gewinnt die WebView und man tippt weiter auf der Seite statt
    /// ins Feld. Darum: WebView-First-Responder zuerst lösen (`makeFirstResponder(nil)`),
    /// dann den Fokus DEFERRED setzen — das Suchfeld ist erst im nächsten Runloop
    /// fertig in der Responder-Kette.
    func focusSearchField() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        DispatchQueue.main.async { searchFocused = true }
    }

    /// Fängt ↑/↓/⏎ ab, solange das Overlay offen ist. Das Suchfeld behält den
    /// Fokus fürs Tippen; die Pfeiltasten steuern die Auswahl statt den Cursor.
    ///
    /// Ein lokaler Monitor sieht die Tasten ALLER Fenster der App. Darum nur im
    /// Fenster des Pickers und nur ohne angehängtes Sheet eingreifen — sonst
    /// öffnete ⏎ im Namensfeld von „Neue Seite …" (⌘N) oder im Einstellungen-
    /// Fenster die markierte Seite, statt das Sheet bzw. Feld zu bedienen.
    func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        weak let pickerWindow = NSApp.keyWindow ?? NSApp.mainWindow
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let window = event.window, window === pickerWindow,
                  window.attachedSheet == nil else { return event }
            switch event.keyCode {
            case 125: moveSelection(1);  return nil   // ↓
            case 126: moveSelection(-1); return nil   // ↑
            case 36, 76: openSelected(); return nil   // ⏎ / Enter
            default: return event
            }
        }
    }

    func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }
}
