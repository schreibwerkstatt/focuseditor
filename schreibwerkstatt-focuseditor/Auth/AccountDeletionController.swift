//
//  AccountDeletionController.swift
//  schreibwerkstatt-focuseditor
//
//  Konto-Löschung aus der App heraus (App-Store-Guideline 5.1.1(v):
//  „Apps, die eine Kontoerstellung unterstützen, müssen auch das Löschen des
//  Kontos in der App anbieten"). Direkter Swift→Server-Call, KEIN Bridge-Op —
//  die WebView ist daran nicht beteiligt.
//
//  Vertrag (Server, s. CLAUDE.md „Konto löschen"):
//    DELETE /me/account   Body { "confirm": "DELETE" }
//      200 { ok: true, scheduled_purge_at?: ISO }  → Konto gelöscht (ggf. mit
//                                                    Karenzfrist bis zur
//                                                    endgültigen Entfernung)
//      400 CONFIRM_REQUIRED         → Bestätigung fehlte (Client-Fehler)
//      403 ACCOUNT_DELETE_FORBIDDEN → Konto darf nicht selbst gelöscht werden
//      404 ohne error_code          → Server kennt die Route nicht (älterer
//                                     Stand) → Web-Fallback anbieten
//
//  Nach einem 200 räumt `onDeleted` lokal auf (Token aus der Keychain, lokaler
//  Spiegel + Sync-Zustand dieses Servers) — verdrahtet in `AppCore`.
//

import Foundation
import Combine
import os

@MainActor
final class AccountDeletionController: ObservableObject {

    enum Phase: Equatable {
        case idle
        case deleting
        /// Gelöscht; `purgeAt` ist der (optionale) Server-Zeitpunkt der
        /// endgültigen Entfernung, falls der Server mit Karenzfrist arbeitet.
        case done(purgeAt: String?)
        /// Server ohne Selbst-Löschung → Nutzer auf den Browser verweisen.
        case unsupported
        case failed(String)
    }

    /// Bestätigungswort im Request-Body — bewusst konstant und NICHT lokalisiert
    /// (Protokollwert). Was der Nutzer tippen muss, steht getrennt davon im
    /// Katalog (`settings.account.deleteConfirmWord`).
    static let confirmToken = "DELETE"

    @Published private(set) var phase: Phase = .idle

    /// Aufräumen nach bestätigter Löschung (Keychain + lokale Spiegel).
    var onDeleted: (() async -> Void)?

    private let api: APIClient
    private let logger = AppLog.account

    init(api: APIClient) {
        self.api = api
    }

    var isDeleting: Bool { phase == .deleting }

    func reset() {
        phase = .idle
    }

    /// Führt die Löschung aus. Idempotent gegen Doppelklick (läuft bereits →
    /// no-op). Lokale Inhalte werden NUR nach einer bestätigten Server-Löschung
    /// entfernt — bei jedem Fehler bleibt alles unangetastet.
    func deleteAccount() async {
        guard phase != .deleting else { return }
        phase = .deleting

        do {
            let (status, data) = try await api.sendExpectingJSON(
                "/me/account",
                method: .DELETE,
                body: ConfirmBody(confirm: Self.confirmToken))
            let error = try? JSONDecoder().decode(ServerErrorBody.self, from: data)

            switch status {
            case 200...299:
                let purgeAt = (try? JSONDecoder().decode(DeletionResponse.self, from: data))?.scheduled_purge_at
                logger.notice("Konto serverseitig gelöscht — lokale Daten werden entfernt")
                await onDeleted?()
                phase = .done(purgeAt: purgeAt)

            case 404 where error?.error_code == nil, 405:
                // Kein `error_code` → generischer Express-404: die Route gibt es
                // auf diesem Server (noch) nicht. Ein fachliches 404 mit Code
                // (z. B. USER_NOT_FOUND) fällt in den Standardzweig.
                logger.notice("Server ohne /me/account-Löschroute (Status \(status, privacy: .public))")
                phase = .unsupported

            case 403:
                phase = .failed(t("settings.account.deleteForbidden"))

            default:
                logger.error("Konto-Löschung fehlgeschlagen: \(status, privacy: .public) \(error?.error_code ?? "-", privacy: .public)")
                phase = .failed(AuthError.server(status: status,
                                                 code: error?.error_code,
                                                 body: nil).errorDescription
                                ?? t("settings.account.deleteFailedGeneric"))
            }
        } catch AuthError.server(let status, _, _) where status == 501 {
            // 5xx wirft `sendExpectingJSON` (der Status-`switch` oben sieht ihn
            // nie) — 501 heisst aber „Route nicht implementiert", nicht „kaputt":
            // dann den Browser-Weg anbieten statt einer Fehler-Sackgasse.
            logger.notice("Server ohne /me/account-Löschroute (Status 501)")
            phase = .unsupported
        } catch AuthError.unauthorized {
            // Token ungültig/widerrufen — die AuthStore hat die Session bereits
            // beendet. Lokale Inhalte bleiben (Datenverlust-Schutz).
            phase = .failed(t("settings.account.deleteUnauthorized"))
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription
                            ?? t("settings.account.deleteFailedGeneric"))
        }
    }

    // MARK: - Wire-Typen

    private struct ConfirmBody: Encodable {
        let confirm: String
    }

    private struct DeletionResponse: Decodable {
        let ok: Bool?
        let scheduled_purge_at: String?
    }
}
