//
//  MiniZip.swift
//  schreibwerkstatt-focuseditor
//
//  Minimaler, abhängigkeitsfreier ZIP-Entpacker für das OTA-Editor-Bundle
//  (GET /content/editor-bundle.zip, JSZip/DEFLATE). Die App läuft im App-Sandbox
//  → kein `Process`/`unzip`, und Foundation hat keinen ZIP-Reader. Statt einer
//  SPM-Dependency (ZIPFoundation) parsen wir das Central Directory selbst und
//  inflaten DEFLATE über das bordeigene `Compression`-Framework.
//
//  Bewusst minimal und auf unser eigenes, kontrolliertes ZIP zugeschnitten:
//   • liest Größen/Offsets aus dem Central Directory (robust gegen
//     Data-Descriptors, bei denen der Local-Header Nullgrößen trägt),
//   • unterstützt „stored" (0) und „deflate" (8) — was JSZip erzeugt,
//   • kein ZIP64 (Bundle ist klein; 0xFFFFFFFF-Marker → Fehler statt Fehlinterpret.),
//   • Deckel für Anzahl Einträge, Eintrags- und Gesamtgrösse (die Grössen aus
//     dem Central Directory werden VOR der Allokation geprüft — sonst legte ein
//     kaputtes ZIP bis zu 4 GiB je Eintrag an),
//   • CRC-32 je Eintrag (ein auf dem Transport beschädigtes Bundle wird
//     abgelehnt, statt mit kaputtem JS installiert und per ETag festgehalten).
//
//  `nonisolated`: läuft abseits des Main Threads (EditorBundleStore entpackt im
//  Hintergrund, damit das Schreiben nicht stockt).
//

import Foundation
import Compression

nonisolated enum MiniZipError: Error {
    case notAZip                 // EOCD nicht gefunden
    case malformed(String)       // Header-/Offset-Inkonsistenz
    case unsupported(String)     // ZIP64 / unbekannte Kompression
    case inflateFailed(String)   // DEFLATE-Dekompression fehlgeschlagen
    case tooLarge(String)        // Deckel überschritten (Anzahl/Grösse)
    case checksumMismatch(String) // CRC-32 passt nicht
}

nonisolated enum MiniZip {

    /// Ein entpackter Eintrag: relativer POSIX-Pfad + roher Inhalt.
    struct Entry: Sendable {
        let path: String
        let data: Data
    }

    /// Obergrenzen gegen kaputte oder manipulierte Archive. Das echte Bundle
    /// liegt weit darunter (wenige MB, einige hundert Dateien).
    struct Limits: Sendable {
        var maxEntries: Int
        var maxEntrySize: Int
        var maxTotalSize: Int

        static let editorBundle = Limits(maxEntries: 5_000,
                                         maxEntrySize: 16 * 1024 * 1024,
                                         maxTotalSize: 96 * 1024 * 1024)
    }

    // ── Signaturen ───────────────────────────────────────────────────────────
    private static let eocdSig: UInt32 = 0x0605_4b50   // PK\x05\x06
    private static let cdSig: UInt32    = 0x0201_4b50   // PK\x01\x02
    private static let lfhSig: UInt32   = 0x0403_4b50   // PK\x03\x04

    /// Entpackt alle Dateieinträge eines ZIP-Puffers. Verzeichniseinträge
    /// (Pfad endet auf „/") werden übersprungen.
    static func entries(in input: Data, limits: Limits = .editorBundle) throws -> [Entry] {
        // Auf startIndex 0 normalisieren: der Parser rechnet durchgängig mit
        // absoluten Offsets (Slices aus URLSession sind i. d. R. schon 0-basiert).
        let data = input.startIndex == 0 ? input : Data(input)
        let eocd = try findEOCD(in: data)
        let total = readU16(data, eocd + 10)
        let cdOffset = Int(readU32(data, eocd + 16))
        guard cdOffset < data.count else { throw MiniZipError.malformed("CD-Offset außerhalb") }
        guard Int(total) <= limits.maxEntries else {
            throw MiniZipError.tooLarge("\(total) Einträge (max. \(limits.maxEntries))")
        }

        var out: [Entry] = []
        var totalSize = 0
        var p = cdOffset
        for _ in 0..<total {
            guard p + 46 <= data.count, readU32(data, p) == cdSig else {
                throw MiniZipError.malformed("Central-Directory-Header erwartet @\(p)")
            }
            let method   = readU16(data, p + 10)
            let crc      = readU32(data, p + 16)
            let compSize = readU32(data, p + 20)
            let rawSize  = readU32(data, p + 24)
            let nameLen  = Int(readU16(data, p + 28))
            let extraLen = Int(readU16(data, p + 30))
            let commLen  = Int(readU16(data, p + 32))
            let lhOffset = Int(readU32(data, p + 42))

            if compSize == 0xFFFF_FFFF || rawSize == 0xFFFF_FFFF || lhOffset == 0xFFFF_FFFF {
                throw MiniZipError.unsupported("ZIP64 nicht unterstützt")
            }

            let nameRange = (p + 46)..<(p + 46 + nameLen)
            guard nameRange.upperBound <= data.count else { throw MiniZipError.malformed("Name-Bereich") }
            let name = String(decoding: data[nameRange], as: UTF8.self)

            if !name.hasSuffix("/") {
                // Grössen VOR dem Entpacken prüfen (Allokation folgt rawSize).
                guard Int(rawSize) <= limits.maxEntrySize else {
                    throw MiniZipError.tooLarge("\(name): \(rawSize) Byte (max. \(limits.maxEntrySize))")
                }
                totalSize += Int(rawSize)
                guard totalSize <= limits.maxTotalSize else {
                    throw MiniZipError.tooLarge("Gesamtgrösse über \(limits.maxTotalSize) Byte")
                }
                let raw = try extractPayload(data, localHeaderOffset: lhOffset,
                                             method: method,
                                             compressedSize: Int(compSize),
                                             uncompressedSize: Int(rawSize))
                guard CRC32.checksum(raw) == crc else {
                    throw MiniZipError.checksumMismatch(name)
                }
                out.append(Entry(path: name, data: raw))
            }

            p += 46 + nameLen + extraLen + commLen
        }
        return out
    }

    // ── Intern ────────────────────────────────────────────────────────────────

    /// Liest die komprimierten Bytes ab dem Local-File-Header und entpackt sie.
    /// Die Daten-Startposition wird aus dem LOCAL-Header berechnet (dessen
    /// name/extra-Längen können von denen im Central Directory abweichen).
    private static func extractPayload(_ data: Data,
                                       localHeaderOffset: Int,
                                       method: UInt16,
                                       compressedSize: Int,
                                       uncompressedSize: Int) throws -> Data {
        guard localHeaderOffset + 30 <= data.count, readU32(data, localHeaderOffset) == lfhSig else {
            throw MiniZipError.malformed("Local-File-Header erwartet @\(localHeaderOffset)")
        }
        let nameLen  = Int(readU16(data, localHeaderOffset + 26))
        let extraLen = Int(readU16(data, localHeaderOffset + 28))
        let start = localHeaderOffset + 30 + nameLen + extraLen
        let end = start + compressedSize
        guard end <= data.count else { throw MiniZipError.malformed("Nutzdaten außerhalb") }
        let comp = data.subdata(in: start..<end)

        switch method {
        case 0:  // stored
            guard compressedSize == uncompressedSize else {
                throw MiniZipError.malformed("stored: Grössen weichen ab")
            }
            return comp
        case 8:  // deflate (raw, RFC 1951) — Apples COMPRESSION_ZLIB ist genau das
            return try inflate(comp, expectedSize: uncompressedSize)
        default:
            throw MiniZipError.unsupported("Kompressionsmethode \(method)")
        }
    }

    /// Raw-DEFLATE-Dekompression in einen Puffer bekannter Größe.
    private static func inflate(_ comp: Data, expectedSize: Int) throws -> Data {
        if expectedSize == 0 { return Data() }
        // Komprimierte Bytes erwartet, aber `comp` ist leer (manipuliertes/korruptes
        // ZIP: rawSize>0, compSize=0) → sauber werfen statt `baseAddress!` zu
        // force-unwrappen (das würde crashen).
        guard !comp.isEmpty else {
            throw MiniZipError.inflateFailed("keine komprimierten Daten, aber \(expectedSize) Byte erwartet")
        }
        var dst = Data(count: expectedSize)
        let written = dst.withUnsafeMutableBytes { dstRaw -> Int in
            comp.withUnsafeBytes { srcRaw -> Int in
                guard let dstBase = dstRaw.bindMemory(to: UInt8.self).baseAddress,
                      let srcBase = srcRaw.bindMemory(to: UInt8.self).baseAddress else {
                    return 0
                }
                return compression_decode_buffer(
                    dstBase, expectedSize,
                    srcBase, comp.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        guard written == expectedSize else {
            throw MiniZipError.inflateFailed("erwartet \(expectedSize), erhalten \(written)")
        }
        return dst
    }

    /// Sucht das End-of-Central-Directory rückwärts (es kann ein Kommentar von
    /// bis zu 65535 Bytes folgen). Liefert den Offset der EOCD-Signatur.
    private static func findEOCD(in data: Data) throws -> Int {
        let minSize = 22
        guard data.count >= minSize else { throw MiniZipError.notAZip }
        let maxBack = min(data.count, minSize + 0xFFFF)
        var i = data.count - minSize
        let lowest = data.count - maxBack
        while i >= lowest {
            if readU32(data, i) == eocdSig { return i }
            i -= 1
        }
        throw MiniZipError.notAZip
    }

    // Little-Endian-Leser (ZIP ist durchgängig LE).
    private static func readU16(_ d: Data, _ o: Int) -> UInt16 {
        let b = d.startIndex + o
        return UInt16(d[b]) | (UInt16(d[b + 1]) << 8)
    }
    private static func readU32(_ d: Data, _ o: Int) -> UInt32 {
        let b = d.startIndex + o
        return UInt32(d[b]) | (UInt32(d[b + 1]) << 8) | (UInt32(d[b + 2]) << 16) | (UInt32(d[b + 3]) << 24)
    }
}

/// CRC-32 (IEEE 802.3, wie ZIP/zlib), tabellengestützt.
nonisolated enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { raw in
            for byte in raw.bindMemory(to: UInt8.self) {
                crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}
