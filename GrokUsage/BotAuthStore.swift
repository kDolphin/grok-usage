import Foundation
import Security
import CommonCrypto

enum BotAuthStoreError: LocalizedError {
    case missingSecretsFile(URL)
    case invalidSecretsJSON
    case noActiveAccount
    case keychainUnavailable
    case decryptFailed
    case noAccessToken
    case loginFailed(String)
    case loginDenied
    case loginExpired
    case loginCancelled
    case refreshFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingSecretsFile:
            return L10n.botAuthMissing
        case .invalidSecretsJSON:
            return L10n.botAuthInvalid
        case .noActiveAccount:
            return L10n.botAuthNoAccount
        case .keychainUnavailable:
            return L10n.botAuthKeychain
        case .decryptFailed:
            return L10n.botAuthDecryptFailed
        case .noAccessToken:
            return L10n.botAuthNoToken
        case .loginFailed(let detail):
            return L10n.botLoginFailed(detail)
        case .loginDenied:
            return L10n.botLoginDenied
        case .loginExpired:
            return L10n.botLoginExpired
        case .loginCancelled:
            return L10n.botLoginCancelled
        case .refreshFailed(let detail):
            return L10n.botRefreshFailed(detail)
        }
    }
}

/// In-flight Cursor PKCE browser login (loginDeepControl + poll).
struct BotBrowserLoginPending: Equatable {
    var loginURL: URL
    var uuid: String
    var verifier: String
}

/// Cursor session for Grok Bot usage APIs.
/// Prefer tokens from this app's Keychain (browser login); fall back to local Grok Bot
/// `sand-secrets.json` when present.
enum BotAuthStore {
    private static let ownKeychainService = "com.kdolphin.grok-usage.bot"
    private static let accessAccount = "cursor-access-token"
    private static let refreshAccount = "cursor-refresh-token"

    private static let loginURL = URL(string: "https://cursor.com/loginDeepControl")!
    private static let pollURL = URL(string: "https://api2.cursor.sh/auth/poll")!
    private static let refreshURL = URL(string: "https://api2.cursor.sh/auth/exchange_user_api_key")!

    private static let secretsFileName = "sand-secrets.json"
    private static let grokBotKeychainService = "Grok Bot Safe Storage"
    private static let grokBotKeychainAccount = "Grok Bot Key"
    private static let accountsKey = "cursor-accounts"
    private static let accessTokenKey = "cursor-access-token"
    private static let refreshSkew: TimeInterval = 5 * 60
    private static let pollTimeout: TimeInterval = 5 * 60

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Grok Bot", isDirectory: true)
    }

    static var secretsFileURL: URL {
        supportDirectory.appendingPathComponent(secretsFileName)
    }

    /// True when this app has its own Cursor tokens (browser login).
    static var hasOwnCredential: Bool {
        (try? readKeychain(account: accessAccount)) != nil
            || (try? readKeychain(account: refreshAccount)) != nil
    }

    /// True when any Bot auth source is available (own Keychain or local Grok Bot).
    static var hasAnyCredential: Bool {
        if hasOwnCredential { return true }
        return (try? loadFromGrokBotApp()) != nil
    }

    /// Load a usable access JWT, refreshing own tokens when near expiry.
    static func loadValidAccessToken() async throws -> String {
        if let own = try? loadOwnAccessToken() {
            if !needsRefresh(jwt: own), !own.isEmpty {
                return own
            }
            if let refreshed = try? await refreshOwnCredential() {
                return refreshed
            }
            if !own.isEmpty { return own }
        }

        if let local = try? loadFromGrokBotApp(), !local.isEmpty {
            return local
        }

        if hasOwnCredential {
            throw BotAuthStoreError.noAccessToken
        }
        throw BotAuthStoreError.missingSecretsFile(secretsFileURL)
    }

    /// Decrypt / return local Grok Bot token only (no network).
    static func loadAccessToken() throws -> String {
        if let own = try? loadOwnAccessToken(), !own.isEmpty {
            return own
        }
        return try loadFromGrokBotApp()
    }

    // MARK: - Browser login (Cursor PKCE)

    static func beginBrowserLogin() throws -> BotBrowserLoginPending {
        let verifier = base64URLEncode(randomBytes(32))
        let challenge = base64URLEncode(sha256(Data(verifier.utf8)))
        let authUUID = UUID().uuidString.lowercased()

        var components = URLComponents(url: loginURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "challenge", value: challenge),
            URLQueryItem(name: "uuid", value: authUUID),
            URLQueryItem(name: "mode", value: "login"),
            URLQueryItem(name: "redirectTarget", value: "cli"),
        ]
        guard let url = components.url else {
            throw BotAuthStoreError.loginFailed(L10n.authInvalidResponse)
        }
        return BotBrowserLoginPending(loginURL: url, uuid: authUUID, verifier: verifier)
    }

    /// Poll until the user approves in the browser, then store tokens in our Keychain.
    static func completeBrowserLogin(_ pending: BotBrowserLoginPending) async throws {
        let tokens = try await pollForTokens(uuid: pending.uuid, verifier: pending.verifier)
        try storeOwnTokens(access: tokens.access, refresh: tokens.refresh)
    }

    /// Remove only this app's Bot tokens (does not touch Grok Bot's sand-secrets).
    static func clearOwnCredential() throws {
        try deleteKeychain(account: accessAccount)
        try deleteKeychain(account: refreshAccount)
    }

    // MARK: - Own token refresh

    private static func refreshOwnCredential() async throws -> String {
        let bearer = (try? readKeychain(account: refreshAccount))
            ?? (try? readKeychain(account: accessAccount))
        guard let bearer, !bearer.isEmpty else {
            throw BotAuthStoreError.noAccessToken
        }

        var request = URLRequest(url: refreshURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("grok-usage-menubar", forHTTPHeaderField: "User-Agent")
        request.httpBody = Data("{}".utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw BotAuthStoreError.refreshFailed(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw BotAuthStoreError.refreshFailed(L10n.authInvalidResponse)
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw BotAuthStoreError.refreshFailed("HTTP \(http.statusCode) \(body.prefix(160))")
        }

        let tokens = try extractTokens(from: data)
        try storeOwnTokens(access: tokens.access, refresh: tokens.refresh)
        return tokens.access
    }

    private static func pollForTokens(uuid: String, verifier: String) async throws -> (access: String, refresh: String?) {
        let deadline = Date().addingTimeInterval(pollTimeout)
        var delay: TimeInterval = 1.0
        var lastTransport: Error?

        while Date() < deadline {
            try Task.checkCancellation()

            var components = URLComponents(url: pollURL, resolvingAgainstBaseURL: false)!
            components.queryItems = [
                URLQueryItem(name: "uuid", value: uuid),
                URLQueryItem(name: "verifier", value: verifier),
            ]
            guard let url = components.url else {
                throw BotAuthStoreError.loginFailed(L10n.authInvalidResponse)
            }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("grok-usage-menubar", forHTTPHeaderField: "User-Agent")

            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw BotAuthStoreError.loginFailed(L10n.authInvalidResponse)
                }

                if http.statusCode == 404 {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    delay = min(delay * 1.5, 5.0)
                    continue
                }

                if http.statusCode == 403 {
                    throw BotAuthStoreError.loginDenied
                }
                if !(200..<300).contains(http.statusCode) {
                    let body = String(data: data, encoding: .utf8) ?? ""
                    throw BotAuthStoreError.loginFailed("HTTP \(http.statusCode) \(body.prefix(160))")
                }

                return try extractTokens(from: data)
            } catch is CancellationError {
                throw BotAuthStoreError.loginCancelled
            } catch let err as BotAuthStoreError {
                throw err
            } catch {
                lastTransport = error
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                delay = min(delay * 1.5, 5.0)
            }
        }

        if let lastTransport {
            throw BotAuthStoreError.loginFailed(lastTransport.localizedDescription)
        }
        throw BotAuthStoreError.loginExpired
    }

    private static func extractTokens(from data: Data) throws -> (access: String, refresh: String?) {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BotAuthStoreError.loginFailed(L10n.authInvalidResponse)
        }
        let access = (
            (json["accessToken"] as? String)
                ?? (json["access_token"] as? String)
                ?? (json["token"] as? String)
                ?? ""
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !access.isEmpty else {
            throw BotAuthStoreError.loginFailed(L10n.authMissingAccessToken)
        }
        let refreshRaw = (json["refreshToken"] as? String) ?? (json["refresh_token"] as? String)
        let refresh = refreshRaw?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (access, (refresh?.isEmpty == false) ? refresh : nil)
    }

    // MARK: - Own Keychain

    private static func loadOwnAccessToken() throws -> String {
        let token = try readKeychain(account: accessAccount)
        guard token.contains(".") else { throw BotAuthStoreError.noAccessToken }
        return token
    }

    private static func storeOwnTokens(access: String, refresh: String?) throws {
        try writeKeychain(account: accessAccount, value: access)
        if let refresh, !refresh.isEmpty {
            try writeKeychain(account: refreshAccount, value: refresh)
        }
    }

    private static func readKeychain(account: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: ownKeychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            throw BotAuthStoreError.keychainUnavailable
        }
        guard let value = String(data: data, encoding: .utf8), !value.isEmpty else {
            throw BotAuthStoreError.keychainUnavailable
        }
        return value
    }

    private static func writeKeychain(account: String, value: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: ownKeychainService,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw BotAuthStoreError.keychainUnavailable
        }
    }

    private static func deleteKeychain(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: ownKeychainService,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw BotAuthStoreError.keychainUnavailable
        }
    }

    // MARK: - Local Grok Bot fallback

    private static func loadFromGrokBotApp() throws -> String {
        let url = secretsFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw BotAuthStoreError.missingSecretsFile(url)
        }

        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BotAuthStoreError.invalidSecretsJSON
        }

        guard
            let accountsRaw = root[accountsKey] as? String,
            let accountsData = accountsRaw.data(using: .utf8),
            let accountsRoot = try JSONSerialization.jsonObject(with: accountsData) as? [String: Any],
            let active = accountsRoot["active"] as? String,
            !active.isEmpty,
            let accounts = accountsRoot["accounts"] as? [String: Any],
            let account = accounts[active] as? [String: Any],
            let encrypted = account[accessTokenKey] as? String,
            !encrypted.isEmpty
        else {
            throw BotAuthStoreError.noActiveAccount
        }

        let password = try grokBotKeychainPassword()
        guard let token = decryptSafeStorageBase64(encrypted, password: password), !token.isEmpty else {
            throw BotAuthStoreError.decryptFailed
        }
        guard token.contains(".") else {
            throw BotAuthStoreError.noAccessToken
        }
        return token
    }

    private static func grokBotKeychainPassword() throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: grokBotKeychainService,
            kSecAttrAccount as String: grokBotKeychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            throw BotAuthStoreError.keychainUnavailable
        }
        guard let password = String(data: data, encoding: .utf8), !password.isEmpty else {
            throw BotAuthStoreError.keychainUnavailable
        }
        return password
    }

    // MARK: - JWT helpers

    private static func needsRefresh(jwt: String) -> Bool {
        guard let exp = jwtExpiry(jwt) else { return false }
        return exp.timeIntervalSinceNow <= refreshSkew
    }

    private static func jwtExpiry(_ jwt: String) -> Date? {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let pad = (4 - payload.count % 4) % 4
        if pad > 0 { payload += String(repeating: "=", count: pad) }
        guard
            let data = Data(base64Encoded: payload),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let exp = json["exp"] as? TimeInterval {
            return Date(timeIntervalSince1970: exp)
        }
        if let exp = json["exp"] as? Int {
            return Date(timeIntervalSince1970: TimeInterval(exp))
        }
        return nil
    }

    // MARK: - Crypto helpers

    private static func randomBytes(_ count: Int) -> Data {
        var data = Data(count: count)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        return data
    }

    private static func sha256(_ data: Data) -> Data {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(data.count), &hash)
        }
        return Data(hash)
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Decrypt a base64 blob produced by Electron `safeStorage.encryptString`.
    /// On macOS this is Chromium `v10` + AES-128-CBC with PBKDF2-HMAC-SHA1
    /// (`saltysalt`, 1003 iterations, 16-byte key, IV of 16 spaces).
    private static func decryptSafeStorageBase64(_ b64: String, password: String) -> String? {
        guard let raw = Data(base64Encoded: b64), raw.count > 3 else { return nil }
        let prefix = raw.prefix(3)
        guard String(data: prefix, encoding: .utf8) == "v10" else { return nil }

        let ciphertext = raw.dropFirst(3)
        guard !ciphertext.isEmpty, ciphertext.count % 16 == 0 else { return nil }

        guard let key = pbkdf2SHA1(password: password, salt: Data("saltysalt".utf8), iterations: 1003, keyLength: 16) else {
            return nil
        }
        let iv = Data(repeating: 0x20, count: 16)

        var outCount = 0
        var out = Data(count: ciphertext.count + kCCBlockSizeAES128)
        let outCapacity = out.count
        let keyCount = key.count
        let cipherCount = ciphertext.count
        let status: CCCryptorStatus = out.withUnsafeMutableBytes { outBytes in
            ciphertext.withUnsafeBytes { cipherBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, keyCount,
                            ivBytes.baseAddress,
                            cipherBytes.baseAddress, cipherCount,
                            outBytes.baseAddress, outCapacity,
                            &outCount
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        out.count = outCount
        return String(data: out, encoding: .utf8)
    }

    private static func pbkdf2SHA1(password: String, salt: Data, iterations: UInt32, keyLength: Int) -> Data? {
        let passwordData = Data(password.utf8)
        var derived = Data(count: keyLength)
        let result = derived.withUnsafeMutableBytes { derivedBytes in
            salt.withUnsafeBytes { saltBytes in
                passwordData.withUnsafeBytes { passwordBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.bindMemory(to: Int8.self).baseAddress,
                        passwordData.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        iterations,
                        derivedBytes.bindMemory(to: UInt8.self).baseAddress,
                        keyLength
                    )
                }
            }
        }
        return result == kCCSuccess ? derived : nil
    }
}
