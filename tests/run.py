#!/usr/bin/env python3
"""Run Swift regressions on macOS without a microphone, network or app credentials."""
import pathlib
import subprocess
import tempfile
import uuid

root = pathlib.Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="dictate-tests-") as directory:
    tmp = pathlib.Path(directory)
    session = (root / "ios/App/Session.swift").read_text()
    session = session.replace("import AVFoundation", "import Combine").replace("import UIKit", "")
    start = session.index("    // MARK: audio")
    end = session.index("    // MARK: deepgram", start)
    session = session[:start] + """
    private var micRunning: Bool { alive && !TestIO.micDead }
    private var inBackground: Bool { false }
    private func heartbeatTick() { Shared.defaults.set(Date(), forKey: Shared.kAlive) }
    private func openMic() throws { TestIO.micOpens += 1; TestIO.micDead = false }
    private func closeMic() { alive = false }
""" + session[end:]
    session = session.replace("URLSession", "StubURLSession")
    (tmp / "Session.swift").write_text(session)
    shared = (root / "ios/Shared/Shared.swift").read_text()
    shared = shared.replace('"group.com.clawd.dictate"', '"test.dictate.' + str(uuid.uuid4()) + '"')
    (tmp / "Shared.swift").write_text(shared)
    subprocess.run(["swiftc", str(tmp / "Session.swift"), str(tmp / "Shared.swift"),
                    str(root / "ios/Shared/RecordingRun.swift"), str(root / "tests/SessionTests.swift"),
                    "-o", str(tmp / "tests")], check=True)
    subprocess.run([str(tmp / "tests")], check=True)
