import Foundation

enum AuthStoreError: LocalizedError {
    case missingAuthFile(URL)
    case invalidAuthJSON
    case noAccessToken
    case noRefreshToken
    case refreshFailed(String)
    case deviceAuthFailed(String)
    case deviceAuthDenied
    case deviceAuthExpired
    case deviceAuthCancelled

    var errorDescription: String? {
        switch self {
        case .missingAuthFile(let url):
            return L10n.authMissingFile(url.path)
        case .invalidAuthJSON:
            return L10n.authInvalidJSON
        case .noAccessToken:
            return L10n.authNoToken
        case .noRefreshToken:
            return L10n.authNoRefreshToken
        case .refreshFailed(let detail):
            return L10n.authRefreshFailed(detail)
        case .deviceAuthFailed(let detail):
            return L10n.deviceAuthFailed(detail)
        case .deviceAuthDenied:
            return L10n.deviceAuthDenied
        case .deviceAuthExpired:
            return L10n.deviceAuthExpired
        case .deviceAuthCancelled:
            return L10n.deviceAuthCancelled
        }
    }
}

/// In-flight device-code login (RFC 8628) against auth.x.ai.
struct DeviceAuthPending: Equatable {
    var deviceCode: String
    var userCode: String
    var verificationURL: URL
    var interval: TimeInterval
    var expiresAt: Date
}

/// Full OIDC credential row as stored under `~/.grok/auth.json`.
struct AuthCredential {
    var scopeKey: String
    var entry: [String: Any]
    var accessToken: String
    var refreshToken: String?
    var clientID: String?
    var issuer: String?
    var expiresAt: Date?

    var identity: AuthIdentity {
        AuthIdentity(
            email: entry["email"] as? String,
            teamID: entry["team_id"] as? String,
            principalType: entry["principal_type"] as? String,
            authMode: entry["auth_mode"] as? String,
            accessToken: accessToken,
            expiresAt: expiresAt
        )
    }

    /// Refresh when already expired or within this window of expiry.
    func needsRefresh(leeway: TimeInterval = 5 * 60) -> Bool {
        guard let expiresAt else {
            // No expiry recorded — still try use token; refresh only on 401.
            return false
        }
        return expiresAt.timeIntervalSinceNow <= leeway
    }
}

enum AuthStore {
    /// Public OAuth client used by Grok Build CLI (no client secret; PKCE / device code).
    static let oidcClientID = "b1a00492-073a-47ea-816f-4c329264a828"
    static let oidcIssuer = "https://auth.x.ai"
    /// Match scopes on tokens issued by `grok login` so cli-chat-proxy billing works.
    static let oidcScopes = [
        "openid", "profile", "email", "offline_access",
        "grok-cli:access", "api:access",
        "conversations:read", "conversations:write",
        "workspaces:read", "workspaces:write",
    ].joined(separator: " ")

    private static let deviceCodeURL = URL(string: "https://auth.x.ai/oauth2/device/code")!
    private static let tokenURL = URL(string: "https://auth.x.ai/oauth2/token")!
    private static let userInfoURL = URL(string: "https://auth.x.ai/oauth2/userinfo")!

    static var grokHome: URL {
        if let custom = ProcessInfo.processInfo.environment["GROK_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok", isDirectory: true)
    }

    static var authFileURL: URL {
        grokHome.appendingPathComponent("auth.json")
    }

    static var defaultScopeKey: String {
        "\(oidcIssuer)::\(oidcClientID)"
    }

    /// True when `auth.json` has a usable access or refresh token.
    static var hasStoredCredential: Bool {
        (try? loadCredential()) != nil
    }

    static func loadIdentity() throws -> AuthIdentity {
        try loadCredential().identity
    }

    static func loadCredential() throws -> AuthCredential {
        let url = authFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AuthStoreError.missingAuthFile(url)
        }

        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AuthStoreError.invalidAuthJSON
        }

        var bestScope: String?
        var bestEntry: [String: Any]?
        var bestScore = -1

        for (scope, value) in root {
            guard let entry = value as? [String: Any] else { continue }
            let key = (entry["key"] as? String) ?? ""
            let refresh = (entry["refresh_token"] as? String) ?? ""
            // Prefer entries that still have either an access token or a refresh token.
            guard !key.isEmpty || !refresh.isEmpty else { continue }

            var score = 0
            if scope.contains("auth.x.ai") { score += 10 }
            if (entry["auth_mode"] as? String) == "oidc" { score += 5 }
            if !refresh.isEmpty { score += 3 }
            if !key.isEmpty { score += 1 }
            if entry["expires_at"] != nil { score += 1 }
            if score > bestScore {
                bestScore = score
                bestScope = scope
                bestEntry = entry
            }
        }

        guard let scopeKey = bestScope, let entry = bestEntry else {
            throw AuthStoreError.noAccessToken
        }

        let token = (entry["key"] as? String) ?? ""
        return AuthCredential(
            scopeKey: scopeKey,
            entry: entry,
            accessToken: token,
            refreshToken: entry["refresh_token"] as? String,
            clientID: entry["oidc_client_id"] as? String,
            issuer: entry["oidc_issuer"] as? String,
            expiresAt: parseDate(entry["expires_at"])
        )
    }

    /// Load credential and silently refresh via OIDC when near/past expiry.
    static func loadValidIdentity() async throws -> AuthIdentity {
        var cred = try loadCredential()
        if cred.needsRefresh() {
            cred = try await refreshCredential(cred)
        }
        if cred.accessToken.isEmpty {
            // Access empty but refresh might work.
            if cred.refreshToken != nil {
                cred = try await refreshCredential(cred)
            } else {
                throw AuthStoreError.noAccessToken
            }
        }
        return cred.identity
    }

    /// Force OIDC refresh and rewrite `auth.json` (same file Grok CLI uses).
    static func refreshCredential(_ cred: AuthCredential) async throws -> AuthCredential {
        guard let refreshToken = cred.refreshToken, !refreshToken.isEmpty else {
            throw AuthStoreError.noRefreshToken
        }

        let clientID = cred.clientID ?? oidcClientID

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("grok-usage-menubar", forHTTPHeaderField: "User-Agent")

        let parts: [URLQueryItem] = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: clientID),
        ]
        var components = URLComponents()
        components.queryItems = parts
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw AuthStoreError.refreshFailed(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw AuthStoreError.refreshFailed(L10n.authInvalidResponse)
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AuthStoreError.refreshFailed("HTTP \(http.statusCode) \(body.prefix(160))")
        }

        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let access = json["access_token"] as? String,
            !access.isEmpty
        else {
            throw AuthStoreError.refreshFailed(L10n.authMissingAccessToken)
        }

        var updatedEntry = cred.entry
        updatedEntry["key"] = access
        if let newRefresh = json["refresh_token"] as? String, !newRefresh.isEmpty {
            updatedEntry["refresh_token"] = newRefresh
        }
        if let expiresIn = json["expires_in"] as? Int {
            let exp = Date().addingTimeInterval(TimeInterval(expiresIn))
            updatedEntry["expires_at"] = isoFractional(exp)
        } else if let expiresIn = json["expires_in"] as? Double {
            let exp = Date().addingTimeInterval(expiresIn)
            updatedEntry["expires_at"] = isoFractional(exp)
        }

        try writeEntry(scopeKey: cred.scopeKey, entry: updatedEntry)

        return AuthCredential(
            scopeKey: cred.scopeKey,
            entry: updatedEntry,
            accessToken: access,
            refreshToken: updatedEntry["refresh_token"] as? String,
            clientID: clientID,
            issuer: cred.issuer,
            expiresAt: parseDate(updatedEntry["expires_at"])
        )
    }

    // MARK: - Device-code browser login (no Grok Build CLI required)

    /// Start RFC 8628 device authorization. Caller should open `verificationURL` in a browser.
    static func beginDeviceLogin() async throws -> DeviceAuthPending {
        var request = URLRequest(url: deviceCodeURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("grok-usage-menubar", forHTTPHeaderField: "User-Agent")

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "client_id", value: oidcClientID),
            URLQueryItem(name: "scope", value: oidcScopes),
        ]
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw AuthStoreError.deviceAuthFailed(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw AuthStoreError.deviceAuthFailed(L10n.authInvalidResponse)
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AuthStoreError.deviceAuthFailed("HTTP \(http.statusCode) \(body.prefix(160))")
        }

        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let deviceCode = json["device_code"] as? String,
            let userCode = json["user_code"] as? String,
            !deviceCode.isEmpty, !userCode.isEmpty
        else {
            throw AuthStoreError.deviceAuthFailed(L10n.authInvalidResponse)
        }

        let verification: URL
        if let complete = json["verification_uri_complete"] as? String, let url = URL(string: complete) {
            verification = url
        } else if let base = json["verification_uri"] as? String, let url = URL(string: base) {
            verification = url
        } else {
            throw AuthStoreError.deviceAuthFailed(L10n.authInvalidResponse)
        }

        let interval = TimeInterval((json["interval"] as? Int) ?? (json["interval"] as? Double).map(Int.init) ?? 5)
        let expiresIn = TimeInterval((json["expires_in"] as? Int) ?? (json["expires_in"] as? Double).map(Int.init) ?? 1800)

        return DeviceAuthPending(
            deviceCode: deviceCode,
            userCode: userCode,
            verificationURL: verification,
            interval: max(interval, 1),
            expiresAt: Date().addingTimeInterval(expiresIn)
        )
    }

    /// Poll until the user finishes browser authorization, then persist tokens like `grok login`.
    static func completeDeviceLogin(_ pending: DeviceAuthPending) async throws -> AuthIdentity {
        var interval = pending.interval

        while true {
            try Task.checkCancellation()
            if Date() >= pending.expiresAt {
                throw AuthStoreError.deviceAuthExpired
            }

            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            try Task.checkCancellation()

            let result = try await pollDeviceToken(deviceCode: pending.deviceCode)
            switch result {
            case .pending:
                continue
            case .slowDown:
                interval += 5
                continue
            case .denied:
                throw AuthStoreError.deviceAuthDenied
            case .expired:
                throw AuthStoreError.deviceAuthExpired
            case .success(let access, let refresh, let expiresIn):
                let identity = try await persistDeviceTokens(
                    accessToken: access,
                    refreshToken: refresh,
                    expiresIn: expiresIn
                )
                return identity
            }
        }
    }

    /// Remove the shared xAI OIDC entry from `~/.grok/auth.json` (also affects Grok Build CLI).
    static func clearStoredCredential() throws {
        let url = authFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let data = try Data(contentsOf: url)
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AuthStoreError.invalidAuthJSON
        }

        // Drop preferred CLI scope; also remove any other auth.x.ai rows.
        root.removeValue(forKey: defaultScopeKey)
        for key in Array(root.keys) where key.contains("auth.x.ai") {
            root.removeValue(forKey: key)
        }

        if root.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }

        let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        let tmp = url.appendingPathExtension("tmp")
        try out.write(to: tmp, options: .atomic)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    private enum DevicePollResult {
        case pending
        case slowDown
        case denied
        case expired
        case success(access: String, refresh: String?, expiresIn: TimeInterval?)
    }

    private static func pollDeviceToken(deviceCode: String) async throws -> DevicePollResult {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("grok-usage-menubar", forHTTPHeaderField: "User-Agent")

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "urn:ietf:params:oauth:grant-type:device_code"),
            URLQueryItem(name: "device_code", value: deviceCode),
            URLQueryItem(name: "client_id", value: oidcClientID),
        ]
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw AuthStoreError.deviceAuthFailed(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw AuthStoreError.deviceAuthFailed(L10n.authInvalidResponse)
        }

        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]

        if (200..<300).contains(http.statusCode) {
            guard let access = json?["access_token"] as? String, !access.isEmpty else {
                throw AuthStoreError.deviceAuthFailed(L10n.authMissingAccessToken)
            }
            let refresh = json?["refresh_token"] as? String
            let expiresIn: TimeInterval?
            if let n = json?["expires_in"] as? Int {
                expiresIn = TimeInterval(n)
            } else if let n = json?["expires_in"] as? Double {
                expiresIn = n
            } else {
                expiresIn = nil
            }
            return .success(access: access, refresh: refresh, expiresIn: expiresIn)
        }

        let errorCode = (json?["error"] as? String) ?? ""
        switch errorCode {
        case "authorization_pending":
            return .pending
        case "slow_down":
            return .slowDown
        case "access_denied":
            return .denied
        case "expired_token":
            return .expired
        default:
            let body = String(data: data, encoding: .utf8) ?? errorCode
            throw AuthStoreError.deviceAuthFailed("HTTP \(http.statusCode) \(body.prefix(160))")
        }
    }

    private static func persistDeviceTokens(
        accessToken: String,
        refreshToken: String?,
        expiresIn: TimeInterval?
    ) async throws -> AuthIdentity {
        var entry: [String: Any] = [
            "key": accessToken,
            "auth_mode": "oidc",
            "oidc_client_id": oidcClientID,
            "oidc_issuer": oidcIssuer,
            "principal_type": "User",
            "create_time": isoFractional(Date()),
        ]
        if let refreshToken, !refreshToken.isEmpty {
            entry["refresh_token"] = refreshToken
        }
        if let expiresIn {
            entry["expires_at"] = isoFractional(Date().addingTimeInterval(expiresIn))
        }

        // Best-effort profile enrichment for the panel header.
        if let profile = try? await fetchUserInfo(accessToken: accessToken) {
            if let email = profile["email"] as? String { entry["email"] = email }
            if let name = profile["name"] as? String { entry["first_name"] = name }
            if let given = profile["given_name"] as? String { entry["first_name"] = given }
            if let sub = profile["sub"] as? String {
                entry["user_id"] = sub
                entry["principal_id"] = sub
            }
        }

        try writeEntry(scopeKey: defaultScopeKey, entry: entry)

        return AuthCredential(
            scopeKey: defaultScopeKey,
            entry: entry,
            accessToken: accessToken,
            refreshToken: entry["refresh_token"] as? String,
            clientID: oidcClientID,
            issuer: oidcIssuer,
            expiresAt: parseDate(entry["expires_at"])
        ).identity
    }

    private static func fetchUserInfo(accessToken: String) async throws -> [String: Any] {
        var request = URLRequest(url: userInfoURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("grok-usage-menubar", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AuthStoreError.deviceAuthFailed(L10n.authInvalidResponse)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AuthStoreError.deviceAuthFailed(L10n.authInvalidResponse)
        }
        return json
    }

    private static func writeEntry(scopeKey: String, entry: [String: Any]) throws {
        let url = authFileURL
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            root = existing
        }
        root[scopeKey] = entry

        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        let tmp = url.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        // Replace main file.
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
    }

    private static func isoFractional(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    static func parseDate(_ value: Any?) -> Date? {
        if let number = value as? Double {
            if number > 1_000_000_000_000 {
                return Date(timeIntervalSince1970: number / 1000)
            }
            return Date(timeIntervalSince1970: number)
        }
        if let number = value as? Int {
            return parseDate(Double(number))
        }
        guard let raw = value as? String, !raw.isEmpty else { return nil }

        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFractional.date(from: raw) { return date }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: raw)
    }
}
