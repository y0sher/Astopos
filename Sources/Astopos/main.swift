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
    let busy = ProcessProbe.busyCwds()
    print("discovered \(sessions.count) running session(s):")
    for s in sessions {
        let idle = ProcessProbe.mtime(s.transcript).map { Int(-$0.timeIntervalSinceNow) } ?? -1
        let sub = ProcessProbe.subagentActive(s.transcript, agent: s.agent)
        let mid = ProcessProbe.awaitingTool(s.transcript, agent: s.agent)
        let summary = ProcessProbe.summarize(s.transcript, agent: s.agent)
        print("  [\(s.agent.rawValue)] \((s.cwd as NSString).lastPathComponent)  idle=\(idle)s subagent=\(sub) midTurn=\(mid) bg=\(busy.contains(s.cwd))  \"\(summary)\"")
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
