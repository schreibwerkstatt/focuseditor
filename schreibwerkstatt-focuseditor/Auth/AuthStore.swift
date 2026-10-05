//
//  AuthStore.swift
//  schreibwerkstatt-focuseditor
//
//  Zentrale Auth-Zustandsmaschine für die SwiftUI-Shell. Hält das
//  Device-Token in der Keychain, validiert es gegen den Server und
//  stellt einen vorkonfigurierten `APIClient` für den restlichen
//  Swift-Kern (Sync etc.) bereit.
//
//  Datenverlust-Schutz: Bei 401/Logout wird nur das Token entfernt und
//  auf Re-Login geschaltet — lokale Inhalte bleiben unangetastet.
//

import Foundation
import Combine

@MainActor
final class AuthStore: ObservableObject {

    /// Keychain-Koordinaten des Device-Tokens.
    private static let keychainService = "ch.schreibwerkstatt.focuseditor.device-token"
    private static let keychainAccount = "default"

    enum State: Equatable {
        case unknown      // Startzustand, vor Bootstrap
        case signedOut    // kein gültiges Token → Login nötig
        case validating   // Login-/Bootstrap-Prüfung läuft
        case signedIn     // Token vorhanden und (zuletzt) akzeptiert
    }

    @Published private(set) var state: State = .unknown
    @Published var lastError: String?

    /// Vorkonfigurierter Client für authentifizierte Requests.
    /// Zieht das Token bei jedem Request frisch aus der Keychain.
    let api: APIClient

    init() {
        self.api = APIClient(tokenProvider: {
            Keychain.read(service: AuthStore.keychainService,
                          account: AuthStore.keychainAccount)
        })
        // 401 aus beliebigem Request → Session beenden (ohne Datenverlust).
        self.api.onUnauthorized = { [weak self] usedToken in
            Task { @MainActor in self?.handleUnauthorized(usedToken: usedToken) }
        }
    }

    /// Ist ein Token gespeichert? (Format-/Server-unabhängig.)
    var hasStoredToken: Bool {
        Keychain.read(service: Self.keychainService, account: Self.keychainAccount) != nil
    }

    // MARK: - Lifecycle

    /// Beim App-Start: gespeichertes Token gegen den Server prüfen.
    /// Bei Netzwerkfehlern bleiben wir optimistisch angemeldet (offline-fähig);
    /// erst ein echtes 401 beendet die Session.
    func bootstrap() async {
        guard hasStoredToken else {
            state = .signedOut
            return
        }
        state = .validating
        do {
            try await probe(token: nil)
            state = .signedIn
        } catch AuthError.unauthorized {
            clearToken()
            state = .signedOut
        } catch {
            // Offline o. Ä.: Token behalten, optimistisch angemeldet.
            state = .signedIn
        }
    }

    // MARK: - Login

    /// Meldet mit Server-URL + eingefügtem Device-Token an.
    /// Reihenfolge: Format prüfen → URL setzen → gegen Server validieren →
    /// erst bei Erfolg in der Keychain ablegen.
    func signIn(serverURLString: String, rawToken: String) async {
        lastError = nil
        let token = DeviceToken.normalize(rawToken)

        guard DeviceToken.isValidFormat(token) else {
            lastError = AuthError.malformedToken.errorDescription
            return
        }
        guard let normalizedURL = ServerConfig.normalizedURL(from: serverURLString) else {
            lastError = AuthError.invalidServerURL.errorDescription
            return
        }

        state = .validating
        // Der APIClient liest die Basis-URL aus `ServerConfig`, daher muss sie für
        // die Probe gesetzt sein. Den bisherigen Wert merken und bei Fehlschlag
        // zurückrollen — eine fehlgeschlagene Anmeldung darf die zuvor
        // funktionierende Server-Konfiguration nicht dauerhaft überschreiben.
        let previousURL = ServerConfig.baseURLString
        ServerConfig.baseURLString = normalizedURL.absoluteString

        do {
            // Token noch nicht gespeichert → explizit mitgeben.
            try await probe(token: token)
            try Keychain.save(token,
                              service: Self.keychainService,
                              account: Self.keychainAccount)
            state = .signedIn
        } catch {
            ServerConfig.baseURLString = previousURL
            lastError = (error as? LocalizedError)?.errorDescription
                ?? AuthError.network(error).errorDescription
            state = .signedOut
        }
    }

    // MARK: - Logout / 401

    /// Sichert den offenen Editor-Draft, BEVOR die Session endet. Das Abmelden
    /// baut die Schreibfläche ab (WebView weg) — ohne Flush gingen die
    /// Tastenanschläge seit dem letzten Autosave verloren (bis 5 s; aus einem
    /// Menü heraus feuert auch das `blur` der WebView nicht). AppCore verdrahtet
    /// das auf `bridge.flushDraftSave`. Lokal, braucht kein Token.
    var flushBeforeSignOut: (@MainActor () async -> Void)?

    /// Manueller Logout: Draft sichern, Token entfernen, lokale Inhalte bleiben
    /// erhalten. Das Token geht sofort (keine Requests mehr in der Zwischenzeit),
    /// der Zustandswechsel — der die Schreibfläche abbaut — erst nach dem Flush.
    func signOut() {
        clearToken()
        guard let flush = flushBeforeSignOut else {
            state = .signedOut
            return
        }
        Task { @MainActor in
            await flush()
            // Zwischenzeitlich neu angemeldet (anderer Server)? Dann nichts kippen.
            if !self.hasStoredToken { self.state = .signedOut }
        }
    }

    /// Reaktion auf ein 401 aus laufendem Betrieb.
    ///
    /// Nur relevant, solange überhaupt eine Session besteht. Ohne Token feuern
    /// Hintergrund-Komponenten trotzdem Requests (OTA-Bundle-Refresh,
    /// `/config`-Seed der Lokalisierung) — deren 401 ist erwartbar und darf
    /// keine „Token ungültig oder widerrufen"-Meldung auf den Login-Screen
    /// schreiben: bei Erstinstallation stand sie dort, obwohl der Nutzer nie
    /// ein Token hatte. Ein 401 während `signIn` (falsch eingefügtes Token)
    /// wird dort selbst gemeldet (`lastError` im `catch`).
    ///
    /// Nur ein 401 auf das AKTUELL gespeicherte Token beendet die Session. Ein
    /// verspätetes 401 eines Requests ohne Token oder mit einem älteren Token
    /// (Token gewechselt, während ein Sync-/OTA-Request noch lief) würde sonst
    /// das eben frisch gespeicherte neue Token löschen.
    private func handleUnauthorized(usedToken: String?) {
        guard let usedToken,
              usedToken == Keychain.read(service: Self.keychainService,
                                         account: Self.keychainAccount) else { return }
        clearToken()
        lastError = AuthError.unauthorized.errorDescription
        guard let flush = flushBeforeSignOut else {
            state = .signedOut
            return
        }
        Task { @MainActor in
            await flush()
            if !self.hasStoredToken { self.state = .signedOut }
        }
    }

    // MARK: - Intern

    /// Validierungs-Probe: `GET /me/device-tokens` funktioniert mit einem
    /// Device-Token (nur das Ausstellen via POST ist gesperrt). 200 → ok,
    /// 401 → ungültig; andere Fehler propagieren (Offline etc.).
    private func probe(token: String?) async throws {
        _ = try await api.send("/me/device-tokens",
                               method: .GET,
                               overrideToken: token,
                               decode: DeviceTokenListResponse.self)
    }

    private func clearToken() {
        Keychain.delete(service: Self.keychainService, account: Self.keychainAccount)
    }
}
