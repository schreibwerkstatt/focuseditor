//
//  APIClient.swift
//  schreibwerkstatt-focuseditor
//
//  Schmaler HTTP-Client für den schreibwerkstatt-Server. Setzt bei
//  jedem Request den `Authorization: Bearer swd_…`-Header aus der
//  Keychain (via `tokenProvider`). Netzwerk macht ausschließlich der
//  Swift-Kern — die WebView kennt weder Server noch Token.
//
//  401 → `AuthError.unauthorized`; zusätzlich wird `onUnauthorized`
//  gemeldet, damit die AuthStore das Token verwerfen und auf Re-Login
//  schalten kann. Lokale Inhalte werden dabei NIE verworfen.
//

import Foundation

final class APIClient {
    /// Liefert das aktuelle Klartext-Token (oder nil), z. B. aus der Keychain.
    private let tokenProvider: () -> String?
    /// Wird bei 401 aufgerufen (z. B. um die Session zu beenden) — mit dem
    /// Token, das der abgewiesene Request trug (`nil` = ohne Token). So kann der
    /// Empfänger ein verspätetes 401 eines ALTEN Tokens ignorieren, statt das
    /// inzwischen frisch gespeicherte neue zu löschen.
    var onUnauthorized: ((_ usedToken: String?) -> Void)?

    private let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(tokenProvider: @escaping () -> String?,
         session: URLSession? = nil) {
        self.tokenProvider = tokenProvider
        self.session = session ?? APIClient.makeSession()
    }

    /// Eigene Session mit endlichem Request-Timeout. Default-`URLSession.shared`
    /// wartet bis zu 60 s je Request — ein hängender Sync-Pull würde den
    /// `isRunning`-Lock der SyncEngine so lange halten und alle Folge-Ticks
    /// blockieren. `timeoutIntervalForRequest` greift pro Datenpaket, große
    /// Downloads (Editor-Bundle-ZIP) bleiben also unbeschränkt, solange Daten
    /// fließen.
    static func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.waitsForConnectivity = false
        // Cookie-los: rein stateless Bearer-Auth. Ohne das speichert der Client
        // das `connect.sid`-Session-Cookie, das der Server beim ersten Device-
        // Token-Touch setzt, und sendet es fortan mit. Der Server-Auth-Guard
        // kurzschliesst dann ueber die Session und ueberspringt die Device-Auth
        // → touchTokenUsage-Telemetrie (Zugriffe/Zuletzt-aktiv/Version) friert
        // ein und widerrufene Tokens blieben bis zum Cookie-Ablauf gueltig.
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        cfg.httpCookieStorage = nil
        return URLSession(configuration: cfg)
    }

    enum Method: String {
        case GET, POST, PUT, DELETE
    }

    /// Installierte App-Version für den `X-Client-Version`-Telemetrie-Header
    /// (CFBundleShortVersionString, gespeist aus MARKETING_VERSION). OHNE
    /// führendes „v“ — der Server loggt den reinen Versionsstring (z. B.
    /// `1.2.3`). Einmal berechnet, da pro Prozess konstant.
    static let clientVersion: String =
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown"

    /// Plattform-Code für den `X-Client-Platform`-Header. Der Server baut daraus
    /// das Revision-„Gerät"-Label per Request — bleibt korrekt, selbst wenn
    /// dasselbe Device-Token auf mehreren Geräten genutzt wird.
    static let clientPlatform = "macos"

    /// Gerätename für den `X-Client-Device`-Header (Computer-Name, z. B.
    /// „MacBook Pro von David"). Fällt auf den Hostnamen zurück.
    static let clientDevice: String =
        Host.current().localizedName ?? (Host.current().name ?? "Mac")

    /// Führt einen Request gegen `ServerConfig.baseURL` + `path` aus und
    /// dekodiert die Antwort. `overrideToken` erlaubt das Validieren eines
    /// noch nicht gespeicherten Tokens beim Login.
    @discardableResult
    func send<T: Decodable>(
        _ path: String,
        method: Method = .GET,
        body: Encodable? = nil,
        overrideToken: String? = nil,
        decode type: T.Type
    ) async throws -> T {
        let data = try await sendRaw(path, method: method, body: body, overrideToken: overrideToken)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw AuthError.decoding(error)
        }
    }

    /// Variante ohne dekodierten Body (z. B. revoke/delete: `{ ok: true }`).
    func sendVoid(
        _ path: String,
        method: Method = .GET,
        body: Encodable? = nil,
        overrideToken: String? = nil
    ) async throws {
        _ = try await sendRaw(path, method: method, body: body, overrideToken: overrideToken)
    }

    /// POST mit JSON-Body, der fachliche 4xx-Antworten als `(status, data)`
    /// durchreicht, statt sie zu werfen. Gedacht für Endpoints, deren 4xx eine
    /// Bedeutung trägt, die der Aufrufer deuten muss — z. B. liefert
    /// `POST /languagetool/check` ein `404`, wenn LanguageTool serverseitig
    /// deaktiviert ist (kein Fehler, sondern „Feature aus").
    ///
    /// `401` schlägt wie üblich auf `onUnauthorized` durch und wirft; `5xx`
    /// und Netzfehler werfen ebenfalls. Lokale Inhalte werden NIE verworfen.
    func postExpectingJSON(_ path: String, body: Encodable) async throws -> (status: Int, data: Data) {
        try await sendExpectingJSON(path, method: .POST, body: body)
    }

    /// Wie `postExpectingJSON`, aber für beliebige Methoden — z. B.
    /// `DELETE /me/account`, wo der Aufrufer `404` (Server ohne Selbst-Löschung)
    /// von `403` (verweigert) unterscheiden muss.
    func sendExpectingJSON(_ path: String,
                           method: Method,
                           body: Encodable? = nil) async throws -> (status: Int, data: Data) {
        let request = try buildRequest(path, method: method, body: body)
        let (http, data) = try await perform(request)

        switch http.statusCode {
        case 401:
            onUnauthorized?(Self.bearerToken(of: request))
            throw AuthError.unauthorized
        case 500...599:
            throw serverError(http, data)
        default:
            // 2xx und fachliche 4xx (z. B. 404/413) reicht der Aufrufer aus.
            return (http.statusCode, data)
        }
    }

    /// Ergebnis eines Roh-GET ohne JSON-Decode (für Nicht-JSON-Ressourcen wie
    /// das Editor-Bundle-ZIP). `notModified` = Server-304 auf `If-None-Match`.
    struct RawResponse {
        let notModified: Bool
        let data: Data
        let etag: String?
    }

    /// Roh-GET für binäre Ressourcen. Behandelt `304 Not Modified` NICHT als
    /// Fehler (für konditionale Anfragen via `If-None-Match`). 401 schlägt wie
    /// üblich auf `onUnauthorized` durch.
    func getRaw(_ path: String, ifNoneMatch etag: String? = nil) async throws -> RawResponse {
        // Roh-GET: kein `Accept: application/json` (Ziel ist ein ZIP), aber
        // optionaler `If-None-Match`.
        let request = try buildRequest(path, method: .GET, acceptJSON: false, ifNoneMatch: etag)
        let (http, data) = try await perform(request)

        let responseETag = http.value(forHTTPHeaderField: "ETag")
        switch http.statusCode {
        case 304:
            return RawResponse(notModified: true, data: Data(), etag: responseETag ?? etag)
        case 200...299:
            return RawResponse(notModified: false, data: data, etag: responseETag)
        case 401:
            onUnauthorized?(Self.bearerToken(of: request))
            throw AuthError.unauthorized
        default:
            throw serverError(http, data)
        }
    }

    /// Kern: baut den Request, prüft Statuscodes, mappt Fehler.
    private func sendRaw(
        _ path: String,
        method: Method,
        body: Encodable?,
        overrideToken: String?
    ) async throws -> Data {
        let request = try buildRequest(path, method: method, body: body, overrideToken: overrideToken)
        let (http, data) = try await perform(request)

        switch http.statusCode {
        case 200...299:
            return data
        case 401:
            onUnauthorized?(Self.bearerToken(of: request))
            throw AuthError.unauthorized
        default:
            throw serverError(http, data)
        }
    }

    // MARK: - Gemeinsame Request-Bausteine

    /// Baut einen `URLRequest` gegen `ServerConfig.baseURL` + `path`: setzt
    /// Bearer-Token (override > Keychain), optional `Accept`/`Content-Type` und
    /// `If-None-Match`. EINE Stelle für Header/Auth — kein Drift zwischen den
    /// Aufruf-Varianten.
    private func buildRequest(
        _ path: String,
        method: Method,
        body: Encodable? = nil,
        overrideToken: String? = nil,
        acceptJSON: Bool = true,
        ifNoneMatch: String? = nil
    ) throws -> URLRequest {
        // Pfad an die Basis ANHÄNGEN statt relativ aufzulösen: `URL(string:
        // "/content/…", relativeTo:)` ersetzt einen Pfad der Basis (Server unter
        // `https://host/sw`) durch den Wurzelpfad. Die Basis ist normalisiert
        // (ohne Slash am Ende), der Pfad beginnt mit `/`.
        guard let baseURL = ServerConfig.baseURL else { throw AuthError.invalidServerURL }
        let joined = baseURL.absoluteString + (path.hasPrefix("/") ? path : "/" + path)
        guard let url = URL(string: joined) else { throw AuthError.invalidServerURL }

        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        // Telemetrie: installierte App-Version auf JEDEM ausgehenden Request
        // (Sync-Pull/-Push, OTA-Bundle, Content, Auth-Probe) — zentral hier,
        // nicht pro Call dupliziert.
        request.setValue(APIClient.clientVersion, forHTTPHeaderField: "X-Client-Version")
        request.setValue(APIClient.clientPlatform, forHTTPHeaderField: "X-Client-Platform")
        request.setValue(APIClient.clientDevice, forHTTPHeaderField: "X-Client-Device")
        if acceptJSON {
            request.setValue("application/json", forHTTPHeaderField: "Accept")
        }
        if let token = overrideToken ?? tokenProvider() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(AnyEncodable(body))
        }
        if let ifNoneMatch {
            request.setValue(ifNoneMatch, forHTTPHeaderField: "If-None-Match")
        }
        return request
    }

    /// Das Bearer-Token, das ein Request trägt (`nil` ohne Authorization-Header).
    private static func bearerToken(of request: URLRequest) -> String? {
        guard let header = request.value(forHTTPHeaderField: "Authorization"),
              header.hasPrefix("Bearer ") else { return nil }
        return String(header.dropFirst("Bearer ".count))
    }

    /// Führt den Request aus und liefert `HTTPURLResponse` + Body. Mappt
    /// Transport-Fehler auf `AuthError.network`, eine Nicht-HTTP-Antwort auf
    /// `AuthError.server(status: -1, …)`. Statuscode-Deutung bleibt beim Aufrufer.
    private func perform(_ request: URLRequest) async throws -> (HTTPURLResponse, Data) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AuthError.network(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw AuthError.server(status: -1, code: nil, body: nil)
        }
        return (http, data)
    }

    /// Einheitlicher Server-Fehler aus Status + Body (dekodiert `error_code`).
    private func serverError(_ http: HTTPURLResponse, _ data: Data) -> AuthError {
        let code = (try? decoder.decode(ServerErrorBody.self, from: data))?.error_code
        return AuthError.server(status: http.statusCode, code: code, body: data)
    }
}

/// Type-Erasure, damit `Encodable` als Parameter funktioniert.
private struct AnyEncodable: Encodable {
    private let encodeFunc: (Encoder) throws -> Void
    init(_ wrapped: Encodable) {
        self.encodeFunc = wrapped.encode
    }
    func encode(to encoder: Encoder) throws {
        try encodeFunc(encoder)
    }
}
