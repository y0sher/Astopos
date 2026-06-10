import Foundation
import IOKit

/// OS-level probing for both Claude Code and OpenAI Codex sessions: discover running sessions,
/// read transcript tails to tell working/stopped/idle, and detect background processes (servers).
///
/// Neither CLI is required to install anything — we poll their on-disk transcripts:
///   • Claude: ~/.claude/projects/<encoded-cwd>/<session_id>.jsonl
///   • Codex:  ~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl (meta line carries cwd + id)
/// Background processes a session spawned (e.g. a server) are children of the claude/codex process,
/// found via the process tree.
enum ProcessProbe {

    enum Agent: String, Codable { case claude, codex }

    struct RunningSession {
        let agent: Agent
        let id: String
        let cwd: String
        let transcript: String
    }

    // MARK: - discovery

    static func runningSessions() -> [RunningSession] { claudeRunning() + codexRunning() }

    /// One running `claude` process == one session, but several can share a cwd. So count processes
    /// per cwd (K) and take the K most-recently-active transcripts in that project — surfacing all
    /// open sessions, not just the newest.
    private static func claudeRunning() -> [RunningSession] {
        var out: [RunningSession] = []
        for (cwd, count) in processCountByCwd(named: "claude") {
            for path in newestTranscripts(forCwd: cwd, limit: count) {
                let id = (path as NSString).lastPathComponent.replacingOccurrences(of: ".jsonl", with: "")
                out.append(.init(agent: .claude, id: id, cwd: cwd, transcript: path))
            }
        }
        return out
    }

    private static func codexRunning() -> [RunningSession] {
        let counts = processCountByCwd(named: "codex")
        guard !counts.isEmpty else { return [] }                   // zero cost when codex isn't running
        let rollouts = recentRollouts(limit: 200)
        var out: [RunningSession] = []
        for (cwd, count) in counts {
            for r in rollouts.filter({ $0.cwd == cwd }).prefix(count) {
                out.append(.init(agent: .codex, id: r.id, cwd: cwd, transcript: r.path))
            }
        }
        return out
    }

    private static func processCountByCwd(named name: String) -> [String: Int] {
        var perCwd: [String: Int] = [:]
        for pid in pids(named: name) { if let c = cwdOf(pid) { perCwd[c, default: 0] += 1 } }
        return perCwd
    }

    // MARK: - transcript reading

    /// True if a subagent (Claude sidechain) is the latest writer — used to keep awake during
    /// subagent work, which runs in-process (no child process to detect). Codex has no subagents.
    static func subagentActive(_ path: String, agent: Agent) -> Bool {
        guard agent == .claude, let lines = tail(path) else { return false }
        for line in lines.reversed() {
            guard let obj = json(line), let type = obj["type"] as? String,
                  type == "assistant" || type == "user" else { continue }
            return (obj["isSidechain"] as? Bool) ?? false
        }
        return false
    }

    /// True if the session is mid-turn executing a tool — the transcript's last meaningful entry
    /// is a tool call with no result yet (e.g. a long build running in the foreground). This is
    /// what keeps a quiet-looking transcript from reading as "stopped" while work is in flight.
    /// Distinct from background children: a server the session left running is NOT mid-turn.
    static func awaitingTool(_ path: String, agent: Agent) -> Bool {
        guard let lines = tail(path) else { return false }
        if agent == .claude {
            for line in lines.reversed() {
                guard let obj = json(line), let type = obj["type"] as? String else { continue }
                if type == "assistant" {
                    let content = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
                    return content.contains { ($0["type"] as? String) == "tool_use" }
                }
                if type == "user" { return false }   // a prompt or a tool_result — no tool pending
            }
            return false
        }
        // Codex rollouts: a function_call with no function_call_output yet means a tool is running.
        for line in lines.reversed() {
            guard let obj = json(line), let p = obj["payload"] as? [String: Any],
                  let t = p["type"] as? String else { continue }
            switch t {
            case "function_call": return true
            case "function_call_output", "message", "task_complete", "user_message": return false
            default: continue
            }
        }
        return false
    }

    /// First human prompt in the session (for naming). Skips system-injected wrappers.
    static func summarize(_ path: String, agent: Agent) -> String {
        guard let fh = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? fh.close() }
        let data = (try? fh.read(upToCount: 65_536)) ?? Data()
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let obj = json(String(line)) else { continue }
            var text = ""
            if agent == .claude {
                guard obj["type"] as? String == "user", (obj["isSidechain"] as? Bool) != true else { continue }
                let c = (obj["message"] as? [String: Any])?["content"]
                if let s = c as? String { text = s }
                else if let arr = c as? [[String: Any]] {
                    text = arr.compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }
                        .joined(separator: " ")
                }
            } else {
                guard obj["type"] as? String == "event_msg",
                      let p = obj["payload"] as? [String: Any], p["type"] as? String == "user_message"
                else { continue }
                text = p["message"] as? String ?? ""
            }
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
            if clean.isEmpty || clean.hasPrefix("<") { continue }   // skip <system-reminder>/command wrappers
            return String(clean.prefix(500))   // row truncates to one line; full text shown in the ⓘ popover
        }
        return ""
    }

    // MARK: - background-process (server / running tool) detection

    /// Child-process probe, one pass for the whole poll. Children are split into two signals:
    ///   • busy        — a real child (tool executing / server it launched) is alive
    ///   • agentActive — claude is holding its own `caffeinate -i -t 300`, which it keeps alive
    ///     the whole time it's working a turn. This catches long generation stretches (extended
    ///     thinking) where the transcript goes quiet for minutes with no tool running — the one
    ///     state the transcript alone can't distinguish from "stopped".
    static func busyState() -> (busy: Set<String>, agentActive: Set<String>) {
        var busy = Set<String>(), agent = Set<String>()
        for pid in pids(named: "claude") + pids(named: "codex") {
            let kids = childKinds(pid)
            guard kids.real || kids.caffeinate, let c = cwdOf(pid) else { continue }
            if kids.real { busy.insert(c) }
            if kids.caffeinate { agent.insert(c) }
        }
        return (busy, agent)
    }

    /// cwds that currently have a real (non-caffeinate) child — kept for the --probe debug path.
    static func busyCwds() -> Set<String> { busyState().busy }

    static func pids(forCwd cwd: String) -> [Int32] {
        (pids(named: "claude") + pids(named: "codex")).filter { cwdOf($0) == cwd }
    }

    /// True if any of these cwds has a live child process (used by the --probe debug command).
    static func hasLiveShells(amongCwds cwds: Set<String>) -> Bool {
        let busy = busyCwds()
        return cwds.contains { busy.contains($0) }
    }

    // MARK: - lid

    /// Lid state read directly from IOKit (`IOPMrootDomain.AppleClamshellState`): true = closed,
    /// false = open, nil = unknown (e.g. desktop Mac). No `ioreg` spawn.
    static func lidClosed() -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let prop = IORegistryEntryCreateCFProperty(
            service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        else { return nil }
        return (prop as? Bool)
    }

    static func mtime(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    // MARK: - implementation

    /// The `limit` most-recently-modified transcripts in a cwd's Claude project dir.
    private static func newestTranscripts(forCwd cwd: String, limit: Int) -> [String] {
        let enc = cwd.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects/\(enc)", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        return files.filter { $0.pathExtension == "jsonl" }
            .sorted { mtime($0.path) ?? .distantPast > mtime($1.path) ?? .distantPast }
            .prefix(max(1, limit)).map(\.path)
    }

    private struct Rollout { let path: String; let cwd: String; let id: String }

    /// Newest `limit` codex rollout files (by mtime), each with its meta cwd + session id.
    private static func recentRollouts(limit: Int) -> [Rollout] {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
        guard let en = FileManager.default.enumerator(
            at: base, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        var files: [(URL, Date)] = []
        for case let u as URL in en where u.pathExtension == "jsonl"
            && u.lastPathComponent.hasPrefix("rollout-") {
            let m = (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            files.append((u, m ?? .distantPast))
        }
        return files.sorted { $0.1 > $1.1 }.prefix(limit).compactMap { rolloutMeta($0.0.path) }
    }

    private static func rolloutMeta(_ path: String) -> Rollout? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        let data = (try? fh.read(upToCount: 16_384)) ?? Data()
        guard let line = String(decoding: data, as: UTF8.self).split(separator: "\n").first,
              let d = json(String(line)), let p = d["payload"] as? [String: Any],
              let cwd = p["cwd"] as? String, !cwd.isEmpty else { return nil }
        let id = p["id"] as? String ?? (path as NSString).lastPathComponent
        return Rollout(path: path, cwd: cwd, id: id)
    }

    /// Read the tail of a JSONL file as lines (drops a possibly-partial first line).
    private static func tail(_ path: String, window: UInt64 = 262_144) -> [String]? {
        guard !path.isEmpty, let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        let end = (try? fh.seekToEnd()) ?? 0
        let start = end > window ? end - window : 0
        try? fh.seek(toOffset: start)
        guard let data = try? fh.readToEnd(), !data.isEmpty else { return nil }
        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        return lines
    }

    private static func json(_ line: String) -> [String: Any]? {
        guard let d = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }

    private static func pids(named name: String) -> [Int32] {
        // Exact process-name match first (the native claude/codex binaries). The fallback covers
        // wrapper installs (`node /path/claude`) but is anchored so the name must be a whole word
        // at a path boundary — a bare `pgrep -f claude` would also match MCP servers,
        // `tail -f ~/.claude/...`, editors with .claude paths in their args, etc., creating
        // phantom sessions.
        let primary = capture("/usr/bin/pgrep", ["-x", name]) ?? ""
        let text = primary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (capture("/usr/bin/pgrep", ["-f", "(^|/)\(name)($| )"]) ?? "") : primary
        return text.split(whereSeparator: \.isNewline).compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }

    private static func cwdOf(_ pid: Int32) -> String? {
        guard let out = capture("/usr/sbin/lsof", ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"]) else { return nil }
        return out.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("n") }).map { String($0.dropFirst()) }
    }

    /// Classify a process's children: real work (tool/server) vs claude's own caffeinate helper.
    /// (`pgrep -l` lists "pid name".)
    private static func childKinds(_ pid: Int32) -> (real: Bool, caffeinate: Bool) {
        guard let out = capture("/usr/bin/pgrep", ["-l", "-P", "\(pid)"]) else { return (false, false) }
        var real = false, caf = false
        for line in out.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            if parts[1].trimmingCharacters(in: .whitespaces) == "caffeinate" { caf = true } else { real = true }
        }
        return (real, caf)
    }

    private static func capture(_ path: String, _ args: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        do {
            try p.run(); p.waitUntilExit()
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        } catch { return nil }
    }
}
