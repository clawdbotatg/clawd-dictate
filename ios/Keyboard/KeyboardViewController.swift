// clawd keys — a normal QWERTY keyboard that is listening while it's up.
//
// The bar above the keys is the only sign: a red dot while dictating, the
// live text beside it. Bringing the keyboard up starts dictation on its own
// — no tap. When the clawd dictate app is asleep (it stays awake an hour
// after the last use) that first start hops into the app once (Apple's rule
// for custom keyboards, which can't hear) — swipe back. Tap the dot to pause
// / resume.
// Dismissing the keyboard stops the mic.
//
// It can't hear: the app records, streams to Deepgram with the shared word
// list, and hands text back through the App Group. The interim is typed and
// re-typed as it revises (delete only what we wrote), the final lands once.
import UIKit

final class KeyboardViewController: UIInputViewController {
    private let bar = UIView()
    private let dot = UIButton(type: .system)
    private let liveLabel = UILabel()
    private let doneBtn = UIButton(type: .system)
    private var doneRequested = false
    private var myDict = ""                // this keyboard's dictation id — text for any other is not ours
    private let keysView = UIStackView()
    private var textObserver: AnyObject?
    private var lastSeq = -1
    private var written = ""               // exactly what THIS dictation has typed into the field so far
    private var committed = 0              // chars of the app's text already typed by hand / a previous field — never touched again
    private var listening = false
    private var wantListening = true       // the dot toggles this; auto-start honors it
    private var pollTimer: Timer?
    private var shifted = false
    private var symbols = false
    private var stopTimeout: DispatchWorkItem?

    // The column on the right: one tap types the things Austin says most. The
    // links come from ~/.config/clawd-dictate/env (CAL_URL, SLOP_URL) via
    // gen-secrets.sh — they're his, not the repo's.
    private var macros: [(String, String)] {
        [("📅", Secrets.calURL), ("💻", Secrets.slopURL), ("😅", "😅"), ("🫡", "🫡")]
    }
    private let macroCol = UIStackView()

    private let rowsABC = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
    private let rowsSYM = ["1234567890", "-/:;()$&@\"", ".,?!'"]

    // MARK: lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.82, green: 0.84, blue: 0.86, alpha: 1)
        buildBar()
        buildKeys()
        textObserver = Shared.observe(Shared.noteText) { [weak self] in self?.pull() }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in self?.pull() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        written = ""; committed = 0
        lastSeq = Shared.defaults.integer(forKey: Shared.kSeq)   // don't replay a previous dictation's final
        if !hasFullAccess { setBar("needs Full Access: Settings → Keyboards → clawd keys", on: false); return }
        // Austin (09-15): "recording as soon as I bring it up" — always. When the
        // app is asleep that means one hop into clawd dictate (swipe back).
        if wantListening { startListening() }
        else { setBar("paused — tap ● to dictate", on: false) }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if listening { stopListening(silent: true) }
    }

    // MARK: the bar
    private func buildBar() {
        bar.backgroundColor = UIColor(white: 0.10, alpha: 1)
        bar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bar)
        dot.setTitle("●", for: .normal)
        dot.titleLabel?.font = .systemFont(ofSize: 22)
        dot.setTitleColor(UIColor(white: 0.5, alpha: 1), for: .normal)
        dot.addTarget(self, action: #selector(tapDot), for: .touchUpInside)
        dot.translatesAutoresizingMaskIntoConstraints = false
        liveLabel.textColor = .white
        liveLabel.font = .systemFont(ofSize: 13)
        liveLabel.lineBreakMode = .byTruncatingHead
        liveLabel.translatesAutoresizingMaskIntoConstraints = false
        doneBtn.setTitle("done", for: .normal)
        doneBtn.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        doneBtn.setTitleColor(.white, for: .normal)
        doneBtn.backgroundColor = UIColor(red: 0.20, green: 0.45, blue: 0.95, alpha: 1)
        doneBtn.layer.cornerRadius = 6
        doneBtn.contentEdgeInsets = UIEdgeInsets(top: 0, left: 20, bottom: 0, right: 20)
        doneBtn.addTarget(self, action: #selector(tapDone), for: .touchUpInside)
        doneBtn.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(dot); bar.addSubview(liveLabel); bar.addSubview(doneBtn)
        NSLayoutConstraint.activate([
            doneBtn.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -6),
            doneBtn.topAnchor.constraint(equalTo: bar.topAnchor, constant: 4),
            doneBtn.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -4),
            bar.topAnchor.constraint(equalTo: view.topAnchor),
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 48),
            dot.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 6),
            dot.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 34), dot.heightAnchor.constraint(equalToConstant: 30),
            liveLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 2),
            liveLabel.trailingAnchor.constraint(equalTo: doneBtn.leadingAnchor, constant: -8),
            liveLabel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])
    }

    private func setBar(_ text: String, on: Bool) {
        liveLabel.text = text
        dot.setTitleColor(on ? UIColor(red: 0.95, green: 0.2, blue: 0.2, alpha: 1) : UIColor(white: 0.5, alpha: 1), for: .normal)
    }

    /// done: finish the dictation (let the last words land), then hand over to
    /// the stock keyboard.
    @objc private func tapDone() {
        if !listening { advanceToNextInputMode(); return }
        doneRequested = true
        stopListening(silent: true)
        setBar("finishing…", on: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in   // the app didn't answer in time: go anyway
            guard let self = self, self.doneRequested else { return }
            self.doneRequested = false
            self.advanceToNextInputMode()
        }
    }

    @objc private func tapDot() {
        if listening { wantListening = false; stopListening(silent: false); return }
        wantListening = true
        startListening()
    }

    // MARK: dictation control
    private func startListening() {
        let nonce = String(Int(Date().timeIntervalSince1970 * 1000))
        written = ""; committed = 0
        myDict = nonce
        Shared.defaults.set("start:" + nonce, forKey: Shared.kCmd)
        Shared.post(Shared.noteCmd)
        listening = true
        if Shared.aliveNow { setBar("listening…", on: true) }
        else { setBar("waking clawd dictate… swipe back here", on: true); openApp(URL(string: "clawddictate://start")!) }
    }

    private func stopListening(silent: Bool) {
        let nonce = String(Int(Date().timeIntervalSince1970 * 1000))
        Shared.defaults.set("stop:" + nonce, forKey: Shared.kCmd)
        Shared.post(Shared.noteCmd)
        listening = false
        if silent { return }
        setBar("finishing…", on: false)
        stopTimeout?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self = self, self.liveLabel.text == "finishing…" else { return }
            self.setBar(Shared.aliveNow ? "paused — tap ● to dictate" : "clawd dictate is asleep — tap ● to wake it", on: false)
        }
        stopTimeout = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: w)
    }

    /// Keyboard extensions have no UIApplication.shared, and which launch path
    /// works changes with iOS: the responder chain's application object, the
    /// UIApplication class via runtime lookup, then extensionContext.open.
    @objc private func openURL(_ url: URL) -> Bool { false }
    private func openApp(_ url: URL) {
        let sel = #selector(openURL(_:))
        var r: UIResponder? = self.next
        while let cur = r {
            if cur.responds(to: sel) { cur.perform(sel, with: url); return }
            r = cur.next
        }
        if let cls = NSClassFromString("UIApplication") as? NSObject.Type,
           let app = cls.perform(NSSelectorFromString("sharedApplication"))?.takeUnretainedValue() as? NSObject,
           app.responds(to: sel) { app.perform(sel, with: url); return }
        extensionContext?.open(url) { [weak self] ok in
            DispatchQueue.main.async { if !ok { self?.setBar("can't wake it from here — open clawd dictate, then come back", on: false) } }
        }
    }

    // MARK: text from the app
    private func pull() {
        let d = Shared.defaults
        let seq = d.integer(forKey: Shared.kSeq)
        guard seq != lastSeq else { return }
        lastSeq = seq
        let state = d.string(forKey: Shared.kState) ?? "idle"
        guard (d.string(forKey: Shared.kDict) ?? "") == myDict else { return }   // another field's dictation — not ours
        let interim = d.string(forKey: Shared.kInterim) ?? ""
        if state.hasPrefix("error") { listening = false; setBar(state, on: false); return }
        let done = d.string(forKey: Shared.kDone) ?? ""
        if state == "listening" || state == "starting" {
            guard listening else { return }          // not ours (another field's keyboard asked)
            let full = done + (interim.isEmpty ? "" : (done.isEmpty ? "" : " ") + interim)
            setBar("listening", on: true)             // the words are in the field — the bar just says so
            sync(to: full)
        } else if state == "idle" {
            let final = d.string(forKey: Shared.kFinal) ?? ""
            if !final.isEmpty {
                sync(to: final)
                if !written.isEmpty { textDocumentProxy.insertText(" ") }
                d.set("", forKey: Shared.kFinal)
                setBar("paused — tap ● to dictate", on: false)
            }
            written = ""; committed = 0
            if doneRequested { doneRequested = false; advanceToNextInputMode(); return }
            if listening {                            // the app ended it (idle timeout) — resume if we still want it
                listening = false
                if wantListening && Shared.aliveNow { startListening() }
                else if !Shared.aliveNow { setBar("clawd dictate is asleep — tap ● to wake it", on: false) }
            } else if liveLabel.text == "finishing…" { setBar("paused — tap ● to dictate", on: false) }
        }
    }

    /// Make the field show `target` (the app's text for this dictation) by
    /// editing only the tail that differs from what we typed: finished words
    /// stay put, the in-progress segment is re-typed as it revises, a rule that
    /// rewrites an earlier word ("on chain" → "onchain") reaches back exactly
    /// as far as it must. Text the user typed by hand is behind `committed`.
    private func sync(to target: String) {
        let want = String(target.dropFirst(committed))
        if want == written { return }
        let common = zip(written, want).prefix { $0 == $1 }.count
        for _ in 0..<(written.count - common) { textDocumentProxy.deleteBackward() }
        let tail = String(want.dropFirst(common))
        if !tail.isEmpty { textDocumentProxy.insertText(tail) }
        written = want
    }

    /// The user typed: everything dictated so far is theirs now. Dictation
    /// resumes appending after it and never deletes back into it.
    private func handTyped() {
        committed += written.count
        written = ""
    }

    // MARK: the keys
    private func buildKeys() {
        keysView.axis = .vertical
        keysView.spacing = 9
        keysView.distribution = .fillEqually
        keysView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(keysView)
        macroCol.axis = .vertical; macroCol.spacing = 9; macroCol.distribution = .fillEqually
        macroCol.translatesAutoresizingMaskIntoConstraints = false
        for (label, text) in macros {
            let b = keyButton(label, dark: true)
            b.titleLabel?.font = .systemFont(ofSize: 26)
            b.accessibilityLabel = text
            b.addTarget(self, action: #selector(tapMacro(_:)), for: .touchUpInside)
            macroCol.addArrangedSubview(b)
        }
        view.addSubview(macroCol)
        NSLayoutConstraint.activate([
            keysView.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 8),
            keysView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 3),
            keysView.trailingAnchor.constraint(equalTo: macroCol.leadingAnchor, constant: -7),
            keysView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -6),
            macroCol.topAnchor.constraint(equalTo: keysView.topAnchor),
            macroCol.bottomAnchor.constraint(equalTo: keysView.bottomAnchor),
            macroCol.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -3),
            macroCol.widthAnchor.constraint(equalToConstant: 54),
            view.heightAnchor.constraint(equalToConstant: 48 + 8 + 4 * 42 + 3 * 9 + 6),
        ])
        layoutKeys()
    }

    private func layoutKeys() {
        keysView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let rows = symbols ? rowsSYM : rowsABC
        for (i, row) in rows.enumerated() {
            let h = UIStackView(); h.axis = .horizontal; h.spacing = 5; h.distribution = .fillEqually
            var keys: [UIView] = []
            if i == 2 { keys.append(specialKey(symbols ? "#+=" : (shifted ? "⇧" : "⇧"), #selector(tapShift), wide: false, highlighted: shifted && !symbols)) }
            for ch in row { keys.append(charKey(String(ch))) }
            if i == 2 { keys.append(specialKey("⌫", #selector(tapBackspace), wide: false)) }
            if i == 1 && !symbols {   // the home row is one key narrower: inset it
                let pad = UIView(); pad.widthAnchor.constraint(equalToConstant: 14).isActive = true
                h.distribution = .fill
                let inner = UIStackView(arrangedSubviews: keys); inner.axis = .horizontal; inner.spacing = 5; inner.distribution = .fillEqually
                let pad2 = UIView(); pad2.widthAnchor.constraint(equalToConstant: 14).isActive = true
                h.addArrangedSubview(pad); h.addArrangedSubview(inner); h.addArrangedSubview(pad2)
            } else {
                keys.forEach { h.addArrangedSubview($0) }
            }
            keysView.addArrangedSubview(h)
        }
        let bottom = UIStackView(); bottom.axis = .horizontal; bottom.spacing = 5; bottom.distribution = .fill
        let mode = specialKey(symbols ? "ABC" : "123", #selector(tapSymbols), wide: false)
        let globe = specialKey("🌐", #selector(tapGlobe), wide: false)
        let space = specialKey("space", #selector(tapSpace), wide: true)
        let ret = specialKey("return", #selector(tapReturn), wide: false)
        [mode, globe, space, ret].forEach { bottom.addArrangedSubview($0) }
        mode.widthAnchor.constraint(equalTo: bottom.widthAnchor, multiplier: 0.13).isActive = true
        globe.widthAnchor.constraint(equalTo: bottom.widthAnchor, multiplier: 0.13).isActive = true
        ret.widthAnchor.constraint(equalTo: bottom.widthAnchor, multiplier: 0.2).isActive = true
        keysView.addArrangedSubview(bottom)
    }

    private func charKey(_ ch: String) -> UIButton {
        let b = keyButton(shifted && !symbols ? ch.uppercased() : ch, dark: false)
        b.addTarget(self, action: #selector(tapChar(_:)), for: .touchUpInside)
        return b
    }

    private func specialKey(_ title: String, _ sel: Selector, wide: Bool, highlighted: Bool = false) -> UIButton {
        let b = keyButton(title, dark: !highlighted)
        if highlighted { b.backgroundColor = .white }
        b.titleLabel?.font = .systemFont(ofSize: title.count > 2 ? 15 : 20)
        b.addTarget(self, action: sel, for: .touchUpInside)
        return b
    }

    private func keyButton(_ title: String, dark: Bool) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.setTitleColor(.black, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 22)
        b.backgroundColor = dark ? UIColor(red: 0.68, green: 0.70, blue: 0.74, alpha: 1) : .white
        b.layer.cornerRadius = 6
        b.layer.shadowColor = UIColor.black.cgColor; b.layer.shadowOpacity = 0.25; b.layer.shadowOffset = CGSize(width: 0, height: 1); b.layer.shadowRadius = 0
        return b
    }

    @objc private func tapChar(_ sender: UIButton) {
        guard let t = sender.title(for: .normal) else { return }
        handTyped()                                   // typing wins: dictation never deletes back into your keys
        textDocumentProxy.insertText(t)
        if shifted && !symbols { shifted = false; layoutKeys() }
    }
    @objc private func tapShift() { if symbols { return }; shifted.toggle(); layoutKeys() }
    @objc private func tapSymbols() { symbols.toggle(); shifted = false; layoutKeys() }
    @objc private func tapBackspace() { handTyped(); textDocumentProxy.deleteBackward() }
    @objc private func tapSpace() { handTyped(); textDocumentProxy.insertText(" ") }
    @objc private func tapReturn() { handTyped(); textDocumentProxy.insertText("\n") }
    @objc private func tapGlobe() { advanceToNextInputMode() }
    @objc private func tapMacro(_ sender: UIButton) {
        guard let text = sender.accessibilityLabel else { return }
        handTyped()
        textDocumentProxy.insertText(text)
    }
}
