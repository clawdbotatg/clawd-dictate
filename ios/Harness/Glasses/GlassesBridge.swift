// 👓 The page's glasses button talks to this over `webkit.messageHandlers.glasses`.
// Glasses = display + touch pads. Mic = the phone's current input (AirPods when
// connected), listened to natively so it keeps working with the phone locked.
//
// Touch pads (on the arm ends, behind the ears):
//   single tap (either side)  start talking / stop and send
//   hold                      talk while held, send on release
//   double tap left / right   previous / next session
//
// page → app  {op:"start"} {op:"stop"}   👓 on / off
//             {op:"show", text}          put text on the glasses (latest wins, throttled)
//             {op:"sent"}                (ignored)
// app → page  window.__glasses({type:"state", on, connected, status, mic})
//             window.__glasses({type:"send", text})     what you said → send it
//             window.__glasses({type:"tab", dir})       -1 / +1
import Foundation
import UIKit
import WebKit

@MainActor
final class GlassesBridge: NSObject, WKScriptMessageHandler {
    weak var webView: WKWebView?
    private var g1: G1?
    private let listener = GlassesListener()
    private var on = false
    private var statusTimer: Timer?
    private var ticks = 0

    // show() throttle: one BLE write at a time, newest text wins
    private var pendingShow: String?
    private var showing = false

    func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let op = body["op"] as? String else { return }
        switch op {
        case "start": Task { await start() }
        case "stop": Task { await stop() }
        case "show": if !listener.talking { show(body["text"] as? String ?? "") }
        default: break
        }
    }

    static func log(_ s: String) { WebView.Coordinator.log("[g1] " + s) }

    private func start() async {
        guard !on else { return }
        Self.log("start")
        on = true
        let g = g1 ?? G1()
        g1 = g
        g.onEvent = { [weak self] side, name in
            Self.log("event \(side.rawValue) \(name)")
            guard let self, self.on else { return }
            self.handle(side: side.rawValue, name: name)
        }
        listener.onText = { [weak self] t in
            guard let self, self.listener.talking else { return }
            self.show(t.isEmpty ? "Listening..." : "> " + String(t.suffix(190)))
        }
        if await GlassesListener.authorize() {
            do { try listener.openMic() } catch { Self.log("mic failed: \(error.localizedDescription)") }
        } else {
            Self.log("mic/speech permission denied")
        }
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        for _ in 0..<40 where !g.connected { try? await Task.sleep(nanoseconds: 500_000_000) }
        Self.log("connected=\(g.connected) mic=\(listener.inputName)")
        postState()
        if g.connected && on { show("Tap to talk, tap to send.\nDouble tap L/R: switch session.") }
    }

    private func handle(side: String, name: String) {
        switch name {
        case "single_tap":
            if listener.talking { Task { await finishTalking() } } else { startTalking() }
        case "long_press_start":
            if !listener.talking { startTalking() }
        case "long_press_end":
            if listener.talking { Task { await finishTalking() } }
        case "double_tap":
            if listener.talking { Task { _ = await listener.stopTalking(); show("Cancelled") } }
            post(["type": "tab", "dir": side == "L" ? -1 : 1])
        default: break
        }
    }

    private func startTalking() {
        guard listener.micOpen else { show("No mic. Reopen the app and allow the mic."); return }
        listener.startTalking()
        show("Listening... (\(listener.inputName))")
    }

    private func finishTalking() async {
        let text = await listener.stopTalking().trimmingCharacters(in: .whitespacesAndNewlines)
        Self.log("heard: \(text)")
        if text.isEmpty { show("Didn't catch that."); return }
        show("Sent: " + String(text.prefix(150)))
        post(["type": "send", "text": text])
    }

    private func stop() async {
        guard on else { return }
        on = false
        Self.log("stop")
        statusTimer?.invalidate(); statusTimer = nil
        listener.closeMic()
        if let g = g1, g.connected { await g.clear() }
        postState()
    }

    private func tick() {
        postState()
        ticks += 1
        if ticks % 30 == 0 {   // is the app (and page) still alive with the phone locked?
            let st = ["active", "inactive", "background"][UIApplication.shared.applicationState.rawValue]
            Self.log("alive app=\(st) glasses=\(g1?.connected ?? false) mic=\(listener.inputName) open=\(listener.micOpen)")
        }
    }

    private func postState() {
        post(["type": "state", "on": on, "connected": g1?.connected ?? false,
              "status": g1?.status ?? "", "mic": listener.inputName])
    }

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
