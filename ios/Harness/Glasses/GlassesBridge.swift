// 👓 The page's glasses button talks to this over `webkit.messageHandlers.glasses`.
// Glasses = display + touch pads + mic (the LEFT arm's; the right one is static).
// If the glasses send no audio, the phone's current input (AirPods when
// connected) is used. All native, so it keeps working with the phone locked.
//
// Screen (5 lines): line 1 = which session ("3/8 title · working"), line 2 = its
// description, the rest = the text.
//
// Touch pads (on the arm ends, behind the ears):
//   single tap (either side)  start talking / stop and send
//   hold                      talk while held, send on release
//   double tap left / right   previous / next session
//
// page → app  {op:"start"} {op:"stop"}   👓 on / off
//             {op:"show", text, head?, desc?}   put text on the glasses (latest wins, throttled);
//                                        head/desc = the session lines, kept until replaced
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
    // session lines kept on top of every screen
    private var head = ""
    private var desc = ""
    // head tilt test (11-18): "UP" / "DOWN" in front of the session line
    private var headPos = ""
    private var lastText = ""
    private var lastTail = false

    // A double tap is reported more than once: a LEFT one comes from L, then R
    // ~20 ms later, then R again ~450 ms later; a RIGHT one comes from R twice.
    // So: wait a moment, call it left if L spoke at all, then ignore the echoes.
    private var tapWindow: Task<Void, Never>?
    private var tapSawLeft = false
    private var tapQuietUntil = Date.distantPast
    private var lastSingleTap = Date.distantPast
    private var talkID = 0

    func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let op = body["op"] as? String else { return }
        switch op {
        case "start": Task { await start() }
        case "stop": Task { await stop() }
        case "show":
            if let h = body["head"] as? String { head = h; desc = body["desc"] as? String ?? "" }
            if !listener.talking { show(body["text"] as? String ?? "") }
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
        g.onMic = { [weak self] d in self?.listener.feedLC3(d) }
        listener.onText = { [weak self] t in
            guard let self, self.listener.talking else { return }
            self.show(t.isEmpty ? "Listening..." : "> " + t, tail: true)
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
            guard Date().timeIntervalSince(lastSingleTap) > 0.6 else { return }   // the other arm's echo
            lastSingleTap = Date()
            if listener.talking { Task { await finishTalking() } } else { startTalking() }
        case "long_press_start":
            if !listener.talking { startTalking() }
        case "long_press_end":
            if listener.talking { Task { await finishTalking() } }
        case "head_up", "head_down":
            headPos = name == "head_up" ? "UP" : "DOWN"
            show(lastText, tail: lastTail)
        case "double_tap":
            guard Date() >= tapQuietUntil else { return }
            if side == "L" { tapSawLeft = true }
            guard tapWindow == nil else { return }
            tapSawLeft = side == "L"
            tapWindow = Task {
                try? await Task.sleep(nanoseconds: 150_000_000)
                let dir = tapSawLeft ? -1 : 1
                tapQuietUntil = Date().addingTimeInterval(0.9)
                tapWindow = nil
                Self.log("double tap -> \(dir)")
                if listener.talking {
                    talkID += 1
                    _ = await listener.stopTalking()
                    await g1?.mic(false)
                }
                guard on else { return }
                post(["type": "tab", "dir": dir])
            }
        default: break
        }
    }

    private func startTalking() {
        guard listener.micOpen else { show("No mic. Reopen the app and allow the mic."); return }
        let g = g1
        listener.startTalking(glasses: g?.connected == true)
        show("Listening...")
        talkID += 1
        let id = talkID
        guard listener.fromGlasses else { return }
        Task {
            await g?.mic(true)
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard id == talkID, listener.talking else { return }
            if listener.glassesPackets == 0 {
                Self.log("glasses mic silent, using \(listener.inputName)")
                await g?.mic(false)
                listener.usePhoneMic()
                show("Listening... (\(listener.inputName))")
                return
            }
            // the glasses may stop the mic by themselves: turn it back on
            while id == talkID, listener.talking {
                let n = listener.glassesPackets
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if id == talkID, listener.talking, listener.glassesPackets == n {
                    Self.log("glasses mic stopped, turning it back on")
                    await g?.mic(true)
                }
            }
        }
    }

    private func finishTalking() async {
        talkID += 1
        let mic = listener.micName, packets = listener.glassesPackets
        let text = await listener.stopTalking().trimmingCharacters(in: .whitespacesAndNewlines)
        await g1?.mic(false)
        Self.log("heard (\(mic), \(packets) packets): \(text)")
        if text.isEmpty { show("Didn't catch that."); return }
        show("Sent: " + text)
        post(["type": "send", "text": text])
    }

    private func stop() async {
        guard on else { return }
        on = false
        Self.log("stop")
        statusTimer?.invalidate(); statusTimer = nil
        talkID += 1
        listener.closeMic()
        if let g = g1, g.connected { await g.mic(false); await g.clear() }
        postState()
    }

    private func tick() {
        postState()
        ticks += 1
        if ticks % 30 == 0 {   // is the app (and page) still alive with the phone locked?
            let st = ["active", "inactive", "background"][UIApplication.shared.applicationState.rawValue]
            Self.log("alive app=\(st) glasses=\(g1?.connected ?? false) mic=\(listener.micName) open=\(listener.micOpen)")
        }
    }

    private func postState() {
        post(["type": "state", "on": on, "connected": g1?.connected ?? false,
              "status": g1?.status ?? "", "mic": listener.micName])
    }

    /// One screen: session line, its description, then as much text as fits
    /// (the start of it, or the end when `tail`).
    private func screen(_ text: String, tail: Bool) -> String {
        func oneLine(_ s: String) -> String {
            let t = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            return t.count > 38 ? String(t.prefix(35)) + "..." : t
        }
        let first = (headPos.isEmpty ? "" : "[\(headPos)] ") + head
        var top = [oneLine(first), oneLine(desc)].filter { !$0.isEmpty }
        if top.count == 2, top[0].lowercased().contains(top[1].lowercased()) { top.removeLast() }
        let room = G1P.linesPerPage - top.count
        var body = G1P.wrap(text)
        if body.count > room {
            body = tail ? Array(body.suffix(room)) : Array(body.prefix(room))
            if !tail, let last = body.last { body[room - 1] = String(last.prefix(35)) + "..." }
        }
        return (top + body).joined(separator: "\n")
    }

    private func show(_ text: String, tail: Bool = false) {
        lastText = text; lastTail = tail
        pendingShow = screen(text, tail: tail)
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
