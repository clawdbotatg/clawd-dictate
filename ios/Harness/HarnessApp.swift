// clawd harness — the phone app that IS the harness page. It exists for one
// reason: a home-screen web app on iOS asks for the microphone on EVERY launch
// (WebKit 215884) and there is no "always allow". A native WKWebView is asked
// once by iOS (the normal mic prompt, for THIS app) and then `WebView` answers
// the page's getUserMedia itself — never again a prompt.
//
// Everything else is the same page every browser gets (`Secrets.relay`, fleet
// mode, the passkey): the relay's /.well-known/apple-app-site-association names
// this app (FLEET_AASA_APPS on the box) and Harness.entitlements (generated,
// gitignored) carries `webcredentials:<relay host>` — without BOTH, WebAuthn in
// a WKWebView fails with NotAllowedError and the passkey gate never opens.
import SwiftUI

/// No third-party keyboards in THIS app (Austin, 09-18: "I wasn't using it
/// here anyway"): the clawd keyboard auto-dictates whenever it appears, so a
/// tap on the page's 🎤 (which focuses the composer) raised it and started a
/// SECOND dictation of the same speech through the dictate app — two engines
/// writing one box (the sixfold interim), and a fight over the microphone.
final class HarnessAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, shouldAllowExtensionPointIdentifier id: UIApplication.ExtensionPointIdentifier) -> Bool {
        id != .keyboard
    }
}

@main
struct ClawdHarnessApp: App {
    @UIApplicationDelegateAdaptor(HarnessAppDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup {
            WebView(url: URL(string: Secrets.relay + "/")!)
                .padding(.bottom, 15)            // the screen's rounded corners clip the page's bottom bar; a sliver of black keeps its buttons whole (Austin, 09-17)
                .ignoresSafeArea()               // viewport-fit=cover: the page owns the notch + home bar
                .background(Color.black)
                .preferredColorScheme(.dark)     // light status-bar text over the black page
                .persistentSystemOverlays(.hidden)
        }
    }
}
