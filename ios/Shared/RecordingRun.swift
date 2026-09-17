import Foundation

/// A new token for every start keeps late permission, socket and flush callbacks
/// from changing a later dictation. Only a live keyboard lease permits streaming.
struct RecordingRun {
    enum Phase { case starting, streaming, stopping }
    let token = UUID()
    let id: String
    let keyboard: Bool
    let started = Date()
    var phase: Phase = .starting

    func expired(now: Date = Date(), leaseUntil: Date?) -> Bool {
        if now.timeIntervalSince(started) >= 10 * 60 { return true }
        return keyboard && (leaseUntil == nil || leaseUntil! <= now)
    }
}

/// Stop waits for an in-flight send to finish, then removes the sending target.
/// The audio thread never reads Session's main-thread state.
final class AudioGate<T> {
    private let lock = NSLock()
    private var target: T?

    func set(_ value: T?) {
        lock.lock(); defer { lock.unlock() }
        target = value
    }

    func withTarget(_ body: (T) -> Void) {
        lock.lock(); defer { lock.unlock() }
        if let target = target { body(target) }
    }
}

/// A transcript belongs to a field and cursor position, not just a recent time.
struct TextAnchor: Equatable {
    let document: UUID
    let before: String?
    let after: String?

    /// No context (nil) and an empty field ("") are the same thing: many hosts,
    /// web views included, report nil until the field has text. Refusing them
    /// refused every empty composer ("place the cursor in an editable field").
    func permits(_ current: TextAnchor, selected: String?) -> Bool {
        document == current.document && (before ?? "") == (current.before ?? "")
            && (after ?? "") == (current.after ?? "") && (selected ?? "").isEmpty
    }

    func canResume(id: String, publishedID: String?, current: TextAnchor, selected: String?) -> Bool {
        !id.isEmpty && id == publishedID && permits(current, selected: selected)
    }
}
