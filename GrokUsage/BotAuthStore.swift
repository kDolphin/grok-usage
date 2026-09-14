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
        }
    }
}

/// Reads the Cursor session JWT that Grok Bot stores locally.
/// Tokens live in `~/Library/Application Support/Grok Bot/sand-secrets.json`,
/// encrypted with Electron `safeStorage` (Keychain service `Grok Bot Safe Storage`).
enum BotAuthStore {
    private static let secretsFileName = "sand-secrets.json"
    private static let keychainService = "Grok Bot Safe Storage"
    private static let keychainAccount = "Grok Bot Key"
    private static let accountsKey = "cursor-accounts"
    private static let accessTokenKey = "cursor-access-token"

    static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Grok Bot", isDirectory: true)
    }

    static var secretsFileURL: URL {
        supportDirectory.appendingPathComponent(secretsFileName)
    }

    /// Decrypt and return a usable Cursor access JWT for Grok Bot usage APIs.
    static func loadAccessToken() throws -> String {
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

        let password = try keychainPassword()
        guard let token = decryptSafeStorageBase64(encrypted, password: password), !token.isEmpty else {
            throw BotAuthStoreError.decryptFailed
        }
        guard token.contains(".") else {
            throw BotAuthStoreError.noAccessToken
        }
        return token
    }

    // MARK: - Keychain

    private static func keychainPassword() throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
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

    // MARK: - Electron / Chromium safeStorage (macOS)

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
        let iv = Data(repeating: 0x20, count: 16) // 16 ASCII spaces

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
