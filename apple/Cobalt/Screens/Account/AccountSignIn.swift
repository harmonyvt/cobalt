import AuthenticationServices
import CobaltKit
import SwiftUI

/// Cloudflare Access in SwiftUI's web authentication session (APP-API-CONTRACT 42.3): the system sheet on iPhone and
/// iPad, its window on the Mac, anchored by SwiftUI. Not ephemeral (the default), so Access's cookie is reused and a
/// second sign-in is usually one tap. Closing the sheet is `AccountError.cancelled`.
@MainActor
struct SystemWebSignIn: WebSignIn {
    let session: WebAuthenticationSession

    func open(_ url: URL, callbackScheme: String) async throws -> URL {
        do {
            return try await session.authenticate(using: url, callbackURLScheme: callbackScheme)
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            throw AccountError.cancelled
        }
    }
}

/// One way to run the sign-in from any button (the sign-in screen, the pinned button, the move-over, settings): the
/// preview sheet in previews, the system's otherwise.
@MainActor
enum AccountSignIn {
    enum Outcome: Equatable {
        case signedIn
        case cancelled
        case failed(String)
    }

    static func sheet(for model: AppModel, session: WebAuthenticationSession) -> any WebSignIn {
        if model.isPreview { return PreviewWebSignIn() }
        return SystemWebSignIn(session: session)
    }

    /// Runs `AppModel.signIn(using:)` and says how it went in words the screen can show.
    static func run(_ model: AppModel, session: WebAuthenticationSession) async -> Outcome {
        do {
            try await model.signIn(using: sheet(for: model, session: session))
            return .signedIn
        } catch {
            guard let line = Copy.Account.message(for: error) else { return .cancelled }
            return .failed(line)
        }
    }
}
