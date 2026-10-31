import CobaltKit
import Foundation

/// Copy for accounts (APP-API-CONTRACT 42; mockup `accounts/mockup.html`): the sign-in screen, the pinned "sign in again",
/// the move-over and settings › account. All lowercase, all new.
extension Copy {
    enum Account {
        // MARK: sign in (first launch)

        static let tagline = "sign in to your library"
        static let signIn = "sign in"
        static let signInHint = "opens cloudflare access, like the website: an emailed code."
        static let oldKey = "have an old api key?"
        static let oldKeyTitle = "use an old api key"
        static let oldKeyBody = "copy a key from capystore on the web (settings → api keys), then paste it here. you can switch to your account any time."
        static let pasteKey = "paste key"
        static let cancel = "cancel"

        // MARK: signed out

        static let signInAgain = "sign in again"
        static let signingIn = "signing in…"
        static let signedOutHint = "signed out. offline files still work; sign in to save, share and sync."
        static let signedIn = "signed in"
        static let signedInAgain = "signed in again, right where you were"

        // MARK: move-over

        static let moveTitle = "capystore has accounts now"
        static var moveBody: String { "this \(Copy.device) uses a pasted api key. switch it to your account and you'll never paste a key again." }
        static let moveLibrary = "your library stays exactly as it is"
        static var moveDevices: String { "this \(Copy.device) shows up in devices, so you can sign it out from anywhere" }
        static let moveOldKey = "the old key keeps working until you revoke it in keys for tools"
        static let moveSwitch = "sign in to switch"
        static let moveLater = "later"
        static var switched: String { "this \(Copy.device) now uses your account" }

        // MARK: settings › account

        static let group = "account"
        static let through = "signed in through"
        static let access = "cloudflare access"
        static let throughAccess = "through cloudflare access"
        static let email = "email"
        static var usesOldKey: String { "this \(Copy.device) uses an old api key" }
        static let switchNow = "sign in to switch"
        static let signedOutRow = "signed out"
        static let accountFooter = "this device stays signed in until it's unused for 90 days, or you sign it out."

        static let devicesGroup = "devices"
        static let thisDevice = "this device"
        static let signOutDevice = "sign out"
        static let signOutOthers = "sign out all other devices"
        static let devicesFooter = "everything signed in to your account. a device that's been away 90 days is signed out by itself."

        static let keysGroup = "keys for tools"
        static let oldPaste = "old paste"
        static let revoke = "revoke"
        static let noKeys = "no keys yet"
        static let keysFooter = "for things that can't sign in: claude code's mcp, shortcuts, curl. make keys on the web: capystore → settings → api keys."
        static func oldPasteNote(_ n: Int) -> String {
            n == 1
                ? "1 key was pasted into an app before accounts. that app uses your account now: revoke the old key when you're ready."
                : "\(n) keys were pasted into apps before accounts. those apps use your account now: revoke the old keys when you're ready."
        }

        static let privateLinks = "private links don't need an account: the link is the key. signing out doesn't stop them; rotate a link to cut it off."
        static let signOut = "sign out"
        static let loading = "loading your account…"
        static let loadFailed = "couldn't load your account."
        static let retry = "try again"

        /// "2 h ago · australia"
        static func sessionLine(_ s: AccountSession) -> String {
            var parts: [String] = []
            if s.current { parts.append("now") } else if let used = s.lastUsedAt { parts.append(when(used)) }
            if let code = s.country, let country = Locale.current.localizedString(forRegionCode: code) {
                parts.append(country.lowercased())
            }
            return parts.joined(separator: " · ")
        }

        /// "3f9a1c2e… · used 3 h ago"
        static func keyLine(_ k: AccountKey) -> String {
            let used = k.lastUsedAt.map { "used \(when($0))" } ?? "never used"
            return k.prefix.isEmpty ? used : "\(k.prefix)\u{2026} · \(used)"
        }

        static func when(_ date: Date) -> String {
            if abs(date.timeIntervalSinceNow) < 60 { return "just now" }
            let f = RelativeDateTimeFormatter()
            f.unitsStyle = .short
            return f.localizedString(for: date, relativeTo: Date()).lowercased()
        }

        // MARK: confirms

        static func signOutDeviceTitle(_ name: String) -> String { "sign out \(name)?" }
        static let signOutDeviceBody = "it's signed out on its next request. nothing in your library changes."
        static var signOutSelfTitle: String { "sign out of this \(Copy.device)?" }
        static let signOutSelfBody = "you'll sign in through cloudflare access to come back. files kept offline stay on this device."
        static func signOutOthersTitle(_ n: Int) -> String { n == 1 ? "sign out 1 other device?" : "sign out \(n) other devices?" }
        static let signOutOthersBody = "tool keys and private links keep working: revoke those separately."
        static func signOutOthersAction(_ n: Int) -> String { n == 1 ? "sign out 1 device" : "sign out \(n) devices" }
        static func revokeTitle(_ name: String) -> String { "revoke \(name)?" }
        static let revokeBody = "anything using it stops working at once. this can't be undone."

        // MARK: results

        static func signedOutDevice(_ name: String) -> String { "\(name) signed out" }
        static func signedOutOthers(_ n: Int) -> String { n == 1 ? "1 device signed out" : "\(n) devices signed out" }
        static func revoked(_ name: String) -> String { "\(name) revoked" }
        static let signedOut = "signed out"

        /// Why signing in or an account change did not happen. Nil for a closed sheet: the owner meant it.
        static func message(for error: Error) -> String? {
            switch AccountError.from(error) {
            case .cancelled: return nil
            case .badCallback: return "sign-in didn't finish. try again."
            case .codeInvalid: return "that sign-in ran out. try again."
            case .couldNotSave: return "couldn't keep the sign-in on this \(Copy.device). try again."
            case .notFound: return "that's already gone."
            case .offline: return "can't reach capystore. check your connection."
            case .failed: return "that didn't work. try again."
            }
        }
    }
}
