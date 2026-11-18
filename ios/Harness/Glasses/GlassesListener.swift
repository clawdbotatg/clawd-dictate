// Speech-to-text with Apple's on-device recognizer. Audio comes from the
// glasses' LEFT mic (the right one on this pair is static, 11-18), or from the
// phone's current mic (AirPods when connected) if the glasses send nothing.
// Native on purpose: it keeps running with the phone locked
// (UIBackgroundModes: audio), which a web page can't do.
//
// openMic() starts the audio engine and leaves it running while 👓 is on — that
// keeps the app alive in the background and is the backup mic.
// startTalking()/stopTalking() bracket one message.
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
    /// Where this message's audio comes from.
    private(set) var fromGlasses = false
    /// Glasses mic packets heard in this message.
    private(set) var glassesPackets = 0
    private var decoderMem: UnsafeMutableRawPointer?
    private var decoder: lc3_decoder_t?
    private let pcm16k = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                                       channels: 1, interleaved: false)!
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

    func startTalking(glasses: Bool = false) {
        committed = ""; partial = ""
        talking = true
        fromGlasses = glasses
        glassesPackets = 0
        if glasses { resetDecoder() }
        begin()
    }

    /// The glasses sent no audio: take this message from the phone's mic instead.
    func usePhoneMic() {
        guard talking, fromGlasses else { return }
        fromGlasses = false
        begin()
    }

    var micName: String { fromGlasses ? "glasses mic" : inputName }

    private func resetDecoder() {
        decoderMem?.deallocate()
        decoderMem = UnsafeMutableRawPointer.allocate(byteCount: Int(lc3_decoder_size(10000, 16000)), alignment: 16)
        decoder = lc3_setup_decoder(10000, 16000, 0, decoderMem)
    }

    /// LC3 audio from a glasses mic packet (header already stripped): 20-byte
    /// frames, 10 ms each, 16 kHz mono.
    func feedLC3(_ data: Data) {
        guard talking, fromGlasses, let decoder else { return }
        glassesPackets += 1
        let n = data.count / 20
        guard n > 0, let request,
              let buf = AVAudioPCMBuffer(pcmFormat: pcm16k, frameCapacity: AVAudioFrameCount(n * 160)) else { return }
        var pcm = [Int16](repeating: 0, count: 160)
        let out = buf.floatChannelData![0]
        data.withUnsafeBytes { raw in
            for f in 0..<n {
                pcm.withUnsafeMutableBytes { dst in
                    _ = lc3_decode(decoder, raw.baseAddress!.advanced(by: f * 20), 20, LC3_PCM_FORMAT_S16, dst.baseAddress, 1)
                }
                for i in 0..<160 { out[f * 160 + i] = Float(pcm[i]) / 32768 }
            }
        }
        buf.frameLength = AVAudioFrameCount(n * 160)
        request.append(buf)
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
        task?.cancel()
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        if recognizer?.supportsOnDeviceRecognition == true { req.requiresOnDeviceRecognition = true }
        request = req
        sink.set(fromGlasses ? nil : req)   // glasses audio arrives through feedLC3
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
