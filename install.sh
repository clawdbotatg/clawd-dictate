#!/bin/sh
# clawd-dictate — build the app bundle and install (or re-install) the launchd agent.
#   sh install.sh          # venv + deps + clawd-dictate.app + agent, then starts it
#   sh install.sh --stop   # stop + remove the agent (app + venv stay)
#
# The app is a tiny launcher binary that embeds Python and runs dictate.py from
# this checkout — so macOS permissions (Microphone, Accessibility, Input
# Monitoring) are granted to "clawd-dictate", once, and survive every git pull.
# The launcher is only rebuilt when app/main.c changes (a rebuild changes the
# signature → macOS asks again).
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
LABEL=com.clawd.dictate
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
APP="$HERE/clawd-dictate.app"
BIN="$APP/Contents/MacOS/clawd-dictate"
UID_="$(id -u)"

if [ "$1" = "--stop" ]; then
  launchctl bootout "gui/$UID_/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  echo "stopped + removed $LABEL"
  exit 0
fi

PY=""
for c in /opt/homebrew/bin/python3.13 /usr/local/bin/python3.13; do
  if [ -x "$c" ]; then PY="$c"; break; fi
done
[ -n "$PY" ] || { echo "need python3.13 (brew install python@3.13)"; exit 1; }
[ -d "$HERE/.venv" ] || "$PY" -m venv "$HERE/.venv"
"$HERE/.venv/bin/pip" install -q sounddevice pynput websockets pyobjc-framework-Cocoa pyobjc-framework-ApplicationServices pyobjc-framework-Quartz

# ── the bundle ────────────────────────────────────────────────────────────────
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$HERE/app/Info.plist" "$APP/Contents/Info.plist"
[ -f "$HERE/app/clawd-dictate.icns" ] || "$HERE/.venv/bin/python" "$HERE/app/icon.py"
cp "$HERE/app/clawd-dictate.icns" "$APP/Contents/Resources/clawd-dictate.icns"
if [ ! -x "$BIN" ] || [ "$HERE/app/main.c" -nt "$BIN" ]; then
  echo "building launcher…"
  CFG="${PY}-config"
  # shellcheck disable=SC2046
  clang -O2 -o "$BIN" "$HERE/app/main.c" $("$CFG" --embed --cflags) $("$CFG" --embed --ldflags) \
    -Wl,-rpath,"$(dirname "$("$CFG" --prefix)")" 2>&1 | grep -v "warning: " || true
  [ -x "$BIN" ] || { echo "launcher build failed"; exit 1; }
  codesign --force --sign - --identifier com.clawd.dictate "$APP" >/dev/null 2>&1 || codesign --force --sign - "$APP"
  echo "built + signed $APP"
fi

# ── the agent ────────────────────────────────────────────────────────────────
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$BIN</string></array>
  <key>WorkingDirectory</key><string>$HERE</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>5</integer>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/clawd-dictate.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/clawd-dictate.log</string>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
  </dict>
</dict></plist>
EOF

launchctl bootout "gui/$UID_/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID_" "$PLIST"
launchctl kickstart -k "gui/$UID_/$LABEL"
sleep 1
echo "installed $LABEL — log: ~/Library/Logs/clawd-dictate.log"
echo "first run: allow 'clawd-dictate' under Microphone, Accessibility and Input Monitoring"
echo "(System Settings → Privacy & Security); then double-tap Control and talk."
