//
//  ConflictDiff.swift
//  schreibwerkstatt-focuseditor
//
//  Reiner, dependency-freier Diff-Helfer für die Konflikt-Auflösung. Wandelt das
//  HTML zweier Stände (lokal vs. Server) in lesbare Absätze und markiert pro
//  Spalte die Absätze, die auf der jeweils anderen Seite fehlen — die visuelle
//  Grundlage für die Nebeneinander-Ansicht in `ConflictResolutionView`.
//
//  Bewusst KEIN NSAttributedString-HTML-Parsing: das ist OS-versionsabhängig
//  (nicht deterministisch testbar) und braucht WebKit/Main-Thread. Der schlanke
//  Tag-Stripper hier ist deterministisch und damit unit-testbar.
//

import Foundation

/// Ein Absatz in einer der beiden Diff-Spalten. `changed == true` heißt: dieser
/// Absatz kommt auf der gegenüberliegenden Seite nicht (gleich) vor.
struct DiffParagraph: Identifiable, Equatable {
    let id: Int
    let text: String
    let changed: Bool
}

/// HTML → lesbare Absätze. Block-Enden (`</p>`, Überschriften, `<li>`, `<br>` …)
/// werden zu Absatzgrenzen; restliche Tags fallen weg, ein paar Entities werden
/// dekodiert. `data-bid`-Attribute o. Ä. interessieren hier nicht — es geht nur
/// um den lesbaren Text für den Vergleich, nicht um die Speicherform.
enum ConflictText {
    private static let blockClose = [
        "</p>", "</h1>", "</h2>", "</h3>", "</h4>", "</h5>", "</h6>",
        "</li>", "</blockquote>", "</div>", "</pre>",
    ]

    /// Sichtbarer Platzhalter für eine Trennlinie (`<hr>`). Ohne ihn fiele die
    /// Linie beim Tag-Strippen spurlos weg — ein Konflikt, der nur eine Linie
    /// einfügt oder entfernt, sähe in beiden Spalten identisch aus. Typografisches
    /// Zeichen (Szenentrenner), kein Wort → nicht lokalisiert.
    static let ruleMarker = "* * *"

    static func paragraphs(fromHTML html: String) -> [String] {
        // `<hr>` trägt Attribute (`data-bid`, …) und ist leer → als eigener Absatz
        // VOR dem Tag-Strippen einsetzen; die Zeilenumbrüche machen ihn zur Grenze.
        var s = html.replacingOccurrences(of: "<hr\\b[^>]*>", with: "\n\(ruleMarker)\n",
                                          options: [.regularExpression, .caseInsensitive])
        for br in ["<br>", "<br/>", "<br />"] {
            s = s.replacingOccurrences(of: br, with: "\n", options: .caseInsensitive)
        }
        for tag in blockClose {
            s = s.replacingOccurrences(of: tag, with: "\n", options: .caseInsensitive)
        }
        s = stripTags(s)
        s = decodeEntities(s)
        return s.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func stripTags(_ s: String) -> String {
        var out = ""
        var inTag = false
        for ch in s {
            if ch == "<" { inTag = true; continue }
            if ch == ">" { inTag = false; continue }
            if !inTag { out.append(ch) }
        }
        return out
    }

    private static func decodeEntities(_ s: String) -> String {
        var r = s
        let map = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">",
                   "&quot;": "\"", "&#39;": "'", "&apos;": "'"]
        for (k, v) in map { r = r.replacingOccurrences(of: k, with: v) }
        return r
    }
}

/// Absatzweiser Vergleich über `CollectionDifference` (LCS). Markiert in der
/// lokalen Spalte die Einfügungen (nur lokal vorhanden) und in der Server-Spalte
/// die Entfernungen (nur serverseitig vorhanden). Die Spalten sind NICHT
/// zeilensynchron ausgerichtet — jede hebt nur ihre eigenen Unterschiede hervor;
/// das reicht, um „was ist hier anders" auf einen Blick zu sehen.
enum ConflictDiff {
    static func compare(local: [String], server: [String])
        -> (local: [DiffParagraph], server: [DiffParagraph]) {
        let diff = local.difference(from: server)
        var insertedLocal = Set<Int>()
        var removedServer = Set<Int>()
        for change in diff {
            switch change {
            case let .insert(offset, _, _): insertedLocal.insert(offset)
            case let .remove(offset, _, _): removedServer.insert(offset)
            }
        }
        let localOut = local.enumerated().map {
            DiffParagraph(id: $0.offset, text: $0.element, changed: insertedLocal.contains($0.offset))
        }
        let serverOut = server.enumerated().map {
            DiffParagraph(id: $0.offset, text: $0.element, changed: removedServer.contains($0.offset))
        }
        return (localOut, serverOut)
    }
}
