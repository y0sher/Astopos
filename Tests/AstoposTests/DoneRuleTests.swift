import Testing
import Foundation
@testable import Astopos

/// The core decision: when is a monitored session "done" (Mac may sleep)?
@Suite struct DoneRuleTests {
    let now = Date()

    private func session(lastSeenAgo: TimeInterval = 0, subagents: Bool = false,
                         tool: Bool = false, endedAgo: TimeInterval? = nil) -> AgentSession {
        AgentSession(id: "s", agent: .claude, cwd: "/p/proj", transcript: "/t.jsonl",
                     summary: "", lastSeen: now.addingTimeInterval(-lastSeenAgo),
                     subagentsActive: subagents, toolRunning: tool,
                     endedAt: endedAgo.map { now.addingTimeInterval(-$0) })
    }
    private func policy(_ k: SessionPolicy.Kind, idle: Int = 10) -> SessionPolicy {
        SessionPolicy(kind: k, idleMinutes: idle)
    }
    private func done(_ s: AgentSession, _ p: SessionPolicy, armedAgo: TimeInterval?) -> Bool {
        DoneRule.isDone(s, policy: p, armedAt: armedAgo.map { now.addingTimeInterval(-$0) }, now: now)
    }

    @Test func neverIsNeverDone() {
        #expect(!done(session(lastSeenAgo: 99_999, endedAgo: 1), policy(.never), armedAgo: 100))
    }

    @Test func offNotDone() {
        #expect(!done(session(lastSeenAgo: 99_999), policy(.off), armedAgo: 100))
    }

    @Test func idleNotElapsed() {
        #expect(!done(session(lastSeenAgo: 100), policy(.idle, idle: 10), armedAgo: 2000))
    }

    @Test func idleElapsed() {
        #expect(done(session(lastSeenAgo: 700), policy(.idle, idle: 10), armedAgo: 2000))
    }

    @Test func onStopGrace() {
        #expect(!done(session(lastSeenAgo: 30), policy(.onStop), armedAgo: 2000))
        #expect(done(session(lastSeenAgo: 60), policy(.onStop), armedAgo: 2000))
    }

    @Test func notEligibleIfIdleBeforeArming() {
        // Armed 10s ago, but last activity was 700s ago → already idle; don't sleep.
        #expect(!done(session(lastSeenAgo: 700), policy(.idle, idle: 10), armedAgo: 10))
    }

    @Test func runningToolBlocks() {
        #expect(!done(session(lastSeenAgo: 700, tool: true), policy(.idle, idle: 10), armedAgo: 2000))
    }

    @Test func subagentBlocks() {
        #expect(!done(session(lastSeenAgo: 700, subagents: true), policy(.idle, idle: 10), armedAgo: 2000))
    }

    @Test func endedAfterArmIsDoneRegardlessOfIdle() {
        #expect(done(session(lastSeenAgo: 1, endedAgo: 5), policy(.onStop), armedAgo: 100))
    }

    @Test func endedBeforeArmIsNotDone() {
        #expect(!done(session(lastSeenAgo: 1, endedAgo: 200), policy(.onStop), armedAgo: 100))
    }

    @Test func notArmedNeverDone() {
        #expect(!done(session(lastSeenAgo: 99_999), policy(.idle), armedAgo: nil))
    }
}
