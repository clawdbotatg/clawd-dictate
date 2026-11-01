// Continuous speech-to-text from the Even G1 mic (LC3 over BLE) with Apple's
// recognizer. One recognition request lasts ~1 min, so it restarts itself and
// keeps the words heard so far (`committed`). `reset()` starts a fresh message.
import AVFoundation
import Speech

@MainActor
final class GlassesListener {
    /// Full text heard since the last reset (committed + live partial).
    var onText: ((String) -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var committed = ""
    private var partial = ""
    private var running = false
    private var generation = 0

    private let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                                    channels: 1, interleaved: false)!
    // LC3: 16 kHz, 10 ms frames, 20 bytes per frame
    private static let frameBytes = 20, frameSamples = 160
    private var decoderMem: UnsafeMutableRawPointer?
    private var decoder: lc3_decoder_t?

    var text: String { [committed, partial].filter { !$0.isEmpty }.joined(separator: " ") }

    static func authorize() async -> Bool {
        await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
    }

    func start() {
        if decoder == nil {
            let size = Int(lc3_decoder_size(10000, 16000))
            decoderMem = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
            decoder = lc3_setup_decoder(10000, 16000, 0, decoderMem)
        }
        running = true
        committed = ""; partial = ""
        begin()
    }

    func stop() {
        running = false
        endTask()
    }

    /// Clear the words (after a send) and keep listening.
    func reset() {
        committed = ""; partial = ""
        endTask()
        if running { begin() }
        onText?("")
    }

    private func endTask() {
        generation += 1
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
        request = req
        task = recognizer?.recognitionTask(with: req) { [weak self] result, err in
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                if let result {
                    self.partial = result.bestTranscription.formattedString
                    self.onText?(self.text)
                }
                if err != nil || result?.isFinal == true {
                    // this request is over (time limit / silence): keep its words, start another
                    if !self.partial.isEmpty {
                        self.committed = self.text
                        self.partial = ""
                    }
                    if self.running { self.begin() }
                }
            }
        }
    }

    /// LC3 payload from one 0xF1 mic packet (2-byte header already stripped).
    func feed(_ data: Data) {
        guard running, let decoder, let request else { return }
        let n = data.count / Self.frameBytes
        guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt,
                                                frameCapacity: AVAudioFrameCount(n * Self.frameSamples)) else { return }
        var pcm = [Int16](repeating: 0, count: Self.frameSamples)
        let out = buf.floatChannelData![0]
        data.withUnsafeBytes { raw in
            for f in 0..<n {
                let p = raw.baseAddress!.advanced(by: f * Self.frameBytes)
                pcm.withUnsafeMutableBytes { dst in
                    _ = lc3_decode(decoder, p, Int32(Self.frameBytes), LC3_PCM_FORMAT_S16, dst.baseAddress, 1)
                }
                for i in 0..<Self.frameSamples { out[f * Self.frameSamples + i] = Float(pcm[i]) / 32768 }
            }
        }
        buf.frameLength = AVAudioFrameCount(n * Self.frameSamples)
        request.append(buf)
    }
}
