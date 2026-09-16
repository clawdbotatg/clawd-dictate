// The recorder: mic → 16 kHz Int16 PCM → Deepgram nova-3 over a WebSocket,
// keyterm-biased; results (interim/final, rules applied) go to the App Group
// mailbox for the keyboard. After a dictation the audio session stays ACTIVE
// (silent) for idleMinutes so the app survives in the background and the next
// tap on the keyboard's 🎤 starts at once, without bouncing through this app.
import AVFoundation
import Foundation
import UIKit

final class Session: NSObject, ObservableObject {
    static let shared = Session()
    static let idleMinutes = 24 * 60

    @Published var state = "idle"
    @Published var live = ""
    @Published var listening = false
    var vocab = Vocab.cached()

    private let engine = AVAudioEngine()
    private var ws: URLSessionWebSocketTask?
    private var converter: AVAudioConverter?
    private var finals: [String] = []
    private var interim = ""
    private var alive = false
    private var heartbeat: Timer?
    private var idleTimer: Timer?
    private var cmdObserver: AnyObject?
    private var silence: AVAudioPlayer?     // parked: silence keeps us alive in the background WITHOUT the mic (no orange dot)
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
    func start(id: String = "app", force: Bool = false) {
        if listening {
            if id == dictId && !force { return }
            if id == dictId { finishNow() }   // the hop re-issues our own start: begin again, in the foreground now
            // a NEW dictation (another field's keyboard) while one is still open:
            // finish the old one under its own id, then begin fresh — its text
            // never lands in the new place
            finishNow()
        }
        dictId = id
        finals = []; interim = ""
        publish("starting")
        refreshVocab()                       // a word added in the harness ⚙️ reaches the NEXT dictation, not the next app launch
        if alive && !engine.isRunning {      // parked: the app is awake, the mic is not
            do { try openMic() } catch {
                // iOS won't let a background app START the mic — the keyboard hops us to the front and asks again
                publish("error: wake")
                return
            }
        }
        if !alive {
            // ask for the mic explicitly (the first time this is a system prompt)
            AVAudioApplication.requestRecordPermission { [weak self] ok in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    guard ok else { self.publish("error: microphone not allowed — Settings → clawd dictate → Microphone"); return }
                    do { try self.openAudio() } catch { self.publish("error: mic — \(error.localizedDescription)"); return }
                    self.beginStream()
                }
            }
            return
        }
        beginStream()
    }

    private func beginStream() {
        openDeepgram()
        listening = true
        publish("listening")
        armIdle()
    }

    func stop() {
        guard listening else { return }
        listening = false
        ws?.send(.string(#"{"type":"CloseStream"}"#)) { _ in }
        // the flush: finals trail CloseStream; commit after a short tail or when the server closes
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.commit() }
        armIdle()
    }

    /// End the open dictation at once (no tail): what's typed so far is its final.
    private func finishNow() {
        listening = false
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
        // The mic stays OPEN (orange dot) for idleMinutes: iOS refuses to reopen
        // it from the background (tested 2026-09-15 — parking it meant a hop into
        // the app every time). Audio is only STREAMED while listening: the tap
        // drops every buffer otherwise, nothing leaves the phone between dictations.
    }

    private func armIdle() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: Double(Session.idleMinutes) * 60, repeats: false) { [weak self] _ in
            guard let self = self, !self.listening else { return }
            self.closeAudio()
        }
    }

    // MARK: audio
    private func openAudio() throws {
        try openMic()
        alive = true
        heartbeat?.invalidate()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Shared.defaults.set(Date(), forKey: Shared.kAlive)
        }
        Shared.defaults.set(Date(), forKey: Shared.kAlive)
    }

    /// The mic, from a parked or fresh state: record category, tap, engine.
    private func openMic() throws {
        silence?.stop(); silence = nil
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .allowBluetoothHFP, .defaultToSpeaker])
        try s.setActive(true)
        let input = engine.inputNode
        let inFmt = input.outputFormat(forBus: 0)
        let outFmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
        converter = AVAudioConverter(from: inFmt, to: outFmt)
        input.installTap(onBus: 0, bufferSize: 4096, format: inFmt) { [weak self] buf, _ in
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

    /// Park: release the mic (orange dot off) but stay alive in the background
    /// by playing silence, so the next start needs no hop — if iOS lets a
    /// background app reopen the mic; if not, start() asks for the hop.
    private func parkMic() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? s.setActive(true)
        if silence == nil, let p = try? AVAudioPlayer(data: Session.silentWav) {
            p.numberOfLoops = -1; p.volume = 0
            silence = p
        }
        silence?.play()
    }

    /// One second of 16-bit mono silence as a WAV, built in memory.
    private static let silentWav: Data = {
        let rate: UInt32 = 8000, n: UInt32 = rate * 2
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append("RIFF".data(using: .ascii)!); u32(36 + n); d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(n); d.append(Data(count: Int(n)))
        return d
    }()

    private func closeAudio() {
        silence?.stop(); silence = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        heartbeat?.invalidate(); heartbeat = nil
        Shared.defaults.removeObject(forKey: Shared.kAlive)
        alive = false
        publish("idle")
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
                    if self.listening { self.publish("error: deepgram — \(e.localizedDescription)"); self.listening = false; self.commit() }
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
