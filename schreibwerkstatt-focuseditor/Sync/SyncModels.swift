//
//  SyncModels.swift
//  schreibwerkstatt-focuseditor
//
//  Netzwerk-DTOs für den inkrementellen Sync — exakt nach Server-Vertrag
//  (routes/content.js + lib/content-store/backends/localdb.js im Hauptrepo).
//
//  Wichtig: Der Server vergleicht `expected_updated_at` atomar als String
//  (`WHERE updated_at = ?`). Die exakte ISO-Zeichenkette des Servers MUSS
//  unverändert zurückgeschickt werden — niemals aus Epoch-ms rekonstruiert.
//

import Foundation

// MARK: - Pull

/// Buch aus `GET /content/books`. Buch-ID heißt serverseitig `id`.
struct BookDTO: Decodable {
    let id: Int
    let name: String?
    let slug: String?
}

/// Eine Seite aus `GET /content/books/:id/sync`. Seiten-ID heißt hier `page_id`.
struct SyncPageDTO: Decodable {
    let page_id: Int
    let page_name: String?
    let chapter_id: Int?
    /// ISO-8601 mit Millis + Z. Optional, weil der Server in Randfällen
    /// (unsaubere/leere Seite) `null` liefert — solche Seiten sind ohne Basis
    /// kein gültiger Sync-Stand und werden übersprungen, statt den ganzen
    /// Batch-Decode (und damit den kompletten Sync) zu killen.
    let updated_at: String?
    /// Defensiv optional: eine einzelne `null`-Seite darf den Array-Decode
    /// nicht scheitern lassen.
    let html: String?
}

/// Keyset-Cursor `{ since, since_id }`.
struct SyncCursorDTO: Codable, Equatable, Sendable {
    let since: String?       // ISO-8601 oder null (Voll-Pull)
    let since_id: Int
}

/// Antwort von `GET /content/books/:id/sync`.
struct BookSyncResponse: Decodable {
    let now: String
    let pages: [SyncPageDTO]
    let has_more: Bool
    let cursor: SyncCursorDTO
}

// MARK: - Push

/// Body für `PUT /content/pages/:id`. Wir senden HTML + Concurrency-Guard +
/// Herkunfts-Marker; `expected_updated_at` ist die exakte Server-ISO-Basis
/// (nil → unbedingtes Update, vermeiden wir bewusst, siehe SyncEngine).
/// `source` markiert die Revision serverseitig als Mac-App-Edit
/// (db/page-revisions.js#VALID_SOURCES). `device_id` ist die stabile Geräte-UUID
/// (DeviceIdentity) — der Server stempelt damit `pages.last_editor_device_id` und
/// registriert das Gerät als Buch-Präsenz, sodass ein parallel offener Browser
/// diesen Push als Remote-Change erkennt und die Seite automatisch nachlädt.
///
/// `save_id`/`own_save_ids` (Save-Kennung, s. `OutboxEntry`): nur reguläre
/// Outbox-Pushs setzen sie; `nil` lässt das Feld weg. Ein Server ohne das
/// Feature ignoriert beide.
struct PushRequest: Encodable {
    let html: String
    let expected_updated_at: String?
    var source: String = "macapp"
    var device_id: String = DeviceIdentity.current
    var save_id: String?
    var own_save_ids: [String]?
}

/// 200-Antwort von `PUT /content/pages/:id`. Seiten-ID heißt hier `id`.
struct PushResponse: Decodable {
    let id: Int
    let updated_at: String
    let name: String?
    let html: String?
    // Buch-/Kapitel-Zuordnung: optional, weil `GET /content/pages/:id` sie
    // (noch) nicht zwingend liefert. Sobald der Server sie mitschickt, setzt das
    // Bridge-Nachladen das Buch sofort — sonst trägt der Reconcile-Backfill es
    // über den Buch-Tree nach (LocalStore.assignBook). Siehe CLAUDE.md.
    let book_id: Int?
    let chapter_id: Int?
    /// Kennung des letzten Writes (`GET`); `null` nach einem Write ohne Kennung
    /// (anderes Gerät, Web, Job). Fehlt bei einem Server ohne das Feature.
    var last_save_id: String?
    /// Nur in der PUT-Antwort: `"replay"` (Wiederholung, nichts geschrieben) oder
    /// `"own"` (veralteter Stempel, aber die letzte Kennung war unsere).
    var save_match: String?
    /// Nur in der PUT-Antwort auf einen Push MIT `base_html`: der Server hat
    /// blockweise gemergt, `html` ist der neue Stand. Der Mac schickt
    /// `base_html` nicht (er mergt selbst per `merge3`) — das Feld ist nur
    /// bekannt, damit der Vertrag vollständig dekodiert.
    var merged: Bool?
}

/// 409-Body `PAGE_CONFLICT`.
struct ConflictBody: Decodable {
    let error_code: String?
    let server_updated_at: String?
    let server_editor_email: String?
    let server_editor_name: String?
    /// Nur bei einem Push MIT `base_html`: `data-bid` der kollidierenden Blöcke.
    /// Der Mac schickt `base_html` nicht; bekannt nur für den Vertrag.
    var merge_conflicts: [String]?
}

/// 423-Body `PAGE_LOCKED`.
struct LockBody: Decodable {
    let error_code: String?
    let locked_by_email: String?
    let expires_at: String?
}

// MARK: - ISO-Zeit

/// Konvertierung zwischen Server-ISO-Strings und Epoch-Millisekunden (Double),
/// der lokalen Store-/WebView-Einheit. Nur für die LOKALE Basis nötig — die
/// Server-Basis (`expected_updated_at`) bleibt immer der originale ISO-String.
enum ISOTime {
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func date(_ s: String) -> Date? {
        withFraction.date(from: s) ?? plain.date(from: s)
    }

    /// ISO → Epoch-ms (Double), oder nil bei Parse-Fehler.
    static func millis(_ s: String) -> Double? {
        date(s).map { $0.timeIntervalSince1970 * 1000 }
    }
}
