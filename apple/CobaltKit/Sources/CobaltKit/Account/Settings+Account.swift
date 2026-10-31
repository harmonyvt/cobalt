import Foundation

// Accounts on this device (APP-API-CONTRACT 42.6). The session token is kept exactly where a pasted key is kept (the
// keychain's `api-key` item, bound to the server's host), so the share extension, Shortcuts and background saves read it
// with no change. Three small facts sit beside it in the app-group defaults.
extension Settings {
    nonisolated static let signedInKey = "account.signedIn"
    nonisolated static let moveOverAskedKey = "account.moveOverAsked"
    nonisolated static let sessionPrefixKey = "account.sessionPrefix"

    /// This device has signed in at least once. Then a missing token means "signed out" (the pinned "sign in again"),
    /// not first launch (the sign-in screen).
    public var hasSignedIn: Bool {
        get {
            access(keyPath: \.hasSignedIn)
            return defaults.bool(forKey: Settings.signedInKey)
        }
        set { withMutation(keyPath: \.hasSignedIn) { defaults.set(newValue, forKey: Settings.signedInKey) } }
    }

    /// "capystore has accounts now" was shown on this device (once, whatever the answer).
    public var moveOverAsked: Bool {
        get {
            access(keyPath: \.moveOverAsked)
            return defaults.bool(forKey: Settings.moveOverAskedKey)
        }
        set { withMutation(keyPath: \.moveOverAsked) { defaults.set(newValue, forKey: Settings.moveOverAskedKey) } }
    }

    /// The stored credential is the session this device signed in for (not a key pasted before accounts). Compared by
    /// the token's first 8 characters, which the server shows anyway.
    public var keyIsSession: Bool {
        guard let key = apiKey(), let prefix = defaults.string(forKey: Settings.sessionPrefixKey), !prefix.isEmpty else { return false }
        return key.hasPrefix(prefix)
    }

    /// Keeps the token `POST /auth/exchange` answered in place of whatever key was stored (the old pasted key is gone from
    /// the keychain once this returns). Throws `.couldNotSave` when the keychain refuses; what was there stays.
    func storeSession(token: String) throws(KeyInputError) {
        try setAPIKey(pasted: token)
        defaults.set(String(token.lowercased().prefix(8)), forKey: Settings.sessionPrefixKey)
        hasSignedIn = true
    }

    /// The token is gone (signed out here). `hasSignedIn` stays, so the app shows "sign in again", not first launch.
    func forgetSession() {
        clearAPIKey()
        defaults.removeObject(forKey: Settings.sessionPrefixKey)
    }

    /// Previews: the stored preview key reads as a session this device signed in for.
    func markPreviewSession() {
        if let key = apiKey() { defaults.set(String(key.prefix(8)), forKey: Settings.sessionPrefixKey) }
        hasSignedIn = true
    }
}
