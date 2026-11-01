// 👓 The page's glasses button talks to this over `webkit.messageHandlers.glasses`.
//
// page → app  {op:"start"}            connect the glasses, turn their mic on, listen
//             {op:"stop"}             mic off, stop listening
//             {op:"show", text}       put text on the glasses (latest wins, throttled)
//             {op:"sent"}             the page sent the box: clear the heard words
// app → page  window.__glasses({type:"state", on, connected, status})
//             window.__glasses({type:"tap", side})      a single tap on a glasses arm
import Foundation
import WebKit

@MainActor
final class GlassesBridge: NSObject, WKScriptMessageHandler {
    weak var webView: WKWebView?
    private var g1: G1?
    private let listener = GlassesListener()
    private var on = false
    private var statusTimer: Timer?

    // show() throttle: one BLE write at a time, newest text wins
    private var pendingShow: String?
    private var showing = false

    func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let op = body["op"] as? String else { return }
        switch op {
        case "start": Task { await start() }
        case "stop": Task { await stop() }
        case "show": show(body["text"] as? String ?? "")
        case "sent": break
        default: break
        }
    }

    static func log(_ s: String) { WebView.Coordinator.log("[g1] " + s) }
    private var micBytes = 0, micPackets = 0
    private var micDump = Data()

    private func start() async {
        guard !on else { return }
        Self.log("start")
        on = true
        let g = g1 ?? G1()
        g1 = g
        // 10-31: the glasses mic stream decodes to hiss (no words, same with Even's
        // own decoder), so listening uses the page's 🎤 (phone mic, Deepgram) for
        // now. The glasses are the display + the tap. GlassesListener stays for later.
        g.onEvent = { [weak self] side, name in
            Self.log("event \(side.rawValue) \(name)")
            guard let self, self.on else { return }
            if name == "single_tap" { self.post(["type": "tap", "side": side.rawValue]) }
        }
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.postState() }
        }
        for _ in 0..<40 where !g.connected { try? await Task.sleep(nanoseconds: 500_000_000) }
        Self.log("connected=\(g.connected)")
        postState()
        if g.connected && on { show("Tap the arm to talk.") }
    }

    private func stop() async {
        guard on else { return }
        on = false
        Self.log("stop")
        statusTimer?.invalidate(); statusTimer = nil
        if let g = g1, g.connected { await g.clear() }
        postState()
    }

    private func postState() {
        post(["type": "state", "on": on, "connected": g1?.connected ?? false,
              "status": g1?.status ?? ""])
    }
    private var micArmed = false

    private func show(_ text: String) {
        pendingShow = text
        guard !showing else { return }
        showing = true
        Task {
            while let t = pendingShow {
                pendingShow = nil
                if let g = g1, g.connected { await g.show(t) }
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
            showing = false
        }
    }

    private func post(_ msg: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: msg),
              let s = String(data: d, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("window.__glasses && window.__glasses(\(s))")
    }
}
