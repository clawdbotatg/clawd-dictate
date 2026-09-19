// One full-screen WKWebView pointed at the relay. The three things a plain web
// view gets wrong for this page, fixed here:
//   1. mic — `requestMediaCapturePermissionFor` GRANTS for the relay origin, so
//      the page's getUserMedia never shows WebKit's per-launch prompt (iOS's own
//      one-time app permission still happens the first time, as it should);
//   2. audio — the 🔊 voice plays `new Audio(url)` outside a tap; without
//      `mediaTypesRequiringUserActionForPlayback = []` it would be silent;
//   3. links — the page opens PRs / breakouts with window.open + target=_blank;
//      a WKWebView drops those unless `createWebViewWith` hands them to Safari.
import SwiftUI
import WebKit

struct WebView: UIViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(home: url) }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.websiteDataStore = .default()          // persistent: passkey session, localStorage, ⚙️ prefs
        cfg.applicationNameForUserAgent = "clawd-harness-app"   // lets the page know it's inside the app
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        // 4. the page's console → `Library/web.log` in this app's container (pull:
        //    `xcrun devicectl device copy from --device <id> --source Library/web.log
        //    --destination x.log --domain-type appDataContainer --domain-identifier
        //    com.clawd.dictate.harness`). There is no other way to see what the page
        //    does on the phone (09-18: "I hit the mic button, nothing happens").
        cfg.userContentController.add(context.coordinator, name: "log")
        cfg.userContentController.addUserScript(WKUserScript(source: Coordinator.consoleHook, injectionTime: .atDocumentStart, forMainFrameOnly: true))

        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.uiDelegate = context.coordinator
        wv.navigationDelegate = context.coordinator
        wv.isOpaque = false
        wv.backgroundColor = .black
        wv.scrollView.backgroundColor = .black
        wv.scrollView.contentInsetAdjustmentBehavior = .never   // the page reads env(safe-area-inset-*) itself
        wv.scrollView.bounces = false                            // the page has its own scroll regions; no rubber-band
        wv.allowsBackForwardNavigationGestures = false           // hash routing; an edge swipe would leave the app's page
        wv.load(URLRequest(url: url))
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler {
        let home: URL
        init(home: URL) { self.home = home }

        static let consoleHook = """
        (() => {
          const post = (lvl, args) => { try { window.webkit.messageHandlers.log.postMessage(lvl + ' ' + args.map(a => { try { return typeof a === 'string' ? a : (a && a.stack) || JSON.stringify(a); } catch { return String(a); } }).join(' ').slice(0, 800)); } catch {} };
          for (const lvl of ['log', 'warn', 'error']) { const orig = console[lvl].bind(console); console[lvl] = (...a) => { orig(...a); post(lvl, a); }; }
          window.addEventListener('error', e => post('uncaught', [e.message, e.filename + ':' + e.lineno]));
          window.addEventListener('unhandledrejection', e => post('unhandled', [(e.reason && (e.reason.stack || e.reason.message)) || String(e.reason)]));
          post('log', ['page start ' + location.hash]);
        })();
        """
        private static let logURL: URL? = {
            guard let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else { return nil }
            return lib.appendingPathComponent("web.log")
        }()
        private static let stamp: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f }()
        private static let logQueue = DispatchQueue(label: "harness.web.log")
        static func log(_ msg: String) {
            guard let url = logURL else { return }
            let line = "\(stamp.string(from: Date())) \(msg)\n"
            logQueue.async {
                if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
                else { try? line.data(using: .utf8)!.write(to: url) }
                if let a = try? FileManager.default.attributesOfItem(atPath: url.path), (a[.size] as? Int ?? 0) > 400_000,
                   let d = try? Data(contentsOf: url) { try? d.suffix(200_000).write(to: url) }
            }
        }
        func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "log" { Coordinator.log(String(describing: message.body)) }
        }

        private func isHome(_ host: String?) -> Bool {
            guard let h = host?.lowercased(), let mine = home.host?.lowercased() else { return false }
            return h == mine
        }

        // 1. the mic (iOS 15+). Grant only our origin, only the microphone; anything
        //    else falls back to WebKit's own prompt.
        func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                     initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                     decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            decisionHandler(isHome(origin.host) && type == .microphone ? .grant : .prompt)
        }

        // 3. window.open / target=_blank → Safari. Returning nil keeps this view put.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let u = navigationAction.request.url, u.scheme?.hasPrefix("http") == true {
                UIApplication.shared.open(u)
            }
            return nil
        }

        // A tapped link that leaves the relay's host also goes to Safari. The page
        // itself (same host, hash routes, its own fetches) is never intercepted.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated,
               navigationAction.targetFrame?.isMainFrame ?? true,
               let u = navigationAction.request.url, !isHome(u.host) {
                UIApplication.shared.open(u)
                return decisionHandler(.cancel)
            }
            decisionHandler(.allow)
        }

        // WebKit killed the content process (memory pressure in the background):
        // come back to the page, not a white screen.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            webView.load(URLRequest(url: home))
        }

        // The page never calls alert()/confirm(); if it ever does, don't hang the view.
        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            completionHandler()
        }
        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            completionHandler(true)
        }
    }
}
