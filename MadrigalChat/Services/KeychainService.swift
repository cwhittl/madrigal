import Foundation
import Security
import os

/// The only place in the app that touches SecItem APIs.
///
/// Items are stored with kSecAttrSynchronizable so they ride iCloud Keychain
/// to the user's other devices, which is what makes a key entered on the Mac
/// work on the iPhone without re-entry.
enum KeychainService {

    static let service = "dev.whittle.madrigalchat.apikeys"

    enum KeychainError: LocalizedError {
        case unexpectedStatus(OSStatus)
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
                return "Keychain error: \(message)"
            case .encodingFailed:
                return "Couldn't encode the value for the Keychain."
            }
        }
    }

    /// iCloud Keychain sync needs a real keychain access group, which needs a
    /// signing team. On a locally-signed build SecItemAdd returns
    /// errSecMissingEntitlement (-34018) for synchronizable items, so the app
    /// falls back to a device-local item rather than looking broken.
    /// Once a team is configured, the next save replaces the local item with
    /// a synced one.
    private static let synchronizableAvailable = OSAllocatedUnfairLock(initialState: true)

    private static var useSynchronizable: Bool {
        get { synchronizableAvailable.withLock { $0 } }
        set { synchronizableAvailable.withLock { $0 = newValue } }
    }

    private static func baseQuery(forKey key: String, synchronizable: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        query[kSecAttrSynchronizable as String] = synchronizable
            ? (kCFBooleanTrue as Any)
            : (kSecAttrSynchronizableAny as Any)
        return query
    }

    private static func baseQuery(forKey key: String) -> [String: Any] {
        baseQuery(forKey: key, synchronizable: useSynchronizable)
    }

    static func save(apiKey: String, forKey key: String) throws {
        guard let data = apiKey.data(using: .utf8) else { throw KeychainError.encodingFailed }

        // Replace rather than update. An update scoped to synced items misses
        // a device-local item written by the fallback below, and adding a
        // synced one beside it leaves two items, either of which a load can
        // return. Deleting both kinds first leaves exactly one.
        // The old value is read first so a failed add can put it back
        // instead of leaving the user with no key at all.
        let previous = (try? loadAPIKey(forKey: key)) ?? nil
        try delete(forKey: key)

        let status = add(data, forKey: key)
        guard status == errSecSuccess else {
            if let previous, let old = previous.data(using: .utf8) {
                _ = add(old, forKey: key)
            }
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Adds one item, falling back to a device-local one when iCloud
    /// Keychain isn't available to this build.
    private static func add(_ data: Data, forKey key: String) -> OSStatus {
        var insert = baseQuery(forKey: key)
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        var status = SecItemAdd(insert as CFDictionary, nil)

        if status == errSecMissingEntitlement && useSynchronizable {
            useSynchronizable = false
            insert = baseQuery(forKey: key, synchronizable: false)
            insert.removeValue(forKey: kSecAttrSynchronizable as String)
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(insert as CFDictionary, nil)
        }
        return status
    }

    static func loadAPIKey(forKey key: String) throws -> String? {
        // Match either a synced or a local item, so a key written before the
        // fallback kicked in is still found afterwards.
        var query = baseQuery(forKey: key, synchronizable: false)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    static func delete(forKey key: String) throws {
        let status = SecItemDelete(baseQuery(forKey: key, synchronizable: false) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Deletes, logging a failure instead of throwing. For cleanup the user
    /// can't act on, such as removing a deleted provider's secrets.
    static func deleteOrLog(forKey key: String) {
        do {
            try delete(forKey: key)
        } catch {
            Log.keychain.error("Delete failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func hasKey(forKey key: String) -> Bool {
        ((try? loadAPIKey(forKey: key)) ?? nil)?.isEmpty == false
    }

    /// Masked form for display, e.g. "........f31a". Never returns the whole
    /// secret, and never returns anything at all for a very short value.
    static func maskedValue(forKey key: String) -> String? {
        guard let secret = (try? loadAPIKey(forKey: key)) ?? nil, !secret.isEmpty else { return nil }
        guard secret.count > 6 else { return String(repeating: "\u{2022}", count: 8) }
        return String(repeating: "\u{2022}", count: 8) + secret.suffix(4)
    }
}
