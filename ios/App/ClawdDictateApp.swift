// clawd dictate — the app half of the phone keyboard. It exists to hold the
// microphone: iOS keyboard extensions can't record, so the keyboard asks THIS
// app to listen (Darwin notification when the app is already alive in the
// background, clawddictate://start the first time) and reads the text back
// through the App Group. Same recognizer and word list as the harness mic.
import SwiftUI

@main
struct ClawdDictateApp: App {
    @StateObject private var session = Session.shared

    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(session)
                .onOpenURL { url in
                    guard url.scheme == "clawddictate" else { return }
                    guard url.host == "start",
                          let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value,
                          Shared.defaults.string(forKey: Shared.kCmd) == "start:" + id,
                          (Shared.leaseUntil(id: id) ?? .distantPast) > Date() else { return }
                    session.start(id: id)
                }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var session: Session
    var body: some View {
        VStack(spacing: 18) {
            Image("Logo").resizable().scaledToFit().frame(width: 170, height: 170).clipShape(RoundedRectangle(cornerRadius: 36))
            Text("clawd dictate").font(.title2).bold()
            Text(session.state).font(.headline).foregroundStyle(session.listening ? .red : (session.state.hasPrefix("error") ? .orange : .secondary))
            Text(session.listening ? "dictating — audio streaming" : (Shared.aliveNow ? "mic open, NOT streaming (no socket)" : "mic off"))
                .font(.caption2).foregroundStyle(.secondary)
            if !session.live.isEmpty {
                Text(session.live).font(.body).multilineTextAlignment(.center).padding(.horizontal)
            }
            Text(session.listening
                 ? (session.servingKeyboard
                    ? "Listening. Swipe back to the app you were typing in — the clawd keyboard is filling in your words."
                    : "Listening here. These words stay on this screen; a keyboard only takes its own dictation.")
                 : "Add the clawd keyboard: Settings → General → Keyboard → Keyboards → Add New Keyboard → clawd keys → Allow Full Access.\n\nThe first keyboard use hops through this app for a second so the mic can open — iOS allows nothing else. After that the mic stays open (orange dot) so there is no hop; audio only streams while the keyboard dot is red.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 24)
            HStack(spacing: 14) {
                Button(session.canStop ? "stop" : "listen") { session.canStop ? session.stop() : session.start() }
                    .buttonStyle(.borderedProminent)
                Button("refresh words") { session.refreshVocab() }.buttonStyle(.bordered)
            }
            Text("\(session.vocab.terms.count) words · \(session.vocab.rules.count) rules").font(.caption2).foregroundStyle(.secondary)
        }
        .padding()
        .onAppear { session.refreshVocab() }
    }
}
