// The recorder: mic → 16 kHz Int16 PCM → Deepgram nova-3 over a WebSocket,
// keyterm-biased; results (interim/final, rules applied) go to the App Group
// mailbox for the keyboard.
//
// THE GUARANTEE (Austin, 2026-09-15: "100% sure my voice isn't going to the
// server when I don't mean it to"). Read this file top to bottom and hold it
// to these four facts:
//   1. The microphone tap exists, and the audio engine runs, ONLY between
//      openMic() and closeMic(). There is no other code that touches input.
//   2. stop() calls closeMic() FIRST, synchronously — the tap is removed, the
//      engine stopped and the audio session deactivated before anything else
//      happens. From that instant no audio buffer exists to send. The orange
//      dot goes out with it: no dot = no mic, and that's iOS saying so.
//   3. The only place audio is sent is the tap closure, and it additionally
//      refuses unless `listening` is true and a socket exists.
//   4. The socket is opened in openDeepgram() and closed in commit(), 1.2 s
//      after stop() — that window only flushes Deepgram's transcript of audio
//      sent BEFORE stop(); the mic is already gone.
// There is no idle hold, no parking, no background keep-alive: the app does
// nothing between dictations. iOS refuses to start a mic from the background,
// so each dictation begins with a hop through this app (the keyboard does it).
import AVFoundation
import Foundation
import UIKit

final class Session: NSObject, ObservableObject {
    static let shared = Session()

    @Published var state = "idle"
    @Published var live = ""
    @Published var listening = false
    var vocab = Vocab.cached()

    private let engine = AVAudioEngine()
    private var ws: URLSessionWebSocketTask?
    private var converter: AVAudioConverter?
    private var finals: [String] = []
    private var interim = ""
    private var cmdObserver: AnyObject?
    private var lastCmd = ""
    private var dictId = ""                 // the dictation being served (the keyboard's start nonce, or "app")

    override init() {
        super.init()
        cmdObserver = Shared.observe(Shared.noteCmd) { [weak self] in self?.onCmd() }
        onCmd()   // a command may already be waiting (we were launched for it)
    }

    // MARK: mailbox
    private func publish(_ s: String? = nil) {
        let d = Shared.defaults
        if let s = s { state = s; d.set(s, forKey: Shared.kState) }
        d.set(dictId, forKey: Shared.kDict)
        d.set(vocab.fix(interim), forKey: Shared.kInterim)
        d.set(vocab.fix(finals.joined(separator: " ")), forKey: Shared.kDone)
        Shared.bump()
        Shared.post(Shared.noteText)
        live = vocab.fix((finals + (interim.isEmpty ? [] : [interim])).joined(separator: " "))
    }

    private func onCmd() {
        let cmd = Shared.defaults.string(forKey: Shared.kCmd) ?? ""
        guard cmd != lastCmd, !cmd.isEmpty else { return }
        lastCmd = cmd
        let id = String(cmd.split(separator: ":", maxSplits: 1).last ?? "")
        if cmd.hasPrefix("start") { start(id: id) } else if cmd.hasPrefix("stop") { stop() }
    }

    // MARK: words
    func refreshVocab() {
        let d = Shared.defaults
        var req = URLRequest(url: URL(string: Shared.relay + "/docs/get?name=stt-words.txt")!)
        req.setValue("Bearer " + Secrets.docsCredential, forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            if let data = data, (resp as? HTTPURLResponse)?.statusCode == 200, let s = String(data: data, encoding: .utf8) {
                d.set(s, forKey: Shared.kWords)
                DispatchQueue.main.async { self.vocab = Vocab.cached() }
            }
        }.resume()
        URLSession.shared.dataTask(with: URL(string: Shared.baseTermsURL)!) { data, resp, _ in
            if let data = data, (resp as? HTTPURLResponse)?.statusCode == 200, let s = String(data: data, encoding: .utf8) {
                d.set(s, forKey: Shared.kBaseHTML)
                DispatchQueue.main.async { self.vocab = Vocab.cached() }
            }
        }.resume()
    }

    // MARK: start / stop
    func start(id: String = "app") {
        if listening {
            if id == dictId { return }        // the hop re-issues the start we're already serving
            finishNow()                       // another field's dictation: close it, its text stays where it was typed
        }
        dictId = id
        finals = []; interim = ""
        Shared.defaults.set(Date(), forKey: Shared.kStarted)
        publish("starting")
        refreshVocab()                        // a word added in the harness ⚙️ reaches the NEXT dictation
        AVAudioApplication.requestRecordPermission { [weak self] ok in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard ok else { self.publish("error: microphone not allowed — Settings → clawd dictate → Microphone"); return }
                do { try self.openMic() } catch {
                    // iOS won't let a background app START the mic — the keyboard hops us to the front and asks again
                    self.publish("error: wake")
                    return
                }
                self.openDeepgram()
                self.listening = true
                self.publish("listening")
            }
        }
    }

    func stop() {
        guard listening else { return }
        listening = false
        closeMic()                            // (2) FIRST. No mic, no buffers, no dot.
        ws?.send(.string(#"{"type":"CloseStream"}"#)) { _ in }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.commit() }   // (4) flush the tail, then close the socket
    }

    /// End the open dictation at once (no tail): what's typed so far is its final.
    private func finishNow() {
        listening = false
        closeMic()
        ws?.send(.string(#"{"type":"CloseStream"}"#)) { _ in }
        commit()
    }

    private func commit() {
        guard !listening else { return }
        let text = vocab.fix((finals + (interim.isEmpty ? [] : [interim])).joined(separator: " "))
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        interim = ""
        Shared.defaults.set(text, forKey: Shared.kFinal)
        publish("idle")
        ws?.cancel(with: .normalClosure, reason: nil); ws = nil
        finals = []
        live = text
    }

    // MARK: audio — (1) the ONLY code that touches the microphone
    private func openMic() throws {
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .allowBluetoothHFP, .defaultToSpeaker])
        try s.setActive(true)
        let input = engine.inputNode
        let inFmt = input.outputFormat(forBus: 0)
        let outFmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
        converter = AVAudioConverter(from: inFmt, to: outFmt)
        input.installTap(onBus: 0, bufferSize: 4096, format: inFmt) { [weak self] buf, _ in
            // (3) the only send of audio anywhere — and only while listening, to an open socket
            guard let self = self, self.listening, let conv = self.converter, let ws = self.ws else { return }
            let frames = AVAudioFrameCount(Double(buf.frameLength) * 16000 / inFmt.sampleRate) + 16
            guard let out = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: frames) else { return }
            var err: NSError?
            var consumed = false
            conv.convert(to: out, error: &err) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true; status.pointee = .haveData; return buf
            }
            guard err == nil, out.frameLength > 0, let ch = out.int16ChannelData else { return }
            let data = Data(bytes: ch[0], count: Int(out.frameLength) * 2)
            ws.send(.data(data)) { _ in }
        }
        engine.prepare()
        try engine.start()
    }

    private func closeMic() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
        converter = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: deepgram
    private func deepgramURL() -> URL {
        var c = URLComponents(string: "wss://api.deepgram.com/v1/listen")!
        var q = [URLQueryItem(name: "model", value: "nova-3"), URLQueryItem(name: "language", value: "en"),
                 URLQueryItem(name: "encoding", value: "linear16"), URLQueryItem(name: "sample_rate", value: "16000"),
                 URLQueryItem(name: "channels", value: "1"), URLQueryItem(name: "smart_format", value: "true"),
                 URLQueryItem(name: "interim_results", value: "true"), URLQueryItem(name: "endpointing", value: "300")]
        q += vocab.terms.map { URLQueryItem(name: "keyterm", value: $0) }
        c.queryItems = q
        return c.url!
    }

    private func openDeepgram() {
        var req = URLRequest(url: deepgramURL())
        req.setValue("Token " + Secrets.deepgramKey, forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.webSocketTask(with: req)
        ws = task
        task.resume()
        receive(task)
    }

    private func receive(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self = self, self.ws === task else { return }
            switch result {
            case .failure(let e):
                DispatchQueue.main.async {
                    if self.listening { self.listening = false; self.closeMic(); self.publish("error: deepgram — \(e.localizedDescription)"); self.commit() }
                }
                return
            case .success(let msg):
                if case .string(let s) = msg, let d = s.data(using: .utf8),
                   let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], j["type"] as? String == "Results" {
                    let t = ((((j["channel"] as? [String: Any])?["alternatives"] as? [[String: Any]])?.first)?["transcript"] as? String ?? "")
                        .trimmingCharacters(in: .whitespaces)
                    let isFinal = j["is_final"] as? Bool ?? false
                    DispatchQueue.main.async {
                        if isFinal { if !t.isEmpty { self.finals.append(t) }; self.interim = "" } else { self.interim = t }
                        self.publish()
                    }
                }
                self.receive(task)
            }
        }
    }
}
