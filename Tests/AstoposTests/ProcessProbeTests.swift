import Testing
import Foundation
@testable import Astopos

/// Exercises the transcript parsers against real-shaped JSONL written to temp files.
@Suite struct ProcessProbeTests {
    private func tmp(_ lines: [String]) -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        try! lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    // MARK: Claude

    @Test func claudeSummaryFromFirstUserPrompt() {
        let path = tmp([
            #"{"type":"user","message":{"content":"review this PR"},"timestamp":"2026-06-09T10:00:00.000Z"}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"ok"}]},"isSidechain":false,"timestamp":"2026-06-09T10:00:01.000Z"}"#
        ])
        #expect(ProcessProbe.summarize(path, agent: .claude) == "review this PR")
    }

    @Test func claudeSummarySkipsSystemWrappers() {
        let path = tmp([
            #"{"type":"user","message":{"content":"<system-reminder>noise</system-reminder>"},"timestamp":"2026-06-09T10:00:00.000Z"}"#,
            #"{"type":"user","message":{"content":[{"type":"text","text":"do the real task"}]},"timestamp":"2026-06-09T10:00:02.000Z"}"#
        ])
        #expect(ProcessProbe.summarize(path, agent: .claude) == "do the real task")
    }

    @Test func claudeSubagentActiveWhenLastEntryIsSidechain() {
        let active = tmp([
            #"{"type":"user","message":{"content":"go"},"timestamp":"2026-06-09T10:00:00.000Z"}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"sub"}]},"isSidechain":true,"timestamp":"2026-06-09T10:00:01.000Z"}"#
        ])
        #expect(ProcessProbe.subagentActive(active, agent: .claude))

        let inactive = tmp([
            #"{"type":"user","message":{"content":"go"},"timestamp":"2026-06-09T10:00:00.000Z"}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"done"}]},"isSidechain":false,"timestamp":"2026-06-09T10:00:01.000Z"}"#
        ])
        #expect(!ProcessProbe.subagentActive(inactive, agent: .claude))
    }

    @Test func claudeAwaitingToolWhenLastEntryIsUnansweredToolUse() {
        let pending = tmp([
            #"{"type":"user","message":{"content":"build it"},"timestamp":"2026-06-09T10:00:00.000Z"}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{}}]},"isSidechain":false,"timestamp":"2026-06-09T10:00:01.000Z"}"#
        ])
        #expect(ProcessProbe.awaitingTool(pending, agent: .claude))

        let answered = tmp([
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{}}]},"isSidechain":false,"timestamp":"2026-06-09T10:00:01.000Z"}"#,
            #"{"type":"user","message":{"content":[{"tool_use_id":"t1","type":"tool_result","content":"ok"}]},"timestamp":"2026-06-09T10:05:00.000Z"}"#
        ])
        #expect(!ProcessProbe.awaitingTool(answered, agent: .claude))

        let yielded = tmp([
            #"{"type":"user","message":{"content":"hi"},"timestamp":"2026-06-09T10:00:00.000Z"}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"all done"}]},"isSidechain":false,"timestamp":"2026-06-09T10:00:01.000Z"}"#
        ])
        #expect(!ProcessProbe.awaitingTool(yielded, agent: .claude))
    }

    @Test func codexAwaitingToolOnUnansweredFunctionCall() {
        let pending = tmp([
            #"{"type":"response_item","payload":{"type":"function_call","name":"shell"},"timestamp":"2026-06-09T10:00:01.000Z"}"#
        ])
        #expect(ProcessProbe.awaitingTool(pending, agent: .codex))

        let answered = tmp([
            #"{"type":"response_item","payload":{"type":"function_call","name":"shell"},"timestamp":"2026-06-09T10:00:01.000Z"}"#,
            #"{"type":"response_item","payload":{"type":"function_call_output","output":"ok"},"timestamp":"2026-06-09T10:02:00.000Z"}"#
        ])
        #expect(!ProcessProbe.awaitingTool(answered, agent: .codex))
    }

    // MARK: Codex

    @Test func codexSummaryFromUserMessage() {
        let path = tmp([
            #"{"type":"session_meta","payload":{"cwd":"/x","id":"abc"},"timestamp":"2026-06-09T10:00:00.000Z"}"#,
            #"{"type":"event_msg","payload":{"type":"task_started"},"timestamp":"2026-06-09T10:00:00.500Z"}"#,
            #"{"type":"event_msg","payload":{"type":"user_message","message":"refactor the indexer"},"timestamp":"2026-06-09T10:00:01.000Z"}"#
        ])
        #expect(ProcessProbe.summarize(path, agent: .codex) == "refactor the indexer")
    }

    @Test func codexHasNoSubagents() {
        let path = tmp([
            #"{"type":"event_msg","payload":{"type":"user_message","message":"hi"},"timestamp":"2026-06-09T10:00:01.000Z"}"#
        ])
        #expect(!ProcessProbe.subagentActive(path, agent: .codex))
    }

    @Test func codexRolloutMetaSurvivesHugeFirstLine() {
        // Codex embeds its full base instructions in the session_meta line (observed 22KB+);
        // a fixed 16KB read used to truncate it mid-JSON and silently drop the session.
        let pad = String(repeating: "x", count: 40_000)
        let meta = #"{"timestamp":"2026-06-11T09:12:33.742Z","type":"session_meta","payload":{"id":"abc-123","cwd":"/p/astopos","base_instructions":{"text":"\#(pad)"}}}"#
        let path = tmp([
            meta,
            #"{"type":"event_msg","payload":{"type":"user_message","message":"hello codex"},"timestamp":"2026-06-11T09:13:00.000Z"}"#
        ])
        let r = ProcessProbe.rolloutMeta(path)
        #expect(r?.id == "abc-123")
        #expect(r?.cwd == "/p/astopos")
        #expect(ProcessProbe.summarize(path, agent: .codex) == "hello codex")
    }

    @Test func descendantsIncludeGrandchildrenAndClassifyCaffeinateSeparately() {
        let rows = ProcessProbe.parseProcessRows("""
          10   1 /usr/local/bin/claude
          11  10 /bin/zsh
          12  11 /opt/homebrew/bin/node
          13  10 /usr/bin/caffeinate
        """)
        let byParent = Dictionary(grouping: rows, by: \.ppid)
        let descendants = ProcessProbe.descendants(of: 10, in: byParent)
        #expect(Set(descendants.map(\.pid)) == [11, 12, 13])
        let kinds = ProcessProbe.childKinds(in: descendants)
        #expect(kinds.real)
        #expect(kinds.caffeinate)
    }

    @Test func caffeinateOnlyDescendantIsAgentActiveNotRealWork() {
        let rows = ProcessProbe.parseProcessRows("""
          10   1 /usr/local/bin/claude
          13  10 /usr/bin/caffeinate
        """)
        let byParent = Dictionary(grouping: rows, by: \.ppid)
        let kinds = ProcessProbe.childKinds(in: ProcessProbe.descendants(of: 10, in: byParent))
        #expect(!kinds.real)
        #expect(kinds.caffeinate)
    }

    @Test func backgroundCwdHeuristicFindsReparentedServerButIgnoresShellsAndKnownPids() {
        let processes = [
            ProcessProbe.CwdProcess(pid: 20, command: "/opt/homebrew/bin/node", cwd: "/p/app"),
            ProcessProbe.CwdProcess(pid: 21, command: "/bin/zsh", cwd: "/p/app"),
            ProcessProbe.CwdProcess(pid: 22, command: "/opt/homebrew/bin/python3", cwd: "/p/app"),
            ProcessProbe.CwdProcess(pid: 23, command: "/opt/homebrew/bin/node", cwd: "/p/other")
        ]
        let cwds = ProcessProbe.backgroundCwds(from: processes,
                                               watchedCwds: ["/p/app"],
                                               excludedPids: [22])
        #expect(cwds == ["/p/app"])
        #expect(ProcessProbe.isBackgroundWorkCommand("/bin/zsh") == false)
        #expect(ProcessProbe.isBackgroundWorkCommand("/opt/homebrew/bin/node"))
    }

    @Test func parseLsofCwdOutput() {
        let processes = ProcessProbe.parseCwdProcesses("""
        p20
        cnode
        n/p/app
        p21
        czsh
        n/p/app
        """)
        #expect(processes == [
            ProcessProbe.CwdProcess(pid: 20, command: "node", cwd: "/p/app"),
            ProcessProbe.CwdProcess(pid: 21, command: "zsh", cwd: "/p/app")
        ])
    }

    @Test func missingFileIsSafe() {
        #expect(ProcessProbe.summarize("/no/such/file.jsonl", agent: .claude) == "")
        #expect(!ProcessProbe.subagentActive("/no/such/file.jsonl", agent: .claude))
    }
}
