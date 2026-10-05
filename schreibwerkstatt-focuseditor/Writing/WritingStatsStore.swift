//
//  WritingStatsStore.swift
//  schreibwerkstatt-focuseditor
//
//  Lebende Schreibstatistik der offenen Seite (Wort-/Zeichenzahl, Lesezeit) und
//  das optionale Schreibziel. Die App fokussiert bewusst auf GENAU EINE Seite
//  (CLAUDE.md, „ablenkungsfreies Schreiben auf genau einer Seite"), darum ist
//  das Ziel pro Seite definiert — gut messbar, kein geräteübergreifendes
//  Baseline-Buchhalten nötig.
//
//  Die Zählung passiert in der WebView (sie kennt den gerenderten Text) und wird
//  über die Bridge-Op `reportStats` an Swift gemeldet — kein direkter DOM-Zugriff
//  aus Swift, kein Editor-Fork. Einstellungen (Anzeige an/aus, Zielwert) sind
//  LOKAL (UserDefaults).
//

import Foundation
import Combine

@MainActor
final class WritingStatsStore: ObservableObject {
    enum Key {
        static let showStats = "writing.showStats"
        static let pageGoal = "writing.pageGoalWords"
        static let dailyBaseline = "writing.dailyBaseline"
    }

    /// Wörter der aktuell offenen Seite (aus der WebView gemeldet).
    @Published private(set) var words: Int = 0
    /// Zeichen (inkl. Leerzeichen) der aktuell offenen Seite.
    @Published private(set) var characters: Int = 0
    /// Heute auf der offenen Seite geschriebene Wörter (Delta zur ersten
    /// Zählung des Tages für diese Seite). Kann beim Löschen negativ werden.
    @Published private(set) var wordsToday: Int = 0
    /// Heute auf der offenen Seite geschriebene Zeichen (Tages-Delta).
    @Published private(set) var charactersToday: Int = 0

    /// Stats-Anzeige in der Toolbar ein-/ausblenden.
    @Published var showStats: Bool {
        didSet { UserDefaults.standard.set(showStats, forKey: Key.showStats) }
    }
    /// Wort-Ziel pro Seite (0 = kein Ziel → keine Fortschrittsanzeige).
    @Published var pageGoalWords: Int {
        didSet { UserDefaults.standard.set(pageGoalWords, forKey: Key.pageGoal) }
    }

    /// Tagesbaseline pro Seite: erster heute gezählter Stand. Differenz dazu =
    /// „heute geschrieben". Wird beim Tageswechsel pro Seite neu gesetzt und
    /// veraltete Einträge (andere Tage) ausgemistet. Persistiert (UserDefaults),
    /// damit „heute" einen App-Neustart innerhalb desselben Tages übersteht.
    /// Spiegelt die Editor-Logik (`focus.dailyBaseline` im Web-Editor).
    private struct DailyBaseline: Codable {
        var date: String
        var words: Int
        var chars: Int
    }
    private var baselines: [String: DailyBaseline] = [:]
    /// Seite der letzten Zählung — ein Sprung ohne Eingabe wird nur dann aus der
    /// Tagesbilanz herausgerechnet, wenn er dieselbe Seite betrifft.
    private var lastReportedPageId: String?

    init() {
        let d = UserDefaults.standard
        showStats = (d.object(forKey: Key.showStats) as? Bool) ?? true
        pageGoalWords = d.integer(forKey: Key.pageGoal)   // Default 0 = aus
        if let data = d.data(forKey: Key.dailyBaseline),
           let decoded = try? JSONDecoder().decode([String: DailyBaseline].self, from: data) {
            // Beim Laden bereits veraltete Tage verwerfen.
            baselines = decoded.filter { $0.value.date == Self.todayKey() }
        }
    }

    /// Geschätzte Lesezeit in Minuten (200 Wörter/Min, min. 1 bei Inhalt).
    var readingMinutes: Int {
        guard words > 0 else { return 0 }
        return max(1, Int((Double(words) / 200.0).rounded()))
    }

    /// Fortschritt zum Seitenziel in [0, 1] — `nil`, wenn kein Ziel gesetzt.
    var goalProgress: Double? {
        guard pageGoalWords > 0 else { return nil }
        return min(1.0, Double(words) / Double(pageGoalWords))
    }

    /// Koppelt den Store an die Bridge: eingehende `reportStats` aktualisieren
    /// die Live-Zahlen + den Tages-Delta. Schwach gehalten — AppCore besitzt die Bridge.
    func attach(to bridge: EditorBridge) {
        bridge.onStats = { [weak self] pageId, words, chars, typed in
            self?.update(pageId: pageId, words: words, chars: chars, typed: typed)
        }
    }

    /// Übernimmt eine neue Zählung der offenen Seite und führt den Tages-Delta
    /// fort. Ohne `pageId` (kein Seitenbezug) bleibt der Tages-Delta bei 0.
    ///
    /// `typed == false` (stiller Server-Refresh derselben Seite): die Änderung
    /// stammt nicht aus diesem Editor. Die Tagesbaseline wandert um genau diesen
    /// Sprung mit, damit „heute geschrieben" unverändert bleibt.
    private func update(pageId: String?, words: Int, chars: Int, typed: Bool) {
        let previous = (pageId: lastReportedPageId, words: self.words, chars: self.characters)
        lastReportedPageId = pageId
        self.words = words
        self.characters = chars

        guard let pageId else {
            wordsToday = 0
            charactersToday = 0
            return
        }

        let today = Self.todayKey()
        var changed = false
        // Veraltete Einträge (andere Tage) lazy ausmisten.
        let pruned = baselines.filter { $0.value.date == today }
        if pruned.count != baselines.count { baselines = pruned; changed = true }

        var base: DailyBaseline
        if let existing = baselines[pageId] {
            base = existing
        } else {
            // Erste Zählung heute für diese Seite → aktueller Stand ist die Basis.
            base = DailyBaseline(date: today, words: words, chars: chars)
            baselines[pageId] = base
            changed = true
        }
        if !typed, previous.pageId == pageId, var shifted = baselines[pageId] {
            shifted.words += words - previous.words
            shifted.chars += chars - previous.chars
            baselines[pageId] = shifted
            base = shifted
            changed = true
        }
        if changed { persistBaselines() }

        wordsToday = words - base.words
        charactersToday = chars - base.chars
    }

    private func persistBaselines() {
        if let data = try? JSONEncoder().encode(baselines) {
            UserDefaults.standard.set(data, forKey: Key.dailyBaseline)
        }
    }

    /// Lokales Tagesdatum als `YYYY-MM-DD` (Schlüssel der Tagesbaseline).
    private static func todayKey() -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
