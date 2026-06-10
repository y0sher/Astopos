import Testing
import Foundation
@testable import Astopos

/// The core decision: when is a monitored session "done" (Mac may sleep)?
@Suite struct DoneRuleTests {
    let now = Date()

    private func session(lastSeenAgo: TimeInterval = 0, subagents: Bool = false,
                         tool: Bool = false, midTurn: Bool = false,
                         endedAgo: TimeInterval? = nil) -> AgentSession {
        AgentSession(id: "s", agent: .claude, cwd: "/p/proj", transcript: "/t.jsonl",
                     summary: "", lastSeen: now.addingTimeInterval(-lastSeenAgo),
                     subagentsActive: subagents, toolRunning: tool, midTurn: midTurn,
                     endedAt: endedAgo.map { now.addingTimeInterval(-$0) })
    }
    private func policy(_ k: SessionPolicy.Kind, idle: Int = 10, wait: Bool = false) -> SessionPolicy {
        SessionPolicy(kind: k, idleMinutes: idle, waitForChildren: wait)
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

    @Test func armingAnAlreadyIdleSessionWaitsTheFullWindowFromArm() {
        // Armed 10s ago, last activity 700s ago → quiet counts from the ARM, so the 10-min
        // window has only run 10s: no insta-sleep right after arming.
        #expect(!done(session(lastSeenAgo: 700), policy(.idle, idle: 10), armedAgo: 10))
        // Once the window HAS elapsed since arming, it's done — even with no post-arm activity
        // (the arm-mid-flight / already-stopped case).
        #expect(done(session(lastSeenAgo: 9_999), policy(.idle, idle: 10), armedAgo: 700))
    }

    @Test func backgroundChildIgnoredByDefault() {
        // A server/bg process the session left running does NOT block sleep unless opted in.
        #expect(done(session(lastSeenAgo: 700, tool: true), policy(.idle, idle: 10), armedAgo: 2000))
    }

    @Test func backgroundChildBlocksWhenWaitForChildren() {
        #expect(!done(session(lastSeenAgo: 700, tool: true), policy(.idle, idle: 10, wait: true), armedAgo: 2000))
    }

    @Test func midTurnToolAlwaysBlocks() {
        // A tool executing mid-turn (long build, transcript quiet) blocks regardless of opt-in.
        #expect(!done(session(lastSeenAgo: 700, midTurn: true), policy(.idle, idle: 10), armedAgo: 2000))
        #expect(!done(session(lastSeenAgo: 700, midTurn: true), policy(.onStop), armedAgo: 2000))
    }

    @Test func subagentBlocks() {
        #expect(!done(session(lastSeenAgo: 700, subagents: true), policy(.idle, idle: 10), armedAgo: 2000))
    }

    @Test func endedIsDoneOnceArmed() {
        #expect(done(session(lastSeenAgo: 1, endedAgo: 5), policy(.onStop), armedAgo: 100))
        // Even if it ended before arming — a dead process can't do more work.
        #expect(done(session(lastSeenAgo: 1, endedAgo: 200), policy(.onStop), armedAgo: 100))
    }

    @Test func notArmedNeverDone() {
        #expect(!done(session(lastSeenAgo: 99_999), policy(.idle), armedAgo: nil))
        #expect(!done(session(lastSeenAgo: 99_999, endedAgo: 50), policy(.idle), armedAgo: nil))
    }
}
