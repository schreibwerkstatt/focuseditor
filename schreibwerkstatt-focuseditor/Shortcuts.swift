//
//  Shortcuts.swift
//  schreibwerkstatt-focuseditor
//
//  EINE Quelle für alle Tastaturkürzel, die für den Nutzer im Client greifen —
//  die nativ deklarierten (SwiftUI-Menübefehle) genauso wie die, die der OTA-
//  Editor, macOS oder der Seiten-Picker selbst behandelt.
//
//  Warum ein Katalog: die harte Regel in CLAUDE.md („Tastaturkürzel-Hilfe
//  pflegen") war bis hierher reine Disziplin — die Deklaration stand im
//  App-Menü, die Hilfe listete sie ein zweites Mal von Hand. Genau das ist
//  auseinandergelaufen: ⌘N und ⌘⇧R fehlten in der Hilfe, und das Menü „Buch
//  exportieren" hatte ⌘⇧E belegt, obwohl der Editor damit den Fokus-Modus
//  umschaltet (ein Menü-Kürzel greift VOR der WKWebView — der Fokus-Umschalter
//  war also tot, während die Hilfe ihn weiter bewarb).
//
//  Seitdem gilt: ein Kürzel wird hier eingetragen, `ShortcutsHelpView` rendert
//  die Liste daraus, und die Menüs binden über `.keyboardShortcut(Shortcuts.…)`.
//  `ShortcutCatalogTests` hält beides zusammen und meldet Kollisionen.
//

import SwiftUI

/// Wer das Kürzel tatsächlich behandelt. Entscheidend für Kollisionen: ein
/// `native` Menübefehl fängt die Taste app-weit ab, BEVOR die WebView sie sieht —
/// er verdeckt damit jedes gleichlautende Editor-Kürzel. Zwei nicht-native
/// Einträge dürfen sich dagegen eine Taste teilen, solange sie in verschiedenen
/// Kontexten leben (⎋ schliesst den Picker bzw. verlässt den Fokus-Modus).
enum ShortcutOwner {
    /// SwiftUI-Menübefehl in diesem Client (`.keyboardShortcut(…)`).
    case native
    /// macOS liefert es selbst (Einstellungen, Widerrufen/Wiederherstellen).
    case system
    /// Der gebündelte Focus-Editor behandelt es in der WebView (SSoT Hauptrepo).
    case editor
    /// Der native Seiten-Picker behandelt es, solange er offen ist.
    case picker
}

/// Abschnitt in der Hilfe (Reihenfolge = Anzeigereihenfolge).
enum ShortcutSection: CaseIterable {
    case app, pages, editor

    var titleKey: String {
        switch self {
        case .app:    return "shortcuts.section.app"
        case .pages:  return "shortcuts.section.pages"
        case .editor: return "shortcuts.section.editor"
        }
    }
}

/// Ein Kürzel: Taste + Modifier, wer es behandelt, und der i18n-Key seiner
/// Beschreibung. Die angezeigten Tasten-Capsules werden aus `key`/`modifiers`
/// ABGELEITET (`glyphs`) — sie sind bewusst kein eigenes Feld, sonst wäre die
/// Anzeige die nächste Stelle, die von der Deklaration abdriften kann.
struct ShortcutSpec: Identifiable {
    let id: String
    let key: KeyEquivalent
    let modifiers: EventModifiers
    let labelKey: String
    let section: ShortcutSection
    let owner: ShortcutOwner

    /// Lokalisierte Beschreibung für die Hilfe.
    var label: String { t(labelKey) }

    /// Tasten-Capsules in macOS-Reihenfolge (⌃ ⌥ ⇧ ⌘, dann die Taste).
    var glyphs: [String] {
        var out: [String] = []
        if modifiers.contains(.control) { out.append("⌃") }
        if modifiers.contains(.option)  { out.append("⌥") }
        if modifiers.contains(.shift)   { out.append("⇧") }
        if modifiers.contains(.command) { out.append("⌘") }
        out.append(Self.glyph(for: key))
        return out
    }

    /// Identität für die Kollisionsprüfung — Taste + Modifier, unabhängig davon,
    /// wer sie behandelt.
    var chord: String {
        (glyphs.dropLast() + [String(key.character).uppercased()]).joined()
    }

    private static func glyph(for key: KeyEquivalent) -> String {
        switch key.character {
        case "\r":       return "⏎"
        case "\u{1B}":   return "⎋"
        case "\u{7F}":   return "⌫"
        case "\t":       return "⇥"
        default:         return String(key.character).uppercased()
        }
    }
}

/// Der Katalog. Reihenfolge innerhalb eines Abschnitts = Reihenfolge in der Hilfe.
enum Shortcuts {

    // MARK: - App & Fenster

    static let fullscreen = ShortcutSpec(
        id: "fullscreen", key: "f", modifiers: [.control, .command],
        labelKey: "shortcuts.fullscreen", section: .app, owner: .native)

    /// ⌘S ist in den meisten Apps „Speichern": `syncManually()` flusht darum
    /// zuerst den offenen Draft und stösst erst danach Push/Pull an.
    static let syncNow = ShortcutSpec(
        id: "syncNow", key: "s", modifiers: .command,
        labelKey: "shortcuts.syncNow", section: .app, owner: .native)

    /// Liefert macOS für jede `Settings`-Scene selbst — nicht von uns deklariert,
    /// aber für den Nutzer da, also gehört es in die Hilfe.
    static let openSettings = ShortcutSpec(
        id: "openSettings", key: ",", modifiers: .command,
        labelKey: "shortcuts.openSettings", section: .app, owner: .system)

    static let mainWindow = ShortcutSpec(
        id: "mainWindow", key: "0", modifiers: .command,
        labelKey: "shortcuts.mainWindow", section: .app, owner: .native)

    static let thisHelp = ShortcutSpec(
        id: "thisHelp", key: "?", modifiers: .command,
        labelKey: "shortcuts.thisHelp", section: .app, owner: .native)

    // MARK: - Seiten

    static let newPage = ShortcutSpec(
        id: "newPage", key: "n", modifiers: .command,
        labelKey: "shortcuts.newPage", section: .pages, owner: .native)

    static let openPage = ShortcutSpec(
        id: "openPage", key: "o", modifiers: .command,
        labelKey: "shortcuts.openPage", section: .pages, owner: .native)

    static let revisions = ShortcutSpec(
        id: "revisions", key: "r", modifiers: [.command, .shift],
        labelKey: "shortcuts.revisions", section: .pages, owner: .native)

    static let pickerOpenFirst = ShortcutSpec(
        id: "pickerOpenFirst", key: .return, modifiers: [],
        labelKey: "shortcuts.pickerOpenFirst", section: .pages, owner: .picker)

    static let pickerClose = ShortcutSpec(
        id: "pickerClose", key: .escape, modifiers: [],
        labelKey: "shortcuts.pickerClose", section: .pages, owner: .picker)

    /// Löschen der markierten Zeile (mit Bestätigung). Nur bei leerem Suchfeld:
    /// mit Suchtext bleibt ⌘⌫ das Feld-Kommando „bis Zeilenanfang löschen".
    static let pickerDelete = ShortcutSpec(
        id: "pickerDelete", key: .delete, modifiers: [.command],
        labelKey: "shortcuts.pickerDelete", section: .pages, owner: .picker)

    // MARK: - Editor
    //
    // Die `.editor`-Einträge behandelt der gebündelte Focus-Editor selbst
    // (SSoT Hauptrepo, `public/js/editor/focus/constants.js`). Sie dürfen darum
    // NIE von einem nativen Menübefehl belegt werden — genau das prüft
    // `ShortcutCatalogTests.testNativeShortcutsDoNotShadowOthers()`.

    static let focusToggle = ShortcutSpec(
        id: "focusToggle", key: "e", modifiers: [.command, .shift],
        labelKey: "shortcuts.focusToggle", section: .editor, owner: .editor)

    static let centerLine = ShortcutSpec(
        id: "centerLine", key: "l", modifiers: .command,
        labelKey: "shortcuts.centerLine", section: .editor, owner: .editor)

    static let synonyms = ShortcutSpec(
        id: "synonyms", key: "s", modifiers: [.command, .shift],
        labelKey: "shortcuts.synonyms", section: .editor, owner: .editor)

    // Fett/Kursiv/Unterstrichen sind native Menübefehle, weil das Menü die Taste
    // ohnehin vor der WebView abfängt — die Aktion routet über die Bridge zurück
    // in den Editor (`FormatMenuCommands`).
    static let bold = ShortcutSpec(
        id: "bold", key: "b", modifiers: .command,
        labelKey: "shortcuts.bold", section: .editor, owner: .native)

    static let italic = ShortcutSpec(
        id: "italic", key: "i", modifiers: .command,
        labelKey: "shortcuts.italic", section: .editor, owner: .native)

    static let underline = ShortcutSpec(
        id: "underline", key: "u", modifiers: .command,
        labelKey: "shortcuts.underline", section: .editor, owner: .native)

    /// Widerrufen/Wiederherstellen im Bearbeiten-Menü. `native`, obwohl die
    /// Wirkung im Editor liegt: die Standardeinträge von AppKit sind bewusst
    /// ERSETZT (`CommandGroup(replacing: .undoRedo)`, s. `HistoryMenuCommands`),
    /// weil sie WebKits eigenen Undo-Stack fahren — der fasst im contenteditable
    /// alles seit dem letzten Mausklick zu EINEM Schritt zusammen (gemessen).
    /// Der Menüpunkt routet stattdessen über die Bridge in die entprellte
    /// Snapshot-Historie des gebündelten Editors (SSoT `shared/edit-history.js`)
    /// — und in Textfeldern weiter an AppKit.
    static let undo = ShortcutSpec(
        id: "undo", key: "z", modifiers: .command,
        labelKey: "shortcuts.undo", section: .editor, owner: .native)

    static let redo = ShortcutSpec(
        id: "redo", key: "z", modifiers: [.command, .shift],
        labelKey: "shortcuts.redo", section: .editor, owner: .native)

    static let focusExit = ShortcutSpec(
        id: "focusExit", key: .escape, modifiers: [],
        labelKey: "shortcuts.focusExit", section: .editor, owner: .editor)

    /// Alle Einträge in Anzeigereihenfolge.
    static let all: [ShortcutSpec] = [
        fullscreen, syncNow, openSettings, mainWindow, thisHelp,
        newPage, openPage, revisions, pickerOpenFirst, pickerClose, pickerDelete,
        focusToggle, centerLine, synonyms, bold, italic, underline,
        undo, redo, focusExit,
    ]

    static func inSection(_ section: ShortcutSection) -> [ShortcutSpec] {
        all.filter { $0.section == section }
    }
}

extension View {
    /// Bindet einen Katalog-Eintrag als Menü-Kürzel. Der einzige erlaubte Weg,
    /// im App-Code ein Kürzel zu deklarieren — `ShortcutCatalogTests` schlägt an,
    /// sobald irgendwo wieder ein Literal (`.keyboardShortcut("x", …)`) auftaucht.
    func keyboardShortcut(_ spec: ShortcutSpec) -> some View {
        keyboardShortcut(spec.key, modifiers: spec.modifiers)
    }
}
