// Shared between the app and the keyboard: the App Group mailbox, the Darwin
// notifications that wake each side, and the word list (keyterms + replace
// rules) — the same list the harness page and the Mac tool use.
import Foundation

enum Shared {
    static let group = "group.com.clawd.dictate"
    static var relay: String { Secrets.relay }   // HARNESS_URL in ~/.config/clawd-dictate/env — never in the repo
    static let baseTermsURL = "https://raw.githubusercontent.com/clawdbotatg/clawd-harness/main/index.html"

    // App Group keys
    static let kAlive = "session.alive"          // Date: the app's recorder heartbeat (background session live)
    static let kState = "state"                  // "idle" | "starting" | "listening" | "error: …"
    static let kCmd = "cmd"                      // "start:<nonce>" | "stop:<nonce>" — keyboard → app
    static let kInterim = "text.interim"         // the current segment, revised as it goes
    static let kDone = "text.done"               // the finished segments of THIS dictation so far (rules applied)
    static let kDict = "dict.id"                 // which dictation the text keys describe — a keyboard only takes its own
    static let kFinal = "text.final"             // the finished text of the last dictation
    static let kSeq = "text.seq"                 // bumps on every text/state change
    static let kWords = "words.txt"              // cached shared list
    static let kBaseHTML = "words.base"          // cached harness index.html (base terms + rules)

    // Darwin notifications (cross-process, no payload — the payload is the mailbox)
    static let noteCmd = "com.clawd.dictate.cmd"    // keyboard → app: read kCmd
    static let noteText = "com.clawd.dictate.text"  // app → keyboard: read kInterim/kFinal/kState

    static var defaults: UserDefaults { UserDefaults(suiteName: group) ?? .standard }

    // MARK: the log — `dictate.log` in the App Group container, both processes
    // append. Pull it over USB: `xcrun devicectl device copy from --device <id>
    // --source dictate.log --destination x.log --domain-type appGroupDataContainer
    // --domain-identifier group.com.clawd.dictate`. Trimmed to ~150 KB.
    static let logURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?.appendingPathComponent("dictate.log")
    private static let logQueue = DispatchQueue(label: "dictate.log")
    private static let logStamp: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f }()
    private static var logWrites = 0
    static func log(_ who: String, _ msg: String) {
        guard let url = logURL else { return }
        let line = "\(logStamp.string(from: Date())) \(who) \(msg)\n"
        logQueue.async {
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
            } else { try? line.data(using: .utf8)!.write(to: url) }
            logWrites += 1
            if logWrites % 200 == 0, let d = try? Data(contentsOf: url), d.count > 300_000 {
                try? d.suffix(150_000).write(to: url)
            }
        }
    }

    static func post(_ name: String) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(name as CFString), nil, nil, true)
    }

    /// Observe a Darwin notification; the closure runs on the main queue.
    static func observe(_ name: String, _ fn: @escaping () -> Void) -> AnyObject {
        let box = Box(fn)
        let ptr = Unmanaged.passRetained(box).toOpaque()
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), ptr, { _, observer, _, _, _ in
            guard let observer = observer else { return }
            let b = Unmanaged<Box>.fromOpaque(observer).takeUnretainedValue()
            DispatchQueue.main.async { b.fn() }
        }, name as CFString, nil, .deliverImmediately)
        return box
    }
    final class Box { let fn: () -> Void; init(_ f: @escaping () -> Void) { fn = f } }

    static func bump() { defaults.set((defaults.integer(forKey: kSeq) + 1), forKey: kSeq) }
    /// The app has the mic open (heartbeat within 6 s): a start needs no hop.
    static var aliveNow: Bool {
        guard let d = defaults.object(forKey: kAlive) as? Date else { return false }
        return Date().timeIntervalSince(d) < 6
    }
    static let kLease = "keyboard.lease"

    static func renewLease(id: String, seconds: TimeInterval = 6) {
        defaults.set(["id": id, "until": Date().addingTimeInterval(seconds)], forKey: kLease)
    }

    static func leaseUntil(id: String) -> Date? {
        guard let lease = defaults.dictionary(forKey: kLease), lease["id"] as? String == id else { return nil }
        return lease["until"] as? Date
    }

    static func releaseLease(id: String) {
        if leaseUntil(id: id) != nil { defaults.removeObject(forKey: kLease) }
    }

}

/// The word list, parsed exactly like the harness page: plain lines are
/// keyterms, `from => to` lines are hard replace rules; the harness's built-in
/// STT_BASE_TERMS / STT_BASE_RULES ride along from index.html.
struct Vocab {
    var terms: [String] = []
    var rules: [(NSRegularExpression, String)] = []

    static func parseShared(_ text: String) -> (words: [String], rules: [(String, String)]) {
        var words: [String] = [], rules: [(String, String)] = []
        let rx = try! NSRegularExpression(pattern: #"^\s*(.+?)\s*(?:=>|->|→)\s*(.+?)\s*$"#)
        for raw in text.components(separatedBy: CharacterSet(charactersIn: "\n,;")) {
            let line = raw as NSString
            if let m = rx.firstMatch(in: raw, range: NSRange(location: 0, length: line.length)) {
                rules.append((line.substring(with: m.range(at: 1)), line.substring(with: m.range(at: 2))))
            } else if !raw.trimmingCharacters(in: .whitespaces).isEmpty {
                words.append(raw.trimmingCharacters(in: .whitespaces))
            }
        }
        return (words, rules)
    }

    static func jsStrings(_ block: String) -> [String] {
        let rx = try! NSRegularExpression(pattern: #"'((?:[^'\\]|\\.)*)'"#)
        let ns = block as NSString
        return rx.matches(in: block, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
    }

    static func parseBase(_ html: String) -> (terms: [String], rules: [(String, String)]) {
        var terms: [String] = [], rules: [(String, String)] = []
        let ns = html as NSString
        if let m = try! NSRegularExpression(pattern: #"const STT_BASE_TERMS = \[(.*?)\];"#, options: .dotMatchesLineSeparators)
            .firstMatch(in: html, range: NSRange(location: 0, length: ns.length)) {
            terms = jsStrings(ns.substring(with: m.range(at: 1)))
        }
        if let m = try! NSRegularExpression(pattern: #"const STT_BASE_RULES = \[(.*?)\];"#, options: .dotMatchesLineSeparators)
            .firstMatch(in: html, range: NSRange(location: 0, length: ns.length)) {
            let block = ns.substring(with: m.range(at: 1)) as NSString
            let pair = try! NSRegularExpression(pattern: #"\['((?:[^'\\]|\\.)*)',\s*'((?:[^'\\]|\\.)*)'\]"#)
            for pm in pair.matches(in: block as String, range: NSRange(location: 0, length: block.length)) {
                rules.append((block.substring(with: pm.range(at: 1)), block.substring(with: pm.range(at: 2))))
            }
        }
        return (terms, rules)
    }

    static func build(shared: String, baseHTML: String) -> Vocab {
        let s = parseShared(shared), b = parseBase(baseHTML)
        var v = Vocab(), seen = Set<String>()
        for t in (s.words + s.rules.map({ $0.1 }) + b.terms) {
            let k = t.lowercased()
            if !t.isEmpty && t.count <= 40 && !seen.contains(k) { seen.insert(k); v.terms.append(t) }
        }
        v.terms = Array(v.terms.prefix(100))
        for (from, to) in s.rules + b.rules {
            let f = from.trimmingCharacters(in: .whitespaces)
            if f.isEmpty { continue }
            let esc = f.split(whereSeparator: { $0.isWhitespace }).map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: #"[\s,.]+"#)   // "ETH, skills" too
            if let rx = try? NSRegularExpression(pattern: #"\b"# + esc + #"\b"#, options: .caseInsensitive) {
                v.rules.append((rx, to))
            }
        }
        return v
    }

    func fix(_ text: String) -> String {
        var t = text
        for (rx, to) in rules {
            t = rx.stringByReplacingMatches(in: t, range: NSRange(location: 0, length: (t as NSString).length), withTemplate: NSRegularExpression.escapedTemplate(for: to))
        }
        return t
    }

    static func cached() -> Vocab {
        build(shared: Shared.defaults.string(forKey: Shared.kWords) ?? "",
              baseHTML: Shared.defaults.string(forKey: Shared.kBaseHTML) ?? "")
    }
}
