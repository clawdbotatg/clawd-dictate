import Foundation
import Combine

// Only hardware and network boundaries are replaced. Session's start/stop,
// permission callbacks, timers, mailbox and receive handlers run unchanged.
enum Secrets {
    static let relay = "https://example.invalid"
    static let docsCredential = ""
    static let deepgramKey = ""
}
enum TestIO { static var micOpens = 0; static var micDead = false }
enum AVAudioApplication {
    static var requests: [(Bool) -> Void] = []
    static func requestRecordPermission(_ callback: @escaping (Bool) -> Void) { requests.append(callback) }
    static func answer(_ index: Int, _ allowed: Bool = true) { requests[index](allowed) }
}
final class AVAudioEngine {}
final class AVAudioConverter {}
final class StubDataTask { func resume() {} }
final class StubURLSession {
    static let shared = StubURLSession()
    var sockets: [StubURLSessionWebSocketTask] = []
    func dataTask(with request: URLRequest, completionHandler: @escaping (Data?, URLResponse?, Error?) -> Void) -> StubDataTask { StubDataTask() }
    func dataTask(with url: URL, completionHandler: @escaping (Data?, URLResponse?, Error?) -> Void) -> StubDataTask { StubDataTask() }
    func webSocketTask(with request: URLRequest) -> StubURLSessionWebSocketTask {
        let socket = StubURLSessionWebSocketTask(); sockets.append(socket); return socket
    }
}
final class StubURLSessionWebSocketTask {
    enum Message { case string(String), data(Data) }
    enum CloseCode { case normalClosure }
    var callback: ((Result<Message, Error>) -> Void)?
    var cancelled = false
    func resume() {}
    func send(_ message: Message, completionHandler: @escaping (Error?) -> Void) { completionHandler(nil) }
    func cancel(with code: CloseCode, reason: Data?) { cancelled = true }
    func receive(completionHandler: @escaping (Result<Message, Error>) -> Void) { callback = completionHandler }
}

@main struct SessionTests {
    static func drain(_ seconds: TimeInterval = 0.03) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
    static func main() {
        defer { Shared.defaults.removePersistentDomain(forName: Shared.group) }
        let s = Session()
        s.start()
        s.stop()
        AVAudioApplication.answer(0)
        drain()
        precondition(TestIO.micOpens == 0 && StubURLSession.shared.sockets.isEmpty, "stop must cancel pending permission")

        s.start()
        s.stop()
        s.start()
        AVAudioApplication.answer(1)
        drain()
        precondition(TestIO.micOpens == 0, "old permission must not start a new run")
        AVAudioApplication.answer(2)
        drain()
        precondition(s.listening && TestIO.micOpens == 1)
        let old = StubURLSession.shared.sockets.last!
        s.stop()
        s.start()
        let replacement = StubURLSession.shared.sockets.last!
        old.callback?(.failure(NSError(domain: "test", code: 1)))
        drain(1.3)
        precondition(s.listening && !replacement.cancelled, "old receive/flush must not end replacement")
        replacement.callback?(.failure(NSError(domain: "test", code: 2)))
        drain()
        precondition(!s.listening && s.state.hasPrefix("error:"), "connection error must remain visible")

        TestIO.micDead = true                 // iOS stopped the engine (call, Siri, route change) while the mic was "open"
        s.start()
        precondition(!s.listening && s.state == "starting", "a dead engine must not be streamed from")
        AVAudioApplication.answer(3)
        drain()
        precondition(s.listening && TestIO.micOpens == 2, "a dead engine must be reopened")
        s.stop()
        drain(1.3)

        s.start(id: "missing-lease")
        precondition(!s.listening, "unowned start must be rejected")
        Shared.renewLease(id: "keyboard")
        s.start(id: "keyboard")
        precondition(s.listening)
        Shared.releaseLease(id: "keyboard")
        drain(1.1)
        precondition(!s.listening, "lost keyboard must stop streaming")
        drain(1.3)
        precondition(StubURLSession.shared.sockets.last!.cancelled)

        let run = RecordingRun(id: "keyboard", keyboard: true)
        precondition(run.expired(leaseUntil: nil))
        precondition(!run.expired(leaseUntil: Date().addingTimeInterval(6)))
        let manual = RecordingRun(id: "app", keyboard: false)
        precondition(manual.expired(now: manual.started.addingTimeInterval(600), leaseUntil: nil))

        let gate = AudioGate<Int>()
        gate.set(1)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), stopped = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { gate.withTarget { _ in entered.signal(); release.wait() } }
        precondition(entered.wait(timeout: .now() + 1) == .success)
        DispatchQueue.global().async { gate.set(nil); stopped.signal() }
        precondition(stopped.wait(timeout: .now() + 0.05) == .timedOut, "stop must wait for in-flight send")
        release.signal()
        precondition(stopped.wait(timeout: .now() + 1) == .success)
        gate.withTarget { _ in preconditionFailure("audio sent after stop") }

        let document = UUID()
        let anchor = TextAnchor(document: document, before: "hello", after: "")
        precondition(anchor.canResume(id: "mine", publishedID: "mine", current: anchor, selected: nil))
        precondition(!anchor.canResume(id: "mine", publishedID: "someone-else", current: anchor, selected: nil))
        precondition(!anchor.canResume(id: "", publishedID: "", current: anchor, selected: nil))
        precondition(!anchor.permits(TextAnchor(document: UUID(), before: "hello", after: ""), selected: nil), "identical text in another field is not ours")
        precondition(!anchor.permits(TextAnchor(document: document, before: "hel", after: "lo"), selected: nil), "cursor movement must stop edits")
        precondition(anchor.permits(anchor, selected: "hello"), "a reported selection is not trusted (web views lie)")
        let unknown = TextAnchor(document: document, before: nil, after: nil)
        precondition(unknown.permits(unknown, selected: nil), "an empty field (no context yet) must be dictatable")
        precondition(unknown.permits(TextAnchor(document: document, before: "", after: ""), selected: nil), "nil and empty context are the same field")
        precondition(!unknown.permits(TextAnchor(document: document, before: "typed", after: nil), selected: nil), "text appearing under us is a field change")

        let vocab = Vocab.build(shared: "ETH skills => ethskills", baseHTML: "")
        precondition(vocab.fix("ETH, skills") == "ethskills")
        precondition(vocab.fix("ETH. skills") == "ethskills")
        precondition(vocab.fix("ETH skills") == "ethskills")
        print("PASS: startup cancellation, dead-engine reopen, stale permission/socket/flush, error display, lease expiry, recording limit, audio gate, field/cursor ownership, punctuation")
    }
}
