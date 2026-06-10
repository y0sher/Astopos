import Foundation

// Entry point. Normally launches the SwiftUI menu-bar app; the flags below are poll/debug helpers.
let args = CommandLine.arguments

if args.contains("--lid") {
    switch ProcessProbe.lidClosed() {
    case .some(true): print("lid: closed")
    case .some(false): print("lid: open")
    case .none: print("lid: unknown")
    }
    exit(0)
}

if args.contains("--discover") {
    let sessions = ProcessProbe.runningSessions()
    let busy = ProcessProbe.busyState()
    // Mirror the app's attribution: cwd-level child signals belong to the most recent writer.
    var latestByCwd: [String: Date] = [:]
    for s in sessions {
        let m = ProcessProbe.mtime(s.transcript) ?? .distantPast
        latestByCwd[s.cwd] = max(latestByCwd[s.cwd] ?? .distantPast, m)
    }
    print("discovered \(sessions.count) running session(s):")
    for s in sessions {
        let mtime = ProcessProbe.mtime(s.transcript) ?? .distantPast
        let idle = Int(-mtime.timeIntervalSinceNow)
        let isLatest = mtime >= (latestByCwd[s.cwd] ?? .distantPast)
        let sub = ProcessProbe.subagentActive(s.transcript, agent: s.agent)
        let mid = ProcessProbe.awaitingTool(s.transcript, agent: s.agent)
        let summary = ProcessProbe.summarize(s.transcript, agent: s.agent)
        print("  [\(s.agent.rawValue)] \((s.cwd as NSString).lastPathComponent)  idle=\(idle)s subagent=\(sub) midTurn=\(mid) agentBusy=\(isLatest && busy.agentActive.contains(s.cwd)) bg=\(isLatest && busy.busy.contains(s.cwd))  \"\(summary)\"")
    }
    exit(0)
}

if let i = args.firstIndex(of: "--probe"), i + 1 < args.count {
    let cwd = args[i + 1]
    let pids = ProcessProbe.pids(forCwd: cwd)
    print("cwd=\(cwd)")
    print("matching claude/codex PIDs: \(pids)")
    print("has live background shells: \(ProcessProbe.hasLiveShells(amongCwds: [cwd]))")
    exit(0)
}

// Default: GUI.
AstoposApp.main()
