//
//  AppLog.swift
//  schreibwerkstatt-focuseditor
//
//  Die Logger der App an einer Stelle. Vorher stand das Subsystem
//  `ch.schreibwerkstatt.focuseditor` als Literal in dreizehn Dateien — ein
//  Tippfehler darin lässt die Meldungen einer Datei still aus `log stream
//  --subsystem …` verschwinden, und die Kategorien liessen sich nirgends
//  überblicken.
//
//  Die Kategorien entsprechen den Verantwortungsbereichen aus
//  [ARCHITECTURE.md](../ARCHITECTURE.md); eine neue kommt hier dazu, nicht als
//  weiteres Literal an der Verwendungsstelle.
//

import os

enum AppLog {
    /// Muss zur Bundle-ID passen, damit `log stream --subsystem …` greift.
    static let subsystem = "ch.schreibwerkstatt.focuseditor"

    private static func make(_ category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }

    /// Konto-Löschung (`DELETE /me/account`).
    static let account = make("account")
    /// WebView-Bridge (auch der Kanal für die `log`-Op der WebView).
    static let bridge = make("bridge")
    /// OTA-Lader des Editor-Bundles (Download, Vertrags-Major).
    static let editorBundle = make("editor-bundle")
    /// Buch-Export als Markdown.
    static let export = make("export")
    /// Serverseitiges Seiten-Lektorat.
    static let lektorat = make("lektorat")
    /// Buch-/Seitenauswahl.
    static let library = make("library")
    /// Seiten anlegen/umbenennen/löschen.
    static let pageAdmin = make("pageadmin")
    /// Lokales Aufräumen nach bestätigter Konto-Löschung.
    static let purge = make("purge")
    /// Frühere Fassungen einer Seite.
    static let revisions = make("revisions")
    /// Lokaler Spiegel (GRDB/SQLite).
    static let store = make("store")
    /// Sync-Durchläufe (Push/Pull/Reconcile).
    static let sync = make("sync")
    /// Persistierter Sync-Zustand (Cursor/Basen/Konflikte).
    static let syncState = make("syncstate")
    /// Schreibzeit-Heartbeat.
    static let writingTime = make("writing-time")
}
