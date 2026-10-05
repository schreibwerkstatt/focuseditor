//
//  ServerNamespace.swift
//  schreibwerkstatt-focuseditor
//
//  Per-Server-Namespacing der lokalen Persistenz. Der lokale Spiegel
//  (SQLite), der Sync-Zustand (Cursor/Basen/Buch-IDs) und die Buchauswahl
//  gehören zu GENAU EINEM Server — sonst pollt der Client nach einem
//  Server-Wechsel (localhost → prod) die Buch-IDs des alten Servers gegen
//  den neuen (→ `NO_BOOK_ACCESS`-Flut im Server-Log). Jeder Server bekommt
//  darum sein eigenes Unterverzeichnis; ein Wechsel lädt den passenden
//  Namespace (und behält den alten, falls man zurückwechselt).
//

import Foundation

/// Leitet einen stabilen, dateisystem-sicheren Slug aus der Server-Basis-URL
/// ab. Scheme + Host + Port (+ Pfad) unterscheiden Server (`http://127.0.0.1:3737`
/// ist ein anderer Bestand als `https://prod`).
///
/// Eindeutigkeit: die Grundform bildet Punkte auf `-` ab. Für Hosts ohne `-`/`_`
/// und ohne Pfad ist das eindeutig — sie behalten die Grundform (alle bisher
/// bekannten Server, keine Migration). Sonst teilten sich `a-b.example.com` und
/// `a.b.example.com` (bzw. zwei Server unter verschiedenen Pfaden desselben
/// Hosts) Spiegel, Sync-Zustand und den Purge der Konto-Löschung. Diese Fälle
/// bekommen einen Hash-Zusatz `_h<8 hex>`; ein Bestand unter der alten
/// Grundform wird beim ersten Zugriff einmalig umgezogen (s. `migrate`).
enum ServerNamespace {
    /// Slug der aktuell konfigurierten Server-Basis-URL.
    static var currentSlug: String { slug(for: ServerConfig.baseURL) }

    /// Slug für eine konkrete URL. `nil`/ohne Host → `"default"` (defensiver
    /// Fallback, damit nie ein leerer Pfadbestandteil entsteht).
    static func slug(for url: URL?) -> String {
        guard let url, let host = url.host, !host.isEmpty else { return "default" }
        let legacy = legacySlug(for: url, host: host)
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let ambiguous = host.contains("-") || host.contains("_") || !path.isEmpty
        guard ambiguous else { return legacy }
        let identity = "\((url.scheme ?? "http").lowercased())://\(host.lowercased())"
            + (url.port.map { ":\($0)" } ?? "") + "/" + path
        let slug = legacy + "_h" + shortHash(identity)
        migrate(from: legacy, to: slug)
        return slug
    }

    /// Die bisherige Grundform (`scheme_host[_port]`, Punkte → `-`).
    private static func legacySlug(for url: URL, host: String) -> String {
        let scheme = (url.scheme ?? "http").lowercased()
        let port = url.port.map { "_\($0)" } ?? ""
        let raw = "\(scheme)_\(host)\(port)".lowercased()
        // Auf [a-z0-9_-] reduzieren (Punkte aus IP/Hostname → `-`).
        let safe = String(raw.map { c in
            (c.isLetter || c.isNumber || c == "_" || c == "-") ? c : "-"
        })
        return safe.isEmpty ? "default" : safe
    }

    /// FNV-1a (64 Bit) → 8 Hex-Zeichen. Stabil über App-Starts und -Versionen
    /// (anders als `Hasher`, der pro Prozess zufällig gesalzen ist).
    private static func shortHash(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for byte in s.utf8 {
            h ^= UInt64(byte)
            h = h &* 0x100000001b3
        }
        return String(format: "%08x", UInt32(truncatingIfNeeded: h ^ (h >> 32)))
    }

    /// Schon geprüfte Ziel-Slugs dieses Prozesses (die Migration läuft je Slug
    /// höchstens einmal — `currentSlug` wird sehr oft gelesen).
    private static var migrationChecked: Set<String> = []

    /// Einmaliger Umzug eines Bestands von der alten Grundform auf den
    /// eindeutigen Slug: Ordner `servers/<legacy>/` und die Defaults-Schlüssel
    /// `….<legacy>`. Nur, wenn am Ziel noch nichts liegt — ein vorhandener
    /// Bestand wird nie überschrieben. Läuft vor dem ersten Öffnen der DB, weil
    /// jeder Pfad dorthin erst den Slug berechnet.
    private static func migrate(from legacy: String, to slug: String) {
        guard migrationChecked.insert(slug).inserted else { return }
        let fm = FileManager.default
        let servers = AppSupport.baseDir().appendingPathComponent("servers", isDirectory: true)
        let from = servers.appendingPathComponent(legacy, isDirectory: true)
        let to = servers.appendingPathComponent(slug, isDirectory: true)
        guard fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) else { return }
        do {
            try fm.moveItem(at: from, to: to)
        } catch {
            return   // nichts halb umziehen: ohne Ordner auch keine Schlüssel
        }
        let defaults = UserDefaults.standard
        let suffix = "." + legacy
        for (key, value) in defaults.dictionaryRepresentation() where key.hasSuffix(suffix) {
            let newKey = String(key.dropLast(suffix.count)) + "." + slug
            if defaults.object(forKey: newKey) == nil { defaults.set(value, forKey: newKey) }
            defaults.removeObject(forKey: key)
        }
    }
}

/// Gemeinsame Pfad-Hilfen für das Application-Support-Verzeichnis. Bündelt die
/// bislang in jedem Store duplizierte Verzeichnis-Ableitung und ergänzt das
/// Per-Server-Unterverzeichnis (`servers/<slug>/`).
enum AppSupport {
    /// `~/Library/Application Support/schreibwerkstatt-focuseditor` (angelegt).
    static func baseDir() -> URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory,
                                in: .userDomainMask,
                                appropriateFor: nil,
                                create: true))
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("schreibwerkstatt-focuseditor", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Per-Server-Verzeichnis `…/servers/<slug>/` (angelegt).
    static func serverDir(slug: String = ServerNamespace.currentSlug) -> URL {
        let dir = baseDir()
            .appendingPathComponent("servers", isDirectory: true)
            .appendingPathComponent(slug, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Einmalige Migration: ein bislang global (top-level) abgelegtes File in den
    /// Namespace des aktuell konfigurierten Servers verschieben — aber nur, wenn
    /// dort noch keins liegt. So gehen die Inhalte des bisherigen (einzigen)
    /// Servers nicht verloren. Verschiebt SQLite-Sidecars (`-wal`/`-shm`) mit.
    static func migrateLegacyFileIfNeeded(named name: String,
                                          into slug: String = ServerNamespace.currentSlug) {
        let fm = FileManager.default
        let target = serverDir(slug: slug).appendingPathComponent(name)
        guard !fm.fileExists(atPath: target.path) else { return }
        let legacy = baseDir().appendingPathComponent(name)
        guard fm.fileExists(atPath: legacy.path) else { return }
        // ZUERST die Hauptdatei verschieben. Scheitert das, GAR NICHTS anfassen —
        // sonst landete ein verwaistes `-wal`/`-shm` ohne Hauptdatei im Ziel und
        // GRDB öffnete dort eine inkonsistente DB (halbe Migration).
        do {
            try fm.moveItem(at: legacy, to: target)
        } catch {
            return
        }
        // Hauptdatei ist drüben → die SQLite-Sidecars best-effort nachziehen.
        for suffix in ["-wal", "-shm"] {
            let from = baseDir().appendingPathComponent(name + suffix)
            let to = serverDir(slug: slug).appendingPathComponent(name + suffix)
            guard fm.fileExists(atPath: from.path) else { continue }
            try? fm.moveItem(at: from, to: to)
        }
    }
}
