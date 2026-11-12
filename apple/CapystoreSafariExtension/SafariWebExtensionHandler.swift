import SafariServices

/// Safari requires a native handler class even when the extension does all of its work in the
/// web extension (the background service worker). Nothing here reads cookies or the page.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        context.completeRequest(returningItems: nil, completionHandler: nil)
    }
}
