import Foundation

/// Pure decision: is this monitored session "done" (no longer needs the Mac kept awake)?
/// Extracted from the Coordinator so it can be reasoned about and unit-tested in isolation.
enum DoneRule {
    static func isDone(_ s: AgentSession, policy p: SessionPolicy, armedAt: Date?, now: Date) -> Bool {
        if p.kind == .never { return false }                      // pinned awake until stopped
        guard let armed = armedAt else { return false }           // not armed → nothing is "done"
        // A session whose process exited can't do more work — done under any trigger.
        if s.endedAt != nil { return true }
        guard let quiet = p.quietSeconds else { return false }    // off / never aren't time-based
        guard !s.subagentsActive, !s.midTurn else { return false } // actively executing a turn
        if p.waitForChildren, s.toolRunning { return false }       // opted in: hold for bg/servers
        // Quiet time counts from the LATER of last activity and the arm. Arming mid-flight works
        // (each transcript write pushes the reference forward); arming an already-stopped session
        // works too — the window runs from the arm, so it can't fire before you've had the full
        // grace to close the lid (and the lid guard means an open-lid Mac never force-sleeps).
        let reference = max(s.lastSeen, armed)
        return now.timeIntervalSince(reference) >= TimeInterval(quiet)
    }
}
