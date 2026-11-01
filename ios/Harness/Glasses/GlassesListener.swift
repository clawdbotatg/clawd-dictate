// Speech-to-text from the phone's current mic (AirPods when connected) with
// Apple's on-device recognizer. Native on purpose: the mic keeps running with
// the phone locked (UIBackgroundModes: audio), which a web page can't do.
// (The G1's own mic only gives hiss, 11-01, so it isn't used.)
//
// openMic() starts the audio engine and leaves it running while 👓 is on — that
// also keeps the app alive in the background. startTalking()/stopTalking()
// bracket one message.
import AVFoundation
import Speech

@MainActor
final class GlassesListener {
    /// Live text of the message being spoken.
    var onText: ((String) -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private var task: SFSpeechRecognitionTask?
    private var committed = ""
    private var partial = ""
    private var generation = 0
    private(set) var talking = false
    private(set) var micOpen = false
    private var configObserver: NSObjectProtocol?

    /// The audio thread appends to whatever request is current.
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var req: SFSpeechAudioBufferRecognitionRequest?
        func set(_ r: SFSpeechAudioBufferRecognitionRequest?) { lock.lock(); req = r; lock.unlock() }
        func append(_ b: AVAudioPCMBuffer) { lock.lock(); req?.append(b); lock.unlock() }
    }
    private let sink = Sink()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    var text: String { [committed, partial].filter { !$0.isEmpty }.joined(separator: " ") }

    static func authorize() async -> Bool {
        let speech = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        let mic = await AVAudioApplication.requestRecordPermission()
        return speech && mic
    }

    func openMic() throws {
        guard !micOpen else { return }
        let s = AVAudioSession.sharedInstance()
        // .allowBluetooth = Bluetooth headset mic (AirPods). mixWithOthers so music etc. isn't killed.
        try s.setCategory(.playAndRecord, mode: .default,
                          options: [.allowBluetooth, .allowBluetoothA2DP, .mixWithOthers, .defaultToSpeaker])
        try s.setActive(true)
        if let bt = s.availableInputs?.first(where: { $0.portType == .bluetoothHFP }) {
            try? s.setPreferredInput(bt)
        }
        try startEngine()
        micOpen = true
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            // AirPods in/out etc.: the input format changed, rebuild the tap
            Task { @MainActor in
                guard let self, self.micOpen else { return }
                GlassesBridge.log("audio route changed: \(self.inputName)")
                self.engine.stop()
                try? self.startEngine()
            }
        }
        GlassesBridge.log("mic open: \(inputName)")
    }

    var inputName: String {
        AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName ?? "none"
    }

    private func startEngine() throws {
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let fmt = input.outputFormat(forBus: 0)
        let sink = self.sink
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { buf, _ in sink.append(buf) }
        engine.prepare()
        try engine.start()
    }

    func closeMic() {
        stopTalkingNow()
        if let o = configObserver { NotificationCenter.default.removeObserver(o) }
        configObserver = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        micOpen = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func startTalking() {
        committed = ""; partial = ""
        talking = true
        begin()
    }

    /// Stop and return what was said (waits briefly for the last words).
    func stopTalking() async -> String {
        guard talking else { return "" }
        talking = false
        request?.endAudio()
        for _ in 0..<10 where task != nil { try? await Task.sleep(nanoseconds: 100_000_000) }
        let t = text
        endTask()
        return t
    }

    private func stopTalkingNow() {
        talking = false
        endTask()
    }

    private func endTask() {
        generation += 1
        sink.set(nil)
        request?.endAudio()
        task?.cancel()
        request = nil; task = nil
    }

    private func begin() {
        generation += 1
        let gen = generation
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        if recognizer?.supportsOnDeviceRecognition == true { req.requiresOnDeviceRecognition = true }
        request = req
        sink.set(req)
        task = recognizer?.recognitionTask(with: req) { [weak self] result, err in
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                if let result {
                    self.partial = result.bestTranscription.formattedString
                    self.onText?(self.text)
                }
                if let err { GlassesBridge.log("speech: \(err.localizedDescription)") }
                if err != nil || result?.isFinal == true {
                    // request over (time limit / pause / endAudio): keep its words
                    if !self.partial.isEmpty { self.committed = self.text; self.partial = "" }
                    self.task = nil
                    if self.talking { self.begin() }   // still talking: start another
                }
            }
        }
    }
}
