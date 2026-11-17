import SwiftUI

@main
struct CapystoreSafariApp: App {
    var body: some Scene {
        WindowGroup {
            EnableView()
        }
        .defaultSize(width: 480, height: 440)
    }
}

/// The container app exists so Safari has something to load the extension from.
/// Turning the extension on happens in Safari, not in this window.
private struct EnableView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Save to Capystore")
                .font(.title2.weight(.semibold))
            Text("This app carries the Safari extension. After it is built, enable it in Safari:")
            VStack(alignment: .leading, spacing: 8) {
                Text("1. Safari → Settings → Advanced → Show features for web developers")
                Text("2. Develop → Allow Unsigned Extensions")
                Text("3. Safari → Settings → Extensions → turn on Save to Capystore")
                Text("4. Click the toolbar button and choose Sign in")
            }
            Text("Sign-in opens Capystore in a tab. Approve it there. The extension never reads the cookies of the site you are saving from.")
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
