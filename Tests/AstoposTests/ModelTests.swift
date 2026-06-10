import Testing
import Foundation
@testable import Astopos

@Suite struct SessionPolicyTests {
    @Test func quietSeconds() {
        #expect(SessionPolicy(kind: .off).quietSeconds == nil)
        #expect(SessionPolicy(kind: .never).quietSeconds == nil)
        #expect(SessionPolicy(kind: .onStop).quietSeconds == 45)
        #expect(SessionPolicy(kind: .idle, idleMinutes: 10).quietSeconds == 600)
        #expect(SessionPolicy(kind: .idle, idleMinutes: 2).quietSeconds == 120)
    }

    @Test func isMonitored() {
        #expect(!SessionPolicy(kind: .off).isMonitored)
        #expect(SessionPolicy(kind: .onStop).isMonitored)
        #expect(SessionPolicy(kind: .idle).isMonitored)
        #expect(SessionPolicy(kind: .never).isMonitored)
    }

    @Test func summary() {
        #expect(SessionPolicy(kind: .idle, idleMinutes: 15).summary == "idle 15m")
        #expect(SessionPolicy(kind: .onStop).summary == "on stop")
        #expect(SessionPolicy(kind: .never).summary == "never (keep awake)")
    }
}

@Suite struct AgentSessionTests {
    private func make(lastSeenAgo: TimeInterval, subagents: Bool = false, tool: Bool = false,
                      midTurn: Bool = false, ended: Bool = false, summary: String = "",
                      cwd: String = "/a/b/proj") -> AgentSession {
        AgentSession(id: "s", agent: .claude, cwd: cwd, transcript: "/t.jsonl", summary: summary,
                     lastSeen: Date().addingTimeInterval(-lastSeenAgo), subagentsActive: subagents,
                     toolRunning: tool, midTurn: midTurn, endedAt: ended ? Date() : nil)
    }

    @Test func isWorking() {
        #expect(make(lastSeenAgo: 1).isWorking)               // recent write
        #expect(make(lastSeenAgo: 9999, midTurn: true).isWorking)    // tool executing mid-turn
        #expect(make(lastSeenAgo: 9999, subagents: true).isWorking)  // subagent
        #expect(!make(lastSeenAgo: 9999, tool: true).isWorking)      // bg child alone ≠ working
        #expect(!make(lastSeenAgo: 100).isWorking)            // quiet, nothing running → idle
        #expect(!make(lastSeenAgo: 1, ended: true).isWorking) // ended → not working
    }

    @Test func idleSeconds() {
        #expect((88...92).contains(make(lastSeenAgo: 90).idleSeconds))
    }

    @Test func labelPrefersSummaryElseFolder() {
        #expect(make(lastSeenAgo: 0, summary: "review this PR").label == "review this PR")
        #expect(make(lastSeenAgo: 0, summary: "").label == "proj")
    }

    @Test func folderName() {
        #expect(make(lastSeenAgo: 0, cwd: "/Users/me/dev/mrkts-ai").folderName == "mrkts-ai")
    }
}
