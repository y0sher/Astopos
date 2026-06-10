import Foundation
import Combine

/// High-level power state shown in the menu bar.
enum PowerMode: String, Codable {
    case normal      // system sleeps as usual
    case armed       // keep-awake active (lid can be closed)
}

/// A Claude or Codex session Astopos is tracking (discovered by polling transcripts).
struct AgentSession: Identifiable, Equatable {
    let id: String          // session_id
    let agent: ProcessProbe.Agent   // .claude / .codex
    var cwd: String         // project folder
    var transcript: String  // transcript path
    var summary: String     // first human prompt, for naming
    var lastSeen: Date      // last transcript write (mtime), refreshed each poll
    var subagentsActive: Bool   // a subagent is currently the latest writer (Claude)
    var toolRunning: Bool   // a background child process (e.g. a server it launched) is alive
    var midTurn: Bool = false   // transcript shows a tool call with no result yet (executing now)
    var agentBusy: Bool = false // claude is holding its caffeinate (working a turn — e.g. a long
                                // thinking stretch where the transcript goes quiet for minutes)
    var endedAt: Date?      // process exited

    var idleSeconds: Int { max(0, Int(Date().timeIntervalSince(lastSeen))) }

    /// Working = the agent is actively executing (subagent, mid-turn on a tool, or holding its
    /// keep-awake while generating), or the transcript was written very recently. A background
    /// child (server) alone is NOT "working" — whether it holds the Mac awake is the per-session
    /// waitForChildren choice.
    var isWorking: Bool {
        endedAt == nil && (subagentsActive || midTurn || agentBusy || idleSeconds < 15)
    }

    var folderName: String {
        let leaf = (cwd as NSString).lastPathComponent
        return leaf.isEmpty ? (cwd.isEmpty ? String(id.prefix(8)) : cwd) : leaf
    }
    var label: String { summary.isEmpty ? folderName : summary }
}

/// Per-session rule: when does THIS session stop needing the Mac kept awake. (PLAN.md §3.)
struct SessionPolicy: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case off           // not monitored (default)
        case onStop        // sleep as soon as the agent yields the turn (finished OR asking)
        case idle          // yields and stays quiet for `idleMinutes`
        case never         // hold the Mac awake until stopped manually (server / long-runner)
        // Note: a session whose process *exits* is treated as done under any trigger (handled in
        // Coordinator.sessionDone), so there's no separate "on session end" option — it would never
        // fire for an interactive session left open with the lid closed anyway.

        var label: String {
            switch self {
            case .off:    return "Don’t monitor"
            case .onStop: return "On stop"
            case .idle:   return "Idle N min"
            case .never:  return "Never (keep awake)"
            }
        }
    }
    var kind: Kind = .off
    var idleMinutes: Int = 10
    /// Opt-in: ALSO hold the Mac awake for background child processes the session left running
    /// (a dev server, a backgrounded build). Default off — a stopped session lets the Mac sleep
    /// even if it spawned a server. A tool executing mid-turn always blocks, regardless.
    var waitForChildren: Bool = false

    init(kind: Kind = .off, idleMinutes: Int = 10, waitForChildren: Bool = false) {
        self.kind = kind; self.idleMinutes = idleMinutes; self.waitForChildren = waitForChildren
    }

    /// Tolerant decoding so policies persisted by an older build (missing newer keys) survive.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .off
        idleMinutes = try c.decodeIfPresent(Int.self, forKey: .idleMinutes) ?? 10
        waitForChildren = try c.decodeIfPresent(Bool.self, forKey: .waitForChildren) ?? false
    }
    private enum CodingKeys: String, CodingKey { case kind, idleMinutes, waitForChildren }

    var isMonitored: Bool { kind != .off }

    /// Quiet-time required for the trigger, or nil if the trigger isn't time-based.
    /// `onStop` uses a short grace so we confirm a real yield (transcript writes stop) rather than
    /// a mid-turn pause — during a turn the transcript keeps being written.
    var quietSeconds: Int? {
        switch kind {
        case .onStop:       return 45
        case .idle:         return idleMinutes * 60
        case .off, .never:  return nil
        }
    }

    var summary: String {
        switch kind {
        case .idle: return "idle \(idleMinutes)m"
        default:    return kind.label.lowercased()
        }
    }
}

/// Single source of truth for the UI. Lives on the main actor.
/// Policies and the two toggles persist via UserDefaults so a relaunch (crash, update) doesn't
/// lose the user's choices — still-running sessions are re-discovered with the same ids.
@MainActor
final class AppState: ObservableObject {
    @Published var mode: PowerMode = .normal
    @Published var sessions: [AgentSession] = []

    /// When we armed; only work finishing AFTER this counts as "done". Published for the UI's
    /// per-session countdowns.
    @Published var armedAt: Date?

    /// When the watchdog hard-cap will fire (nil = not running). Display only.
    @Published var watchdogDeadline: Date?

    // WHICH is derived from each session's trigger: monitored ⇔ policy.kind != .off.
    @Published var policies: [String: SessionPolicy] = [:] { didSet { savePolicies() } }

    @Published var silentSudoInstalled: Bool = false
    /// File present AND its rule actually matches the command we run (stale installs fail this).
    @Published var silentSudoWorks: Bool = false

    /// Optional: while armed, hold the screen awake (no auto-lock) instead of letting it turn off.
    /// Mainly affects the lid-open case; with the lid shut the panel is off by hardware regardless.
    @Published var keepScreenAwake: Bool = false {
        didSet { UserDefaults.standard.set(keepScreenAwake, forKey: Keys.keepScreenAwake) }
    }

    /// Hard cap: revert no matter what after this many minutes (0 = disabled).
    @Published var watchdogMinutes: Int = 120 {
        didSet { UserDefaults.standard.set(watchdogMinutes, forKey: Keys.watchdogMinutes) }
    }

    @Published var lastStatus: String = "Normal"

    private enum Keys {
        static let policies = "policies"
        static let keepScreenAwake = "keepScreenAwake"
        static let watchdogMinutes = "watchdogMinutes"
    }

    init() {
        keepScreenAwake = UserDefaults.standard.bool(forKey: Keys.keepScreenAwake)
        watchdogMinutes = UserDefaults.standard.object(forKey: Keys.watchdogMinutes) as? Int ?? 120
        if let data = UserDefaults.standard.data(forKey: Keys.policies),
           let saved = try? JSONDecoder().decode([String: SessionPolicy].self, from: data) {
            policies = saved
        }
    }

    private func savePolicies() {
        if let data = try? JSONEncoder().encode(policies) {
            UserDefaults.standard.set(data, forKey: Keys.policies)
        }
    }

    /// Drop policies whose session no longer exists (called once discovery has run, and as ended
    /// sessions are removed) so the persisted dict stays bounded.
    func prunePolicies() {
        let live = Set(sessions.map(\.id))
        for id in policies.keys where !live.contains(id) { policies.removeValue(forKey: id) }
    }

    func isMonitored(_ id: String) -> Bool { policy(for: id).isMonitored }
    var monitoredSessions: [AgentSession] { sessions.filter { isMonitored($0.id) } }
    var hasSelection: Bool { sessions.contains { isMonitored($0.id) } }

    func policy(for id: String) -> SessionPolicy { policies[id] ?? SessionPolicy() }

    /// Mutate one field of a session's policy in place.
    func updatePolicy(_ id: String, _ mutate: (inout SessionPolicy) -> Void) {
        var p = policy(for: id); mutate(&p); policies[id] = p
    }

    /// Convenience: set every session to a trigger (or off).
    func setAll(_ kind: SessionPolicy.Kind) { for x in sessions { updatePolicy(x.id) { $0.kind = kind } } }

    /// Merge a session discovered by polling.
    func merge(discovered id: String, agent: ProcessProbe.Agent, cwd: String, transcript: String) {
        if sessions.contains(where: { $0.id == id }) { return }
        sessions.append(AgentSession(id: id, agent: agent, cwd: cwd, transcript: transcript,
                                      summary: "", lastSeen: .distantPast, subagentsActive: false,
                                      toolRunning: false, endedAt: nil))
    }
}
