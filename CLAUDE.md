# clawd-dictate — orientation for Claude

Austin's dictation, everywhere, with HIS words: Deepgram nova-3 biased with one
shared word list (Codex, ethskills, clawd…) plus hard replace rules
("on chain => onchain"). Three surfaces read the same list:

| surface | where | how it hears |
| --- | --- | --- |
| harness mic (🎤 / space-hold) | `clawd-harness/index.html` | page's own WebSocket to Deepgram |
| **Mac**: `clawd-dictate.app` | `dictate.py`, `app/`, `install.sh` | double-tap Control → Deepgram → typed live into the field that had focus at the start (`Focus` anchor: AX element + window title; a move ends that dictation and starts a new one where the cursor is; ); one Control tap, Enter or Escape stops |
| **iPhone**: `clawd keys` keyboard + `clawd dictate` app | `ios/` | keyboard asks the app; the app records |
| **iPhone**: `clawd harness` app | `ios/Harness/` | the harness PAGE in a native web view — same 🎤, no per-launch mic prompt |

**`EXPECTATIONS.md` is the contract** (Austin, 09-17): always listening, one
field = one dictation, fast, never breaks itself. Read it before touching any
surface. The phone writes `Library/dictate.log` in the App Group container (both the
app and the keyboard); the pull command is in EXPECTATIONS.md — pull it
before guessing at any phone problem.

## The word list (single source of truth)

- **Built-in terms + rules** live in the harness: `STT_BASE_TERMS` /
  `STT_BASE_RULES` in `clawd-harness/index.html`. The Mac tool parses the
  local checkout; the phone fetches it raw from GitHub. Add a name every
  surface should know THERE.
- **Austin's own list** (the ⚙️ box in the harness) is `stt-words.txt` on the
  relay's doc shelf. Page: `GET|POST /stt/words` (passkey session). Mac:
  `~/bin/fleet-docs get` (machine credential). Phone: `/docs/get` with the
  read-only `clawd-phone` credential (prefix `stt-words` only). Plain lines
  are keyterms; `from => to` lines are rules. Deepgram takes ≤ 100 keyterms.
- Deepgram key: `DEEPGRAM_API_KEY` in `clawd-harness/.clawd-harness.env`
  (every fleet box has it except bambu). This key can't mint temp tokens.

## Mac (`dictate.py`)

- **It's a real app bundle on purpose** (Austin, 09-15): `app/main.c` is a
  launcher that embeds Python 3.13 and runs `dictate.py` from the checkout,
  so macOS permissions (Mic, Accessibility, Input Monitoring) are granted to
  "clawd-dictate" and survive `git pull`. Rebuilding the launcher (a
  `main.c` change) resets those grants — avoid. Never make him grant
  permissions to bare `python`.
- launchd `com.clawd.dictate`, log `~/Library/Logs/clawd-dictate.log`,
  `sh install.sh` (re)installs, `--stop` removes. Python 3.14's venv is
  broken on this Mac; install.sh uses 3.13.
- Headless checks: `.venv/bin/python dictate.py --words` / `--test x.wav`
  (16 kHz mono). The gesture/paste can only be tested by a human.

## iPhone (`ios/`)

- **Keyboard extensions cannot record audio** (Apple). So: `clawd keys` (the
  keyboard) ↔ `clawd dictate` (the app, background audio) over the App Group
  `group.com.clawd.dictate` (UserDefaults mailbox: `state`, `cmd`,
  `text.interim`, `text.final`, `text.seq`, `session.alive` heartbeat) +
  Darwin notifications `com.clawd.dictate.cmd|text`. The first start opens
  the app via `clawddictate://start` — ONLY `EnvironmentValues().openURL` /
  a SwiftUI `Link` work on iOS 18+ (responder-chain and extensionContext
  hacks are dead, see `openApp`); after that the mic stays open 24 h and starts at once.
- **Mic between dictations: OPEN (orange dot), socket CLOSED.** Austin (09-15) wants no hop, and iOS refuses to start a mic in the background, so the mic stays open 24 h after the last dictation; the Deepgram socket exists only during a dictation and the locked audio gate controls sends. Stop invalidates pending starts; callbacks are scoped to a run token. Keyboard leases expire after 6 s (20 s for the app hop), and each recording is capped at 10 min. Releasing the mic was tried and rejected (hop on every keyboard use). Audio streams to Deepgram only while listening — the tap drops buffers otherwise. **"Mic open" means `engine.isRunning`, never a flag**: iOS stops the engine on its own (call, Siri, another app's mic, AirPods connecting, media reset) and never restarts it. The 2 s heartbeat checks the engine first and reopens a stopped one, or declares the mic closed so the keyboard hops. Before 09-17 a stale flag made "listening" stream silence until the app was killed.
- The keyboard is a plain QWERTY with a bar on top (red dot = listening).
  It auto-starts when it appears. Each keyboard owns a UUID and a text-field/cursor anchor; no adoption by age. A field/cursor/context change ends that dictation and starts a new one in the new field at once (clicking into a box means record); Return ALWAYS stops (next document or keyboard re-show restarts). Start/stop mailbox commands use that same UUID; wake URLs carry it as `?id=…`. Typing a key commits the interim before appending.
- Build: `sh ios/gen-secrets.sh` (Secrets.swift, gitignored — from `~/.config/clawd-dictate/env`: HARNESS_URL, CAL_URL, SLOP_URL, DEEPGRAM_API_KEY, DOCS_CREDENTIAL) → `cd ios &&
  xcodegen generate` → `xcodebuild -scheme ClawdDictate -derivedDataPath build
  -destination 'id=00008150-001205C63A04401C' -allowProvisioningUpdates build`
  (**`-derivedDataPath build` is not optional**: without it Xcode builds into
  ~/Library/Developer/Xcode/DerivedData and the install step below ships
  whatever stale binary sits in `ios/build` — that put the 09-15 build back
  on the phone on 09-17; the code lives in `*.debug.dylib`, check its date)
  → `xcrun devicectl device install app
  --device 8B053FBC-B638-548F-B045-F5DDE25D3BDD build/Build/Products/Debug-iphoneos/ClawdDictate.app`.
  Set `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` first (the
  default toolchain is the CLT). Team is **XX7QP5899Z** (Xcode's account),
  not the X8PV53H794 on the old cert. Phone must be plugged in + unlocked.
- Verified working on Austin's iPhone 17 Pro (iOS 26.6) on 2026-09-15.

## iPhone: `clawd harness` (`ios/Harness/`, target `ClawdHarness`)

- **Why it exists (Austin, 09-17):** the home-screen PWA asks for the mic on
  EVERY launch (WebKit 215884; iOS has no "always allow" for web apps). A
  native app is asked ONCE by iOS; `WebView.swift` then answers the page's
  `getUserMedia` itself (`requestMediaCapturePermissionFor` → `.grant` for the
  relay origin, mic only). Nothing else is native: one WKWebView on
  `Secrets.relay`, fleet mode, the passkey, the page's own Deepgram socket.
- **Passkey in a web view needs BOTH halves** or WebAuthn throws
  NotAllowedError and the gate never opens: the app's Associated Domains
  (`Harness.entitlements`, written by `gen-secrets.sh` from `HARNESS_URL`,
  gitignored — the relay host must not be in the repo) and the relay naming
  the app in `/.well-known/apple-app-site-association` (`FLEET_AASA_APPS` in
  the box's `fleet.env` = `XX7QP5899Z.com.clawd.dictate.harness`;
  `clawd-harness/fleet/test_aasa.py`). `?mode=developer` on the entitlement
  makes a dev-signed build skip Apple's day-long AASA CDN cache.
- Also fixed vs. a bare web view: 🔊 voice audio plays without a tap
  (`mediaTypesRequiringUserActionForPlayback = []`); `window.open` /
  `target=_blank` go to Safari; a killed content process reloads the page.
  UA carries `clawd-harness-app` if the page ever needs to know.
- No Web Speech fallback in WKWebView — a box without a Deepgram key has no
  mic in the app (every fleet box has one except bambu).
- Build (laptop, phone plugged in + unlocked), same recipe as the dictate app:
  `sh ios/gen-secrets.sh && cd ios && xcodegen generate && export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && xcodebuild -project ClawdDictate.xcodeproj -scheme ClawdHarness -destination 'id=00008150-001205C63A04401C' -derivedDataPath build -allowProvisioningUpdates build && xcrun devicectl device install app --device 8B053FBC-B638-548F-B045-F5DDE25D3BDD build/Build/Products/Debug-iphoneos/ClawdHarness.app`
  (`DEVELOPER_DIR` must be exported, not prefixed: `xcrun devicectl` needs it too).
  **A NEW bundle id needs its profile minted once in Xcode's GUI** (09-17):
  xcodebuild under the harness (launchd) can't read the Apple account Xcode
  keeps in the protected keychain and fails with "No Accounts" even while
  Xcode shows the account signed in. Open the xcodeproj in Xcode, pick the
  target → Signing & Capabilities → Team = Austin Griffith; the profile lands
  in `~/Library/Developer/Xcode/UserData/Provisioning Profiles/` and every
  later build works from here without the account (why the dictate app never
  needed this: its profiles date from 09-15). **Do this with the entitlements
  file present and non-empty** — on 09-17 it had been emptied to `<dict/>`
  (root cause: an `entitlements:` block in `project.yml` makes `xcodegen
  generate` REWRITE the file, empty when no properties are listed; it is now a
  `CODE_SIGN_ENTITLEMENTS` setting, which only references it — keep it that
  way), so Xcode minted a WILDCARD profile under a
  different app-id prefix (QA8C2ZSAYY.*): no Associated Domains, the passkey
  button did nothing (WebAuthn NotAllowedError, silent), and the later
  correct build was refused as an upgrade (prefix mismatch) until
  `xcrun devicectl device uninstall app --device … com.clawd.dictate.harness`.
  **Before every install, verify the signed app:**
  `codesign -d --entitlements :- build/Build/Products/Debug-iphoneos/ClawdHarness.app`
  must show `webcredentials:<relay>` and `XX7QP5899Z.com.clawd.dictate.harness`.
  First run: the page's passkey gate → Face ID; first 🎤 tap → iOS's one
  mic prompt for "clawd harness"; after that, never.

## Rules

- Ship by default (commit + push; Mac: `git pull` is the deploy; phone:
  rebuild + install). Secret scan before every commit; `Secrets.swift`,
  `.venv`, the built `.app` and `.xcodeproj` are gitignored.
- Git identity clawdbotatg / clawd@buidlguidl.com, HTTPS; branch `master`.
- Plain English, few words, no slop.

- **Nothing personal in the repo**: no keys, no credentials, and no URLs of Austin's (relay, calendar links). They live in `~/.config/clawd-dictate/env` (HARNESS_URL, CAL_URL, SLOP_URL, …). History was rewritten once (2026-09-15) to scrub URLs — keep it that way.
