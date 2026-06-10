import Foundation

/// Persisted intent so we can always get back to normal — even after a crash or a missed
/// permission. Written *before* we touch pmset; reconciled on launch (PLAN.md §5, layer 1).
struct DesiredState: Codable {
    var mode: PowerMode
    var armedAt: Date?
    var reason: String   // e.g. "babysitting ~/dev/Astopos"
}

enum StateStore {
    private static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Astopos", isDirectory: true)
    }
    private static var file: URL { dir.appendingPathComponent("state.json") }

    static func save(_ s: DesiredState) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(s) {
            try? data.write(to: file, options: .atomic)
        }
    }

    static func load() -> DesiredState? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(DesiredState.self, from: data)
    }

    /// On launch: if we previously armed but the app died without reverting, revert now.
    /// Returns a human-readable note if it took action. The revert needs admin rights — if the
    /// password is refused, say so honestly (and don't overwrite the state file with "normal",
    /// so the next launch retries) instead of claiming the reconcile happened.
    @discardableResult
    static func reconcile() -> String? {
        guard let s = load() else { return nil }
        let pmsetSaysAwake = PowerManager.isDisableSleepActive()
        switch s.mode {
        case .normal:
            if pmsetSaysAwake {
                if PowerManager.disarm() {
                    return "Reconciled: reverted stale keep-awake from a previous run."
                }
                return "Keep-awake was left ON and the password wasn't accepted — hit Reset to restore normal sleep."
            }
        case .armed:
            // We were armed and the app is starting fresh — treat as orphaned: revert to be safe.
            if PowerManager.disarm() {
                save(DesiredState(mode: .normal, armedAt: nil, reason: "reconciled-on-launch"))
                return "Reconciled: previous session left keep-awake on — reverted."
            }
            return "Previous session left keep-awake ON and the password wasn't accepted — hit Reset to restore normal sleep."
        }
        return nil
    }
}
