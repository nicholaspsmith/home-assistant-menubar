import Foundation
import Security

/// The long-lived access token, in the login Keychain. Never UserDefaults: a
/// defaults plist is readable by anything running as this user, and the token
/// is full API access to the house.
enum Keychain {
    static let service = "com.nicholaspsmith.Homestead"
    static let account = "ha-token"

    enum Failure: Error {
        case status(OSStatus)
    }

    static func token() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let token = String(data: data, encoding: .utf8), !token.isEmpty
        else { return nil }
        return token
    }

    /// Always replaces rather than updates: the access control is set when an
    /// item is created, and an update would leave whatever ACL the old item had.
    static func setToken(_ token: String) throws {
        SecItemDelete(baseQuery() as CFDictionary)

        var insert = baseQuery()
        insert[kSecValueData as String] = Data(token.utf8)
        if let access = unpromptedAccess() {
            insert[kSecAttrAccess as String] = access
        }
        let status = SecItemAdd(insert as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.status(status) }
    }

    /// An access policy that does not interrogate the caller — the same thing
    /// `security add-generic-password -A` produces.
    ///
    /// The default policy trusts exactly the binary that created the item, and
    /// every rebuild is a different binary, so each one asked for the login
    /// password before the app could read its own token. A stable signing
    /// identity does not help: it keeps the *designated requirement* stable,
    /// which is what TCC honours, but the keychain ACL checks the application
    /// itself.
    ///
    /// The trade-off is real and worth stating: any process running as this
    /// user can now read the token without a prompt. That is the same exposure
    /// as a 0600 file in Application Support, and still far better than a
    /// defaults plist — but it is not the keychain's strongest setting.
    private static func unpromptedAccess() -> SecAccess? {
        var access: SecAccess?
        guard SecAccessCreate("Homestead" as CFString, [] as CFArray, &access) == errSecSuccess,
              let access,
              let acls = SecAccessCopyMatchingACLList(access, kSecACLAuthorizationDecrypt) as? [SecACL]
        else { return nil }

        for acl in acls {
            // A nil application list means "any application"; an empty one would
            // mean "none", which prompts for everything.
            SecACLSetContents(acl, nil, "Homestead" as CFString, [])
        }
        return access
    }

    /// Rewrite an item created before the access policy above, so the prompt
    /// stops after one last appearance. Returns true when it did something.
    @discardableResult
    static func migrateAccessIfNeeded(defaults: UserDefaults = .standard) -> Bool {
        let flag = "TokenAccessMigrated"
        guard !defaults.bool(forKey: flag) else { return false }
        guard let existing = token() else { return false }   // nothing to migrate yet
        try? setToken(existing)
        defaults.set(true, forKey: flag)
        return true
    }

    static func deleteToken() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
