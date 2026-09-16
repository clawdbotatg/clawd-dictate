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
    static var aliveNow: Bool {
        guard let d = defaults.object(forKey: kAlive) as? Date else { return false }
        return Date().timeIntervalSince(d) < 6
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
            let esc = NSRegularExpression.escapedPattern(for: f).replacingOccurrences(of: #"\ "#, with: #"\s+"#)
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
