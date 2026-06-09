import Foundation

/// Pure decision: is this monitored session "done" (no longer needs the Mac kept awake)?
/// Extracted from the Coordinator so it can be reasoned about and unit-tested in isolation.
enum DoneRule {
    static func isDone(_ s: AgentSession, policy p: SessionPolicy, armedAt: Date?, now: Date) -> Bool {
        if p.kind == .never { return false }                     // pinned awake until stopped
        let armed = armedAt ?? .distantFuture
        // A session whose process exited is done under any trigger — but only if it exited AFTER
        // arming (don't act on a session that was already gone when you armed).
        if let end = s.endedAt { return end > armed }
        guard let quiet = p.quietSeconds else { return false }    // off / never aren't time-based
        guard !s.subagentsActive, !s.toolRunning else { return false } // a tool/subagent is running
        guard s.lastSeen > armed else { return false }            // hasn't been active since arming
        return now.timeIntervalSince(s.lastSeen) >= TimeInterval(quiet)   // idle long enough
    }
}
