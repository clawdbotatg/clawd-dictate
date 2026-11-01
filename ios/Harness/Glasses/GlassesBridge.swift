// 👓 The page's glasses button talks to this over `webkit.messageHandlers.glasses`.
//
// page → app  {op:"start"}            connect the glasses, turn their mic on, listen
//             {op:"stop"}             mic off, stop listening
//             {op:"show", text}       put text on the glasses (latest wins, throttled)
//             {op:"sent"}             the page sent the box: clear the heard words
// app → page  window.__glasses({type:"state", on, connected, status})
//             window.__glasses({type:"text", text})     words heard since the last send
//             window.__glasses({type:"send"})           glasses tap = send the box
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
        case "sent": listener.reset()
        default: break
        }
    }

    private func start() async {
        guard !on else { return }
        guard await GlassesListener.authorize() else {
            post(["type": "state", "on": false, "connected": false, "status": "Allow Speech Recognition in Settings"])
            return
        }
        on = true
        let g = g1 ?? G1()
        g1 = g
        g.onMic = { [weak self] d in self?.listener.feed(d) }
        g.onEvent = { [weak self] _, name in
            guard let self, self.on else { return }
            if name == "single_tap" { self.post(["type": "send"]) }
        }
        listener.onText = { [weak self] t in
            guard let self, self.on else { return }
            self.post(["type": "text", "text": t])
            if !t.isEmpty { self.show("> " + t) }
        }
        listener.start()
        // wait for the BLE link (up to 20 s), then open the mic
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.postState() }
        }
        for _ in 0..<40 where !g.connected { try? await Task.sleep(nanoseconds: 500_000_000) }
        postState()
        if g.connected && on {
            await g.mic(true)
            show("Listening. Tap the arm to send.")
        }
    }

    private func stop() async {
        guard on else { return }
        on = false
        listener.stop()
        statusTimer?.invalidate(); statusTimer = nil
        if let g = g1, g.connected {
            await g.mic(false)
            await g.clear()
        }
        postState()
    }

    private func postState() {
        post(["type": "state", "on": on, "connected": g1?.connected ?? false,
              "status": g1?.status ?? ""])
        // mic re-arm after a reconnect
        if on, let g = g1, g.connected, statusTimer != nil, !micArmed {
            micArmed = true
            Task { await g.mic(true) }
        }
        if !(g1?.connected ?? false) { micArmed = false }
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
