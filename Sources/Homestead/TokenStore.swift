import Foundation
import os

/// Where the Home Assistant token lives.
///
/// The Keychain is the default and the right answer for anyone running an
/// installed build. It is a poor answer for whoever is *developing* the app:
/// macOS pins a keychain item to the code signature of the binaries that have
/// touched it, and with a self-signed certificate that pin is the binary's
/// cdhash — which changes on every build. So each rebuild demands the login
/// password before the app can read its own token, and "Always Allow" only
/// whitelists the build that just asked.
///
/// There is no rebuild-stable keychain answer for a self-signed app: the
/// data-protection keychain (which has no ACLs at all) requires an entitlement
/// self-signed code cannot carry, and a stable partition needs a real Developer
/// ID team.
///
/// Hence the escape hatch: set
/// `defaults write com.nicholaspsmith.Homestead UseFileTokenStore -bool true`
/// and the token moves to a 0600 file instead. It is deliberately not the
/// default and deliberately not in the UI, because it *is* weaker — a file is
/// readable by anything running as you, goes into backups as plaintext, and is
/// not encrypted at rest. It is the right trade only on a machine that rebuilds
/// the app several times an hour.
enum TokenStore {
    static let useFileKey = "UseFileTokenStore"

    private static let log = Logger(subsystem: "com.nicholaspsmith.Homestead", category: "token")

    static func usesFile(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: useFileKey)
    }

    static var fileURL: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Homestead/ha-token")
    }

    static func token(defaults: UserDefaults = .standard) -> String? {
        guard usesFile(defaults: defaults) else { return Keychain.token() }
        // Fall back to the Keychain so turning the flag on does not look like
        // the app forgot its token; `migrateIfNeeded` moves it over.
        return fileToken() ?? Keychain.token()
    }

    static func setToken(_ token: String, defaults: UserDefaults = .standard) throws {
        guard usesFile(defaults: defaults) else {
            try Keychain.setToken(token)
            removeFile()
            return
        }
        try writeFile(token)
        Keychain.deleteToken()
    }

    /// Move an existing Keychain token into the file once the flag is turned
    /// on, so the change takes effect without re-pasting it.
    @discardableResult
    static func migrateIfNeeded(defaults: UserDefaults = .standard) -> Bool {
        guard usesFile(defaults: defaults), fileToken() == nil, let existing = Keychain.token() else { return false }
        do {
            try writeFile(existing)
            Keychain.deleteToken()
            log.info("moved the token out of the Keychain into a 0600 file")
            return true
        } catch {
            log.error("could not write the token file: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    // MARK: - The file

    private static func fileToken() -> String? {
        guard let data = try? Data(contentsOf: fileURL),
              let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty
        else { return nil }
        return token
    }

    private static func writeFile(_ token: String) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // Created 0600 in one step rather than written and then chmod-ed: an
        // atomic write lands a temporary file at the default 0644 and renames
        // it, which leaves a window — however short — where any other account
        // on the machine can read the token.
        try? FileManager.default.removeItem(at: fileURL)
        guard FileManager.default.createFile(atPath: fileURL.path,
                                             contents: Data(token.utf8),
                                             attributes: [.posixPermissions: 0o600])
        else { throw CocoaError(.fileWriteUnknown) }
    }

    private static func removeFile() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
