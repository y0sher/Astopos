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

    @Test func missingFileIsSafe() {
        #expect(ProcessProbe.summarize("/no/such/file.jsonl", agent: .claude) == "")
        #expect(!ProcessProbe.subagentActive("/no/such/file.jsonl", agent: .claude))
    }
}
