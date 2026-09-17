#!/usr/bin/env python3
"""clawd-dictate — double-tap Control, talk, Deepgram types it where your cursor is.

The harness mic, system-wide on the Mac. Same recognizer (Deepgram nova-3),
same word list (the ⚙️ list shared on the relay + the harness's built-in terms
and replace rules, read straight out of clawd-harness/index.html so the three
surfaces never drift). The words are TYPED live into the field that had focus
when you started — revised as Deepgram settles them, editing only the tail
that changed. Move the cursor to another field, chat or app and that
dictation ends there; a new one starts where you are (EXPECTATIONS.md) — and
a small pill at the bottom of the screen (clawd, listening) says the mic is
on. One Control tap (or Enter, or Escape) stops.

Runs as a launchd agent (install.sh). Needs three one-time permissions for the
venv's python: Microphone, Accessibility (the paste keystroke) and Input
Monitoring (the Control double-tap). macOS asks the first time each is used.

    dictate.py            # the daemon
    dictate.py --test f.wav   # stream a 16 kHz mono wav through the same pipeline, print the text
    dictate.py --words        # print the word list + rules in effect
"""
import json, os, re, subprocess, sys, threading, time, queue
from pathlib import Path

HOME = Path.home()
HARNESS = Path(os.environ.get("CLAWD_HARNESS", HOME / "clawd" / "clawd-harness"))
CONF = HOME / ".config" / "clawd-dictate"
WORDS_CACHE = CONF / "words.txt"
WORDS_DOC = "stt-words.txt"                     # the shared list on the relay's doc shelf
FLEET_DOCS = HOME / "bin" / "fleet-docs"
DG_URL = "wss://api.deepgram.com/v1/listen"
DOUBLE_TAP_S = 0.40                              # two Control presses inside this = the gesture
TAIL_S = 1.5                                     # wait this long for the last finals after CloseStream
WORDS_REFRESH_S = 300


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


# ── config: key + word list ──────────────────────────────────────────────────
def deepgram_key():
    k = os.environ.get("DEEPGRAM_API_KEY", "")
    if k:
        return k
    try:
        for line in (HARNESS / ".clawd-harness.env").read_text().splitlines():
            if line.startswith("DEEPGRAM_API_KEY="):
                return line.split("=", 1)[1].strip().strip('"').strip("'")
    except OSError:
        pass
    return ""


def _js_strings(block):
    return [m.group(1) for m in re.finditer(r"'((?:[^'\\]|\\.)*)'", block)]


def harness_builtins():
    """STT_BASE_TERMS + STT_BASE_RULES exactly as the harness page has them."""
    try:
        html = (HARNESS / "index.html").read_text()
    except OSError:
        return [], []
    terms, rules = [], []
    m = re.search(r"const STT_BASE_TERMS = \[(.*?)\];", html, re.S)
    if m:
        terms = _js_strings(m.group(1))
    m = re.search(r"const STT_BASE_RULES = \[(.*?)\];", html, re.S)
    if m:
        pairs = re.findall(r"\['((?:[^'\\]|\\.)*)',\s*'((?:[^'\\]|\\.)*)'\]", m.group(1))
        rules = [list(p) for p in pairs]
    return terms, rules


def parse_words(text):
    """The ⚙️ box, parsed like the page: plain lines are words, `from => to` are rules."""
    words, rules = [], []
    for line in re.split(r"[\n,;]+", text or ""):
        m = re.match(r"^\s*(.+?)\s*(?:=>|->|→)\s*(.+?)\s*$", line)
        if m:
            rules.append([m.group(1), m.group(2)])
        elif line.strip():
            words.append(line.strip())
    return words, rules


def fetch_shared_words():
    """The shared list from the relay (fleet-docs credential), cached on disk so a
    relay hiccup never costs a dictation. Returns the text ('' if none yet)."""
    CONF.mkdir(parents=True, exist_ok=True)
    if FLEET_DOCS.exists():
        tmp = CONF / "words.tmp"
        try:
            r = subprocess.run([str(FLEET_DOCS), "get", WORDS_DOC, str(tmp)], capture_output=True, text=True, timeout=20)
            if r.returncode == 0 and tmp.exists():
                tmp.replace(WORDS_CACHE)
            else:
                tmp.unlink(missing_ok=True)
        except (OSError, subprocess.SubprocessError) as e:
            log("words: fetch failed:", e)
    try:
        return WORDS_CACHE.read_text()
    except OSError:
        return ""


class Vocab:
    """keyterms + compiled rules, refreshed in the background."""
    def __init__(self):
        self.terms, self.rules, self.lock = [], [], threading.Lock()
        self.refresh()

    def refresh(self):
        shared = fetch_shared_words()
        uw, ur = parse_words(shared)
        bt, br = harness_builtins()
        seen, terms = set(), []
        for t in uw + [r[1] for r in ur] + bt:
            t = t.strip()
            if t and len(t) <= 40 and t.lower() not in seen:
                seen.add(t.lower()); terms.append(t)
        rules = []
        for frm, to in ur + br:
            frm = frm.strip()
            if frm:
                rules.append((re.compile(r"\b" + re.escape(frm).replace(r"\ ", r"[\s,.]+") + r"\b", re.I), to))   # "ETH, skills" too
        with self.lock:
            self.terms, self.rules = terms[:100], rules
        log(f"words: {len(terms)} terms, {len(rules)} rules ({len(uw)} shared words, {len(ur)} shared rules)")

    def fix(self, text):
        with self.lock:
            rules = list(self.rules)
        for rx, to in rules:
            text = rx.sub(to, text)
        return text

    def url(self):
        from urllib.parse import urlencode
        with self.lock:
            terms = list(self.terms)
        q = [("model", "nova-3"), ("language", "en"), ("encoding", "linear16"), ("sample_rate", "16000"),
             ("channels", "1"), ("smart_format", "true"), ("interim_results", "true"), ("endpointing", "300")]
        q += [("keyterm", t) for t in terms]
        return DG_URL + "?" + urlencode(q)


# ── one dictation: mic → Deepgram → live text → pasted ───────────────────────
class Dictation:
    def __init__(self, key, vocab, on_text, on_done):
        self.key, self.vocab, self.on_text, self.on_done = key, vocab, on_text, on_done
        self.q = queue.Queue()
        self.finals, self.interim = [], ""
        self.stopping = self.cancelled = False
        self.moved = False                    # replaced by a restart: its callbacks are ignored
        self.ws = None
        self.stream = None
        self.closed = threading.Event()

    def text(self):
        t = " ".join(self.finals + ([self.interim] if self.interim else []))
        return self.vocab.fix(re.sub(r"\s+", " ", t).strip())

    def start(self):
        threading.Thread(target=self._run, daemon=True).start()

    def _run(self):
        from websockets.sync.client import connect
        import sounddevice as sd
        try:
            self.ws = connect(self.vocab.url(), additional_headers={"Authorization": "Token " + self.key},
                              open_timeout=8, max_size=None)
        except Exception as e:
            log("deepgram: connect failed:", e)
            self.on_done(self, None)
            return
        threading.Thread(target=self._recv, daemon=True).start()

        def cb(indata, frames, t, status):
            if not self.stopping:
                self.q.put(bytes(indata))
        try:
            self.stream = sd.RawInputStream(samplerate=16000, channels=1, dtype="int16", blocksize=1600, callback=cb)
            self.stream.start()
        except Exception as e:
            log("mic: failed:", e)
            self._close()
            self.on_done(self, None)
            return
        while not self.stopping:
            try:
                chunk = self.q.get(timeout=0.2)
            except queue.Empty:
                continue
            try:
                self.ws.send(chunk)
            except Exception as e:
                log("deepgram: send failed:", e)
                break
        try:
            self.stream.stop(); self.stream.close()
        except Exception:
            pass
        try:
            self.ws.send(json.dumps({"type": "CloseStream"}))
        except Exception:
            pass
        self.closed.wait(TAIL_S)              # the flush: last finals land, then the server closes
        self._close()
        self.on_done(self, None if self.cancelled else self.text())

    def _recv(self):
        try:
            for msg in self.ws:
                if isinstance(msg, bytes):
                    continue
                m = json.loads(msg)
                if m.get("type") != "Results":
                    continue
                t = (((m.get("channel") or {}).get("alternatives") or [{}])[0].get("transcript") or "").strip()
                if m.get("is_final"):
                    if t:
                        self.finals.append(t)
                    self.interim = ""
                else:
                    self.interim = t
                self.on_text(self, self.text())
        except Exception as e:
            if not self.stopping:
                log("deepgram: recv ended:", e)
        finally:
            self.closed.set()

    def stop(self, cancel=False):
        self.cancelled = cancel
        self.stopping = True

    def _close(self):
        try:
            self.ws.close()
        except Exception:
            pass


# ── where the cursor is ──────────────────────────────────────────────────────
class Focus:
    """The field a dictation belongs to: the focused element and the title of
    its window (Accessibility API). Chats in the harness share one composer
    whose draft swaps per session — only the window title tells them apart;
    other apps swap the element or the window. A dictation is anchored to the
    focus it started in; when that changes it ends there and a new one starts
    where the cursor is now (EXPECTATIONS.md: one field, one dictation)."""
    def __init__(self):
        try:
            from ApplicationServices import (AXUIElementCreateSystemWide, AXUIElementCopyAttributeValue,
                                             kAXFocusedUIElementAttribute, kAXWindowAttribute, kAXTitleAttribute)
        except ImportError:
            self.ok = False
            return
        self.ok = True
        self.title_only = False               # set when element identity proves unreliable in some app
        self.sys = AXUIElementCreateSystemWide()
        self.get = AXUIElementCopyAttributeValue
        self.k_focused, self.k_window, self.k_title = kAXFocusedUIElementAttribute, kAXWindowAttribute, kAXTitleAttribute

    def now(self):
        """(element, window title), or None when nothing has focus."""
        if not self.ok:
            return None
        err, el = self.get(self.sys, self.k_focused, None)
        if err or el is None:
            return None
        title = None
        err, win = self.get(el, self.k_window, None)
        if not err and win is not None:
            err, title = self.get(win, self.k_title, None)
            if err:
                title = None
        return (el, title)

    def same(self, a, b):
        if a is None or b is None:
            return a is None and b is None
        if a[1] != b[1]:
            return False
        return self.title_only or a[0] == b[0]    # AXUIElement == is CFEqual: same pid + element

    @staticmethod
    def describe(a):
        return "nothing" if a is None else f"{a[1]!r}"


# ── the typist: live text into the focused field ─────────────────────────────
class Typist:
    """Keeps the focused field showing the dictation's text by editing only the
    tail that differs from what it already typed (finished words stay put, the
    in-progress segment is re-typed as it revises, a rule that rewrites an
    earlier word reaches back exactly as far as it must). Key events come from
    pynput's Controller, so this works in any app that takes typing."""
    def __init__(self, guard=lambda: True):
        from pynput.keyboard import Controller
        self.kb = Controller()
        self.written = ""
        self.lock = threading.Lock()
        self.busy = False
        self.guard = guard                     # False = the cursor left this dictation's field: type nothing

    def reset(self):
        with self.lock:
            self.written = ""

    def sync(self, target):
        from pynput.keyboard import Key
        target = (target or "").replace("\n", " ")
        with self.lock:
            if target == self.written:
                return
            if not self.guard():
                return
            common = 0
            for a, b in zip(self.written, target):
                if a != b:
                    break
                common += 1
            self.busy = True
            try:
                for _ in range(len(self.written) - common):
                    self.kb.press(Key.backspace); self.kb.release(Key.backspace)
                tail = target[common:]
                if tail:
                    self.kb.type(tail)
            finally:
                self.busy = False
            self.written = target


# ── the app: hotkey + overlay + typing ───────────────────────────────────────
class App:
    def __init__(self):
        self.key = deepgram_key()
        if not self.key:
            sys.exit("no DEEPGRAM_API_KEY (env, or DEEPGRAM_API_KEY= in clawd-harness/.clawd-harness.env)")
        self.vocab = Vocab()
        self.cur = None
        self.last_ctrl = 0.0
        self.ui = None
        self.focus = Focus()
        self.anchor = None                    # the focus the current dictation belongs to
        self.misses = 0
        self.moves = []                       # times of recent restarts with an unchanged title (loop detector)
        self.typist = Typist(guard=lambda: self.focus.same(self.anchor, self.focus.now()))

    # -- hotkey: Control double-tap toggles; Escape cancels a live one
    def on_press(self, key):
        from pynput.keyboard import Key
        if key in (Key.ctrl, Key.ctrl_l, Key.ctrl_r):
            if self.cur:                      # listening: ONE Control tap stops (no need to double)
                self.last_ctrl = 0.0
                self.toggle()
                return
            now = time.monotonic()
            if now - self.last_ctrl < DOUBLE_TAP_S:
                self.last_ctrl = 0.0
                self.toggle()
            else:
                self.last_ctrl = now
        elif key == Key.esc and self.cur and not self.typist.busy:
            self.cur.stop()
        elif key == Key.enter and self.cur and not self.typist.busy:
            self.restart("Enter")             # Enter reaches the app (sends the message); we keep listening for the next one

    def toggle(self):
        if self.cur:
            self.ui.show("finishing…")        # the last words land, then the pill goes
            self.cur.stop()
            return
        self.begin()

    def begin(self):
        self.anchor = self.focus.now()
        self.misses = 0
        self.typist.reset()
        self.ui.show()
        d = Dictation(self.key, self.vocab, self.on_text, self.on_done)
        self.cur = d
        d.start()

    def restart(self, why):
        """End the current dictation where it is (its late words are dropped,
        never typed somewhere else) and start a new one where the cursor is."""
        old = self.cur
        if not old:
            return
        old.moved = True
        old.stop(cancel=True)
        log(f"{why}: new dictation in {Focus.describe(self.focus.now())}")
        self.begin()

    def on_text(self, d, text):
        if d is not self.cur or getattr(d, "moved", False):
            return
        self.typist.sync(text)

    def on_done(self, d, text):
        if getattr(d, "moved", False):
            return                            # replaced by restart(); the new dictation owns the typist now
        if self.cur is d:
            self.cur = None
        if text is not None:
            self.typist.sync(text)
            log("dictation complete")
        self.typist.reset()
        self.ui.hide_after(0.2)

    def watch_loop(self):
        # The cursor moved to another field / chat / app: end the dictation
        # there and start a new one here. Two reads in a row must disagree —
        # one odd read (focus briefly nothing during a switch) is not a move.
        while True:
            time.sleep(0.25)
            d = self.cur
            if not d or self.typist.busy:
                continue
            now = self.focus.now()
            if self.focus.same(self.anchor, now):
                self.misses = 0
                continue
            self.misses += 1
            if self.misses >= 2 and self.cur is d:
                if self.anchor and now and self.anchor[1] == now[1]:
                    # same window title, "different" element: if this keeps happening the
                    # element compare is lying for this app — trust the title alone
                    self.moves = [t for t in self.moves if time.monotonic() - t < 5] + [time.monotonic()]
                    if len(self.moves) >= 2 and not self.focus.title_only:
                        self.focus.title_only = True
                        log("element identity unreliable here — comparing window titles only")
                        self.anchor = now
                        self.misses = 0
                        continue
                self.restart("focus moved")

    def words_loop(self):
        while True:
            time.sleep(WORDS_REFRESH_S)
            try:
                self.vocab.refresh()
            except Exception as e:
                log("words: refresh failed:", e)

    def trust_loop(self):
        # The first run isn't trusted (Accessibility / Input Monitoring): the key
        # listener stays deaf even after you flip the switch. Poll, and once
        # trust lands, exec ourselves so the listener is born trusted.
        try:
            from ApplicationServices import AXIsProcessTrusted
        except ImportError:
            return
        was = AXIsProcessTrusted()
        if not was:
            log("not trusted yet — allow 'clawd-dictate' under Accessibility + Input Monitoring; I'll restart myself")
            # ask, as the app: the dialogs then name clawd-dictate, not python
            try:
                from ApplicationServices import AXIsProcessTrustedWithOptions, kAXTrustedCheckOptionPrompt
                AXIsProcessTrustedWithOptions({kAXTrustedCheckOptionPrompt: True})
            except Exception as e:
                log("accessibility prompt failed:", e)
            try:
                import Quartz
                Quartz.CGRequestListenEventAccess()
            except Exception as e:
                log("input monitoring prompt failed:", e)
        while True:
            time.sleep(5)
            now = AXIsProcessTrusted()
            if now and not was:
                log("trusted now — restarting")
                # bundled (clawd-dictate.app): sys.executable is the launcher, which
                # finds the script itself; bare python needs the script path
                args = [sys.executable] + ([] if os.environ.get("CLAWD_DICTATE_BUNDLED") else sys.argv)
                os.execv(sys.executable, args)
            was = now

    def run(self):
        from pynput import keyboard
        self.ui = Overlay()
        keyboard.Listener(on_press=self.on_press).start()
        threading.Thread(target=self.words_loop, daemon=True).start()
        threading.Thread(target=self.trust_loop, daemon=True).start()
        threading.Thread(target=self.watch_loop, daemon=True).start()
        log("ready — double-tap Control to dictate")
        self.ui.run()


class Overlay:
    """A floating, non-activating pill at the bottom of the screen with the live
    text. Never takes focus — the paste has to land in the app you were in."""
    def __init__(self):
        from AppKit import (NSApplication, NSPanel, NSTextField, NSColor, NSFont, NSScreen,
                            NSWindowStyleMaskBorderless, NSWindowStyleMaskNonactivatingPanel,
                            NSBackingStoreBuffered, NSStatusWindowLevel, NSApplicationActivationPolicyAccessory,
                            NSStatusBar, NSMenu, NSMenuItem, NSVariableStatusItemLength)
        from Foundation import NSMakeRect
        self.app = NSApplication.sharedApplication()
        self.app.setActivationPolicy_(NSApplicationActivationPolicyAccessory)
        scr = NSScreen.mainScreen().visibleFrame()
        w, h = 250, 64
        self.rect = NSMakeRect(scr.origin.x + (scr.size.width - w) / 2, scr.origin.y + 24, w, h)
        self.panel = NSPanel.alloc().initWithContentRect_styleMask_backing_defer_(
            self.rect, NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel, NSBackingStoreBuffered, False)
        self.panel.setLevel_(NSStatusWindowLevel)
        self.panel.setOpaque_(False)
        self.panel.setBackgroundColor_(NSColor.colorWithCalibratedWhite_alpha_(0.08, 0.92))
        self.panel.setIgnoresMouseEvents_(True)
        self.panel.setHasShadow_(True)
        self.panel.setHidesOnDeactivate_(False)
        from AppKit import NSImage, NSImageView, NSImageScaleProportionallyUpOrDown
        logo = NSImage.alloc().initWithContentsOfFile_(str(Path(__file__).resolve().parent / "logo.png"))
        if logo:
            iv = NSImageView.alloc().initWithFrame_(NSMakeRect(10, 6, h - 12, h - 12))
            iv.setImage_(logo); iv.setImageScaling_(NSImageScaleProportionallyUpOrDown)
            self.panel.contentView().addSubview_(iv)
        self.label = NSTextField.alloc().initWithFrame_(NSMakeRect(h + 6, 10, w - h - 18, h - 20))
        self.label.setBezeled_(False); self.label.setDrawsBackground_(False)
        self.label.setEditable_(False); self.label.setSelectable_(False)
        self.label.setTextColor_(NSColor.whiteColor())
        self.label.setFont_(NSFont.systemFontOfSize_(17))
        self.label.setLineBreakMode_(0)   # NSLineBreakByWordWrapping
        self.label.setMaximumNumberOfLines_(1)
        self.label.setStringValue_("listening…")
        self.panel.contentView().addSubview_(self.label)
        # menu bar: 🎤 with Quit — the only way to know it's running
        self.item = NSStatusBar.systemStatusBar().statusItemWithLength_(NSVariableStatusItemLength)
        self.item.button().setTitle_("🎤")
        menu = NSMenu.alloc().init()
        menu.addItem_(NSMenuItem.alloc().initWithTitle_action_keyEquivalent_("double-tap Control to dictate", None, ""))
        menu.addItem_(NSMenuItem.alloc().initWithTitle_action_keyEquivalent_("Quit clawd-dictate", "terminate:", "q"))
        self.item.setMenu_(menu)
        self._hide_t = None

    def _main(self, fn):
        from PyObjCTools import AppHelper
        AppHelper.callAfter(fn)

    def show(self, text="listening…"):
        def go():
            if self._hide_t:
                self._hide_t.cancel(); self._hide_t = None
            self.label.setStringValue_(text)
            self.panel.orderFrontRegardless()
        self._main(go)

    def hide_after(self, secs):
        def go():
            if self._hide_t:
                self._hide_t.cancel()
            self._hide_t = threading.Timer(secs, lambda: self._main(lambda: self.panel.orderOut_(None)))
            self._hide_t.start()
        self._main(go)

    def run(self):
        from PyObjCTools import AppHelper
        AppHelper.runEventLoop()


# ── headless check: a wav through the same pipeline ──────────────────────────
def test_file(path):
    import wave
    from websockets.sync.client import connect
    key = deepgram_key()
    if not key:
        sys.exit("no DEEPGRAM_API_KEY")
    vocab = Vocab()
    with wave.open(path, "rb") as w:
        assert w.getframerate() == 16000 and w.getnchannels() == 1 and w.getsampwidth() == 2, "need 16 kHz mono int16 wav"
        pcm = w.readframes(w.getnframes())
    finals = []
    with connect(vocab.url(), additional_headers={"Authorization": "Token " + key}, max_size=None) as ws:
        for i in range(0, len(pcm), 8000):
            ws.send(pcm[i:i + 8000])
        ws.send(json.dumps({"type": "CloseStream"}))
        for msg in ws:
            m = json.loads(msg)
            if m.get("type") == "Results" and m.get("is_final"):
                t = m["channel"]["alternatives"][0]["transcript"].strip()
                if t:
                    finals.append(t)
    raw = " ".join(finals)
    print("raw:  ", raw)
    print("fixed:", vocab.fix(raw))


if __name__ == "__main__":
    if len(sys.argv) > 2 and sys.argv[1] == "--test":
        test_file(sys.argv[2])
    elif len(sys.argv) > 1 and sys.argv[1] == "--focus":
        # trusted-process check: what the Focus anchor sees, twice, and whether the two reads agree
        from ApplicationServices import AXIsProcessTrusted
        f = Focus()
        a, b = f.now(), f.now()
        err, el = f.get(f.sys, f.k_focused, None) if f.ok else (None, None)
        print("trusted:", AXIsProcessTrusted(), "| focus:", Focus.describe(a), "| same twice:", f.same(a, b), "| ax err:", err, "| element:", a and a[0])
    elif len(sys.argv) > 1 and sys.argv[1] == "--words":
        v = Vocab()
        print("terms:", ", ".join(v.terms))
        print("rules:", ", ".join(f"{rx.pattern} => {to}" for rx, to in v.rules))
    else:
        App().run()
