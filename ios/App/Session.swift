// The recorder: mic → 16 kHz Int16 PCM → Deepgram nova-3 over a WebSocket,
// keyterm-biased; results (interim/final, rules applied) go to the App Group
// mailbox for the keyboard.
//
// Idle audio is discarded. A keyboard must renew its lease to keep streaming;
// stop cancels pending startup and clears the audio gate before flushing text.
// The mic stays open between dictations so the next use needs no app hop.
import AVFoundation
import Foundation
import UIKit

final class Session: NSObject, ObservableObject {
    static let shared = Session()

    @Published var state = "idle"
    @Published var live = ""
    @Published var listening = false
    @Published var servingKeyboard = false  // this dictation belongs to a keyboard field, not the app screen
    var vocab = Vocab.cached()

    private let engine = AVAudioEngine()
    private var ws: URLSessionWebSocketTask?
    private let audioGate = AudioGate<URLSessionWebSocketTask>()
    private var run: RecordingRun?
    private var watchdog: Timer?
    var canStop: Bool { listening || state == "starting" }
    private var converter: AVAudioConverter?
    private var finals: [String] = []
    private var interim = ""
    private var cmdObserver: AnyObject?
    private var lastCmd = ""
    private var dictId = ""                 // the dictation being served (the keyboard's start nonce, or "app")
    static let idleMinutes = 24 * 60        // the mic (not the socket) stays open this long after the last dictation
    private var alive = false               // mic open + heartbeat running
    private var heartbeat: Timer?
    private var idleTimer: Timer?
    private var audioObservers: [NSObjectProtocol] = []
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var vocabRefreshedAt = Date.distantPast
    private var streamStartedAt = Date()
    private var firstResultLogged = false
    private var socketAttempt = 0           // 1-based; a failed socket is reopened up to socketTries times before the dictation fails
    static let socketTries = 4
    private let bufferClock = AudioGate<Date>()   // when the tap last delivered audio (audio thread writes, main reads)
    static let silentAfter: TimeInterval = 3      // a "running" engine that delivers nothing this long is dead: reopen it
    private var pendingStart: String?             // a keyboard start the mic could not serve in the background; retried when the app becomes active

    override init() {
        super.init()
        cmdObserver = Shared.observe(Shared.noteCmd) { [weak self] in self?.onCmd() }
        let nc = NotificationCenter.default
        for (name, tag) in [(UIApplication.didEnterBackgroundNotification, "background"), (UIApplication.willEnterForegroundNotification, "foreground"),
                            (UIApplication.didBecomeActiveNotification, "active"), (UIApplication.willTerminateNotification, "TERMINATE")] {
            lifecycleObservers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self = self else { return }
                Shared.log("app", "\(tag) alive=\(self.alive) engine=\(self.micRunning) listening=\(self.listening)")
            })
        }
        lifecycleObservers.append(nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.onActive() })
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
        Shared.log("app", "cmd \(cmd.prefix(14)) alive=\(alive) engine=\(micRunning) run=\(run?.id.prefix(8) ?? "-")")
        if cmd.hasPrefix("start:") { start(id: id) }
        else if cmd.hasPrefix("stop:"), run?.id == id { stop() }
    }

    // MARK: words
    /// At most every 5 min unless forced: the base list is the whole harness
    /// index.html, and fetching it on every start competed with the Deepgram
    /// socket for the link (the "ten second delay", 09-17).
    func refreshVocab(force: Bool = false) {
        guard force || Date().timeIntervalSince(vocabRefreshedAt) > 300 else { return }
        vocabRefreshedAt = Date()
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
        let keyboard = id != "app"
        guard !keyboard || (Shared.leaseUntil(id: id) ?? .distantPast) > Date() else { Shared.log("app", "start \(id.prefix(8)) REJECTED: no lease"); return }
        if let current = run, current.id == id, current.phase != .stopping { Shared.log("app", "start \(id.prefix(8)) already running"); return }
        Shared.log("app", "start \(id.prefix(8)) alive=\(alive) engine=\(micRunning) bg=\(inBackground)")
        finishNow()
        let current = RecordingRun(id: id, keyboard: keyboard)
        run = current
        dictId = id
        servingKeyboard = keyboard
        finals = []; interim = ""
        Shared.defaults.removeObject(forKey: Shared.kFinal)
        publish("starting")
        refreshVocab()
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self, let run = self.run else { return }
            if run.expired(leaseUntil: Shared.leaseUntil(id: run.id)) { self.stop() }
        }
        if alive && micRunning { beginStream(token: current.token); return }   // `alive` alone lied: iOS stops the engine behind our back
        AVAudioApplication.requestRecordPermission { [weak self] ok in
            DispatchQueue.main.async {
                guard let self = self, let run = self.run, run.token == current.token,
                      run.phase == .starting else { return }
                guard !run.expired(leaseUntil: Shared.leaseUntil(id: run.id)) else { self.stop(); return }
                Shared.log("app", "record permission \(ok ? "granted" : "DENIED")")
                guard ok else { self.fail("microphone not allowed — Settings → clawd dictate → Microphone"); return }
                do { try self.openMic() } catch {
                    let bg = self.inBackground
                    Shared.log("app", "openMic FAILED at start (bg=\(bg)): \(error)")
                    self.closeMic()
                    // In the background iOS refuses a mic start: the keyboard hops once, and the
                    // start is retried the moment the app is active (onActive). In the foreground
                    // the failure is real (another app holds the mic): say so.
                    if bg { self.pendingStart = id }
                    self.fail(bg ? "wake" : "mic busy — \((error as NSError).code)")
                    return
                }
                Shared.log("app", "mic opened at start")
                self.markAlive()
                self.beginStream(token: current.token)
            }
        }
    }

    private func beginStream(token: UUID) {
        guard run?.token == token, run?.phase == .starting else { return }
        socketAttempt = 1
        openDeepgram()
        streamStartedAt = Date(); firstResultLogged = false
        Shared.log("app", "stream \(run?.id.prefix(8) ?? "-") socket opening, \(vocab.terms.count) terms")
        run?.phase = .streaming
        listening = true
        audioGate.set(ws)
        publish("listening")
        armIdle()
    }

    private func armIdle() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: Double(Session.idleMinutes) * 60, repeats: false) { [weak self] _ in
            guard let self = self, !self.listening else { return }
            self.closeMic()
        }
    }

    func stop() {
        Shared.log("app", "stop \(run?.id.prefix(8) ?? "-") phase=\(run.map { "\($0.phase)" } ?? "-")")
        audioGate.set(nil)
        listening = false
        guard let current = run, current.phase != .stopping else { return }
        run?.phase = .stopping           // invalidates the permission callback too
        watchdog?.invalidate(); watchdog = nil
        Shared.releaseLease(id: current.id)
        guard ws != nil else { commit(); armIdle(); return }
        ws?.send(.string(#"{"type":"CloseStream"}"#)) { _ in }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self = self, self.run?.token == current.token else { return }
            self.commit()
        }
        armIdle()
    }

    private func finishNow() {
        audioGate.set(nil)
        listening = false
        if run != nil { commit() }
    }

    private func fail(_ message: String) {
        Shared.log("app", "FAIL \(message)")
        audioGate.set(nil)
        listening = false
        commit(state: "error: " + message)
        armIdle()
    }

    private func commit(state: String = "idle") {
        guard !listening else { return }
        watchdog?.invalidate(); watchdog = nil
        let text = vocab.fix((finals + (interim.isEmpty ? [] : [interim])).joined(separator: " "))
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        interim = ""; finals = []
        Shared.log("app", "commit \(dictId.prefix(8)) \(text.count) chars state=\(state)")
        Shared.defaults.set(text, forKey: Shared.kFinal)
        ws?.cancel(with: .normalClosure, reason: nil); ws = nil
        run = nil
        publish(state)
        live = text
    }

    // MARK: audio — the ONLY code that touches the microphone
    /// The engine is the truth. iOS stops it on its own (a call, Siri, another
    /// app's mic, a route change, a media-services reset) and never restarts
    /// it; `alive` must never outlive the hardware, or "listening" streams
    /// silence and the keyboard skips the hop that would have fixed it.
    private var micRunning: Bool { engine.isRunning }
    private var inBackground: Bool { UIApplication.shared.applicationState != .active }

    private func markAlive() {
        alive = true
        heartbeat?.invalidate()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.heartbeatTick() }
        Shared.defaults.set(Date(), forKey: Shared.kAlive)
    }

    /// Seconds since the tap last delivered a buffer. `isRunning` alone is not
    /// proof: an engine can report running and deliver nothing (a mic opened
    /// on a dead input format, an interruption iOS never told us about) — that
    /// is "listening" with no words, fixed only by killing the app (09-18).
    private var silentFor: TimeInterval {
        var last: Date?
        bufferClock.withTarget { last = $0 }
        return last.map { Date().timeIntervalSince($0) } ?? .infinity
    }

    /// Every beat: an engine that delivers audio is advertised to the keyboard;
    /// a stopped or silent one is reopened in place, or the mic is declared
    /// closed (heartbeat off, so the next keyboard start hops through the app
    /// and opens it again).
    private func heartbeatTick() {
        guard alive else { return }
        let silent = silentFor
        if micRunning && silent < Session.silentAfter { Shared.defaults.set(Date(), forKey: Shared.kAlive); return }
        let why = micRunning ? "engine running but silent for \(Int(silent)) s" : "engine was stopped"
        do {
            try openMic()
            Shared.log("app", "\(why): reopened (bg=\(inBackground))")
            Shared.defaults.set(Date(), forKey: Shared.kAlive)
        } catch {
            Shared.log("app", "\(why): reopen FAILED (bg=\(inBackground)): \(error) — mic declared closed")
            closeMic()
            if listening { fail(inBackground ? "wake" : "microphone lost — tap listen") }
        }
    }

    /// The foreground is the one moment iOS lets us open a mic it refused in
    /// the background. A closed mic opens here whatever brought the app up, and
    /// a keyboard start the mic could not serve (the hop that brought us here)
    /// runs now — before 09-18 nothing retried it: the app sat in front saying
    /// "error: wake" and the keyboard hopped again on return.
    private func onActive() {
        Shared.log("app", "active alive=\(alive) engine=\(micRunning) silent=\(Int(min(silentFor, 999))) run=\(run?.id.prefix(8) ?? "-") pending=\(pendingStart?.prefix(8) ?? "-")")
        if run == nil && !(alive && micRunning) {
            do { try openMic(); markAlive(); armIdle(); publish("idle"); Shared.log("app", "mic opened on activate") }   // publish: the screen still said "error: wake / mic off" (09-18)
            catch { Shared.log("app", "openMic on activate FAILED: \(error)"); closeMic() }
        }
        guard let id = pendingStart else { return }
        pendingStart = nil
        if run == nil, Shared.defaults.string(forKey: Shared.kCmd) == "start:" + id, (Shared.leaseUntil(id: id) ?? .distantPast) > Date() {
            Shared.log("app", "pending start \(id.prefix(8)) retried on activate")
            start(id: id)
        } else {
            Shared.log("app", "pending start \(id.prefix(8)) dropped (run=\(run?.id.prefix(8) ?? "-") cmd=\((Shared.defaults.string(forKey: Shared.kCmd) ?? "").prefix(14)))")
        }
    }

    private func observeAudio() {
        guard audioObservers.isEmpty else { return }
        let nc = NotificationCenter.default
        audioObservers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt ?? 99
            let reason = n.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt
            let resume = ((n.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0) & AVAudioSession.InterruptionOptions.shouldResume.rawValue != 0
            Shared.log("app", "interruption \(raw == 1 ? "began" : raw == 0 ? "ended" : "?\(raw)") reason=\(reason.map(String.init) ?? "-") shouldResume=\(resume)")
            guard AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            self?.reviveMic()
        })
        audioObservers.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Shared.log("app", "engine configuration change"); self?.heartbeatTick()
        })
        audioObservers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Shared.log("app", "media services reset"); self?.heartbeatTick()
        })
    }

    /// An interruption ended (the other app let the mic go, the call ended):
    /// iOS allows a background session to resume here. A mic that had been
    /// declared closed is reopened too, so the next keyboard start needs no hop.
    private func reviveMic() {
        if alive { heartbeatTick(); return }
        do {
            try openMic()
            markAlive()
            publish("idle")
            Shared.log("app", "mic revived after interruption (bg=\(inBackground))")
            armIdle()
        } catch {
            Shared.log("app", "mic revive after interruption FAILED (bg=\(inBackground)): \(error)")
        }
    }

    private func teardownEngine() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
        converter = nil
    }

    private func openMic() throws {
        teardownEngine()                      // a dead engine may still hold the tap; installing a second one crashes
        observeAudio()
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .allowBluetoothHFP, .defaultToSpeaker])
        try s.setActive(true)
        let input = engine.inputNode
        let inFmt = input.outputFormat(forBus: 0)
        // A 0 Hz / 0-channel input is a mic iOS has not really given us: the
        // converter would be nil, the tap would drop everything, and the engine
        // would still report running — "listening" with no words, forever.
        guard inFmt.sampleRate > 0, inFmt.channelCount > 0 else {
            throw NSError(domain: "clawd.dictate", code: 1, userInfo: [NSLocalizedDescriptionKey: "input format \(inFmt.sampleRate) Hz / \(inFmt.channelCount) ch"])
        }
        let outFmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
        converter = AVAudioConverter(from: inFmt, to: outFmt)
        input.installTap(onBus: 0, bufferSize: 4096, format: inFmt) { [weak self] buf, _ in
            guard let self = self else { return }
            self.bufferClock.set(Date())          // audio is flowing, listening or not
            self.audioGate.withTarget { ws in
                guard let conv = self.converter else { return }
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
                ws.send(.data(data)) { [weak self] error in
                    guard error != nil else { return }
                    DispatchQueue.main.async {
                        guard let self = self, self.ws === ws, self.listening else { return }
                        self.fail("connection lost — tap to retry")
                    }
                }
            }
        }
        engine.prepare()
        try engine.start()
        bufferClock.set(Date())                   // the first buffer gets silentAfter to arrive
    }

    private func closeMic() {
        teardownEngine()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        heartbeat?.invalidate(); heartbeat = nil
        Shared.defaults.removeObject(forKey: Shared.kAlive)
        alive = false
        if !listening { publish("idle") }     // mid-dictation the caller reports the error instead
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
        req.timeoutInterval = 8
        req.setValue("Token " + Secrets.deepgramKey, forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.webSocketTask(with: req)
        ws = task
        task.resume()
        receive(task)
    }

    /// Same dictation, same mic: a fresh socket after a short pause. Finals stay,
    /// the interim and the audio during the gap are lost. The mic must not drop
    /// for a network blip (EXPECTATIONS: never breaks itself).
    private func reopenSocket(run: RecordingRun) {
        audioGate.set(nil)
        ws?.cancel(with: .normalClosure, reason: nil); ws = nil
        interim = ""
        let delay = 0.4 * pow(2.0, Double(socketAttempt - 1))     // 0.4, 0.8, 1.6 s
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, self.listening, self.run?.token == run.token, self.run?.phase == .streaming else { return }
            self.socketAttempt += 1
            self.openDeepgram()
            self.audioGate.set(self.ws)
            Shared.log("app", "socket reopened, try \(self.socketAttempt)/\(Session.socketTries)")
        }
    }

    private func receive(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, self.ws === task else { return }
                switch result {
                case .failure(let e):
                    // A rejected handshake (a captive WiFi, a proxy, a 4xx) surfaces as POSIX 57
                    // "Socket is not connected" (09-17); the HTTP status on the task says which.
                    let ns = e as NSError
                    let http = (task.response as? HTTPURLResponse)?.statusCode
                    let why = http.map { "HTTP \($0)" } ?? "\(ns.domain) \(ns.code)"
                    Shared.log("app", "socket failed try \(self.socketAttempt)/\(Session.socketTries): \(why) — \(e.localizedDescription) (results=\(self.firstResultLogged))")
                    guard self.listening, let run = self.run, run.phase == .streaming else { self.commit(); return }
                    if self.socketAttempt < Session.socketTries { self.reopenSocket(run: run); return }
                    self.fail("deepgram — \(why) after \(self.socketAttempt) tries" + (http != nil ? " (this network may block it)" : ""))
                case .success(let msg):
                    if case .string(let s) = msg, let d = s.data(using: .utf8),
                       let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], j["type"] as? String == "Results" {
                        let t = ((((j["channel"] as? [String: Any])?["alternatives"] as? [[String: Any]])?.first)?["transcript"] as? String ?? "")
                            .trimmingCharacters(in: .whitespaces)
                        if !self.firstResultLogged {
                            self.firstResultLogged = true
                            Shared.log("app", "first result \(Int(Date().timeIntervalSince(self.streamStartedAt) * 1000)) ms after socket open: \"\(t.prefix(30))\"")
                        }
                        if j["is_final"] as? Bool == true {
                            if !t.isEmpty { self.finals.append(t) }
                            self.interim = ""
                        } else { self.interim = t }
                        self.publish()
                    }
                    self.receive(task)
                }
            }
        }
    }
}
