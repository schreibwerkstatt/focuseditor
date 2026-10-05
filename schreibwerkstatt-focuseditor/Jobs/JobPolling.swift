//
//  JobPolling.swift
//  schreibwerkstatt-focuseditor
//
//  Warten auf einen Server-Job (`GET /jobs/:id`), bis er terminal ist.
//
//  Der Server führt mehrere Job-Arten über dieselbe Queue (Lektorat, KI-
//  Synonyme, …) und antwortet für alle gleich: `status` (`queued`/`running`/
//  `done`/`error`/`cancelled`), optional `progress`, bei Erfolg `result`. Die
//  zwei Aufrufer im Client hatten diese Schleife darum je einmal nachgebaut —
//  inklusive Percent-Encoding der Job-ID, Deckel, „transienten Lesefehler
//  überspringen" und der Sonderbehandlung von `status == nil`.
//
//  Bewusst NICHT hier: was ein Ergebnis bedeutet. Der Lektorats-Store zählt
//  Beanstandungen, der Synonym-Proxy liest eine Wortliste — beide bekommen ihr
//  `result` typisiert zurück und deuten es selbst.
//

import Foundation

// `nonisolated` an den Typen: das Projekt baut mit MainActor-Default-Isolation,
// sonst wären die `Decodable`/`Sendable`-Conformances MainActor-isoliert und
// taugten nicht als generische Sendable-Parameter (derselbe Grund wie bei den
// GRDB-Records im Store).

/// Ausgang eines gepollten Jobs.
nonisolated enum JobOutcome<Result: Decodable & Sendable>: Sendable {
    /// Terminal erfolgreich. `result` fehlt, wenn der Server keins mitgab.
    case done(Result?)
    /// Terminal fehlgeschlagen oder storniert. `code` ist der rohe Serverwert —
    /// ein i18n-Key des SERVER-Katalogs, nicht der mac-Kataloge: nur loggen,
    /// dem Nutzer eine eigene Meldung zeigen.
    case failed(code: String?)
    /// Deckel erreicht, ohne dass der Job terminal wurde. Der Job läuft
    /// serverseitig weiter — nur unser Warten endet.
    case timedOut
}

/// Antwortform von `GET /jobs/:id`, generisch über den Ergebnis-Teil.
nonisolated struct JobStatusEnvelope<Result: Decodable & Sendable>: Decodable, Sendable {
    let status: String?
    let progress: Int?
    let result: Result?
    let error: String?
}

enum JobPolling {

    /// Pollt `GET /jobs/:id`, bis der Job terminal ist oder der Deckel greift.
    ///
    /// - Parameters:
    ///   - onProgress: Fortschritt 0…1, geklemmt. Feuert bei jedem Tick, solange
    ///     der Job läuft — auch ohne `progress`-Feld (dann mit 0). Läuft auf dem
    ///     MainActor (Default-Isolation des Moduls), darf also direkt in den
    ///     Anzeige-Zustand des Aufrufers schreiben.
    ///
    /// Transiente Lesefehler (Netz-Zucken, kurzer 5xx, unlesbare Antwort)
    /// überspringen einen Tick, statt den Lauf abzubrechen: der Job läuft
    /// serverseitig weiter, und ein abgebrochenes Warten würde dem Nutzer ein
    /// Scheitern melden, das keins ist. Endgültig ist dagegen ein 4xx: 404 heisst
    /// „Job weg" (die Queue lebt im Speicher — ein Server-Neustart verliert ihn),
    /// das endet sofort als `.failed` statt erst nach dem Deckel (Minuten).
    /// 401 wird geworfen (Session vorbei, kein Weiterpollen ohne Token).
    /// `status == nil` gilt als „läuft noch" — ältere Serverstände liefern das
    /// Feld erst, wenn der Worker den Job angefasst hat.
    static func awaitCompletion<Result: Decodable & Sendable>(
        jobId: String,
        api: APIClient,
        interval: Duration,
        maxPolls: Int,
        resultType: Result.Type = Result.self,
        onProgress: (Double) -> Void = { _ in }
    ) async throws -> JobOutcome<Result> {
        let encoded = jobId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? jobId

        for _ in 0..<maxPolls {
            try await Task.sleep(for: interval)
            let job: JobStatusEnvelope<Result>
            do {
                job = try await api.send("/jobs/\(encoded)",
                                         decode: JobStatusEnvelope<Result>.self)
            } catch AuthError.unauthorized {
                throw AuthError.unauthorized
            } catch let AuthError.server(status, code, _) where (400..<500).contains(status) {
                return .failed(code: code ?? (status == 404 ? "JOB_NOT_FOUND" : nil))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
            switch job.status {
            case "queued", "running", .none:
                onProgress(min(max(Double(job.progress ?? 0) / 100, 0), 1))
            case "done":
                return .done(job.result)
            default:   // error / cancelled
                return .failed(code: job.error)
            }
        }
        return .timedOut
    }
}
