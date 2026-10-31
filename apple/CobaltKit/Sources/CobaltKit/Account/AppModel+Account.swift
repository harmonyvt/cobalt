import Foundation

// Accounts in the app (APP-API-CONTRACT 42.6). Everything shows only on a server with `features.accounts`; elsewhere the
// old api key paste stays as it was.
//
//   first launch    no token, never signed in            the sign-in screen (`needsFirstSignIn`)
//   move-over       a pasted key, never signed in        "capystore has accounts now", once (`offersMoveOver`)
//   signed out      the token was refused (401), or      the screen stays; a pinned "sign in again" (`signInPinned`)
//                   this device signed out
extension AppModel {
    /// No token and this device never signed in: the sign-in screen stands in for the shell.
    public var needsFirstSignIn: Bool {
        capabilities.accounts && !settings.hasAPIKey && !settings.hasSignedIn
    }

    /// Signed out without leaving the screen: the token was refused (`key: invalid`), or this device signed out. What is
    /// already loaded and the offline files stay; "sign in again" stays pinned until it works.
    public var signInPinned: Bool {
        guard capabilities.accounts else { return false }
        if !settings.hasAPIKey { return settings.hasSignedIn }
        return capabilities.key == .invalid
    }

    /// A key pasted before accounts still works and this device never signed in: offer the switch, once.
    public var offersMoveOver: Bool {
        capabilities.accounts && settings.hasAPIKey && !settings.hasSignedIn && !settings.moveOverAsked
            && capabilities.key == .valid && !settings.keyIsSession
    }

    /// The whole of 42.3: a PKCE pair, Cloudflare Access in `web`, the code exchanged for this device's token, which
    /// replaces the stored key in the keychain (a pasted key goes to the server as `old_key`, so the web marks it "old
    /// paste"). Then the server is read again and the library reloads; the screen stays where it is.
    /// Throws `AccountError` (`.cancelled` when the owner closed the sheet).
    public func signIn(using web: any WebSignIn) async throws {
        guard !account.signingIn else { return }
        account.signingIn = true
        defer { account.signingIn = false }

        let verifier = AccountAuth.makeVerifier()
        let device = AccountDevice.current
        guard let start = AccountAuth.startURL(
            platform: device.platform, device: device.name, challenge: AccountAuth.challenge(for: verifier))
        else { throw AccountError.failed }

        let callback: URL
        do {
            callback = try await web.open(start, callbackScheme: AccountAuth.callbackScheme)
        } catch {
            throw AccountError.from(error)
        }
        guard let code = AccountAuth.code(from: callback) else { throw AccountError.badCallback }

        let oldKey = settings.keyIsSession ? nil : settings.apiKey()
        let answer: AuthExchange
        do {
            answer = try await ctx.client.exchangeSignIn(code: code, verifier: verifier, oldKey: oldKey)
        } catch {
            Telemetry.log(.warn, .net, "sign in exchange failed", data: ["error": .string(String(describing: AccountError.from(error)))])
            throw AccountError.from(error)
        }
        do {
            try settings.storeSession(token: answer.key)
        } catch {
            throw AccountError.couldNotSave
        }
        settings.moveOverAsked = true
        Telemetry.log(.info, .net, "signed in", data: ["platform": .string(device.platform), "replacedKey": .bool(oldKey != nil)])

        account.reset()
        await refreshServer()
        if capabilities.library { Task { await library.refresh() } }
        Task { await account.refresh() }
    }

    /// Signs this device out: the server revokes the session (`POST /auth/signout`; offline, it ends by itself after 90
    /// days unused), the token leaves the keychain, and the app is signed out with "sign in again" pinned.
    public func signOut() async {
        if settings.hasAPIKey { _ = try? await ctx.client.signOutSession() }
        settings.forgetSession()
        account.reset()
        var caps = capabilities
        caps.key = .missing
        caps.keyName = nil
        apply(caps)
        Telemetry.log(.info, .net, "signed out")
    }

    /// Any route answered `401 error.api.auth.key.invalid` (the real client's `AuthSignal`): ask `/capabilities` once
    /// with the token stored now, so a refusal that raced a fresh sign-in never signs the app out.
    func serverRefusedKey() {
        guard capabilities.accounts, capabilities.key != .invalid, !isCheckingServer else { return }
        Task { await refreshServer() }
    }
}
