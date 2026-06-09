import Foundation
import Combine

/// Polls Claude/Codex transcripts + the OS probe and drives power actions via the observable state.
@MainActor
final class Coordinator: ObservableObject {
    let state = AppState()

    private var watchdog: Timer?
    private var evalTimer: Timer?
    private var lidTimer: Timer?
    private var lidClosed = false
    private var armedAt: Date?   // only work finishing AFTER this counts as "done"

    init() {
        // Layer 1 safety: undo anything a previous run left armed.
        if let note = StateStore.reconcile() { state.lastStatus = note }
        state.silentSudoInstalled = SudoersInstaller.isInstalled

        // Seed + scan right away, then poll on a cadence (60s while armed — battery-light, per the
        // user's request; 15s while idle so the picker feels responsive).
        poll()
        schedulePoll()
        // Lid watcher (light): screen off on close while armed, wake on open. Also nudges the UI so
        // the idle counter ticks between heavy polls.
        lidClosed = ProcessProbe.lidClosed() ?? false
        lidTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkLid(); self?.state.objectWillChange.send() }
        }
    }

    private func schedulePoll() {
        evalTimer?.invalidate()
        let interval: TimeInterval = state.mode == .armed ? 60 : 15
        evalTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    /// One poll cycle: discover running sessions, scan each transcript tail, mark ended ones, then
    /// evaluate the done-policy. No hooks required.
    private func poll() {
        let running = ProcessProbe.runningSessions()
        let runningIds = Set(running.map(\.id))
        // Drop sessions that have ended and are gone (already evaluated in a prior poll) so the
        // list stays bounded instead of accumulating "ended" rows.
        state.sessions.removeAll { $0.endedAt != nil && !runningIds.contains($0.id) }
        for r in running { state.merge(discovered: r.id, agent: r.agent, cwd: r.cwd, transcript: r.transcript) }
        let busy = ProcessProbe.busyCwds()   // cwds with a running tool/server (one pass)

        for i in state.sessions.indices {
            let s = state.sessions[i]
            state.sessions[i].lastSeen = ProcessProbe.mtime(s.transcript) ?? s.lastSeen
            state.sessions[i].subagentsActive = ProcessProbe.subagentActive(s.transcript, agent: s.agent)
            state.sessions[i].toolRunning = busy.contains(s.cwd)
            if state.sessions[i].summary.isEmpty {
                state.sessions[i].summary = ProcessProbe.summarize(s.transcript, agent: s.agent)
            }
            // Mark vanished sessions ended once gone from the process list and quiet a while.
            if state.sessions[i].endedAt == nil,
               !runningIds.contains(s.id),
               Date().timeIntervalSince(state.sessions[i].lastSeen) > 60 {
                state.sessions[i].endedAt = Date()
            }
        }
        evaluateDone()
        state.objectWillChange.send()
    }

    private func checkLid() {
        guard let closed = ProcessProbe.lidClosed() else { return }
        defer { lidClosed = closed }
        guard closed != lidClosed, state.mode == .armed else { return }   // act on transitions only
        // Keeping awake always means: screen off when the lid closes, screen back on when it opens.
        if closed { PowerManager.displayOff() } else { PowerManager.wakeDisplay() }
    }

    // MARK: - arming (called AFTER which/when/how is configured)

    func arm() {
        guard state.hasSelection else {
            state.lastStatus = "Pick a 'sleep when' option on a session first"
            return
        }
        let who = state.monitoredSessions.map(\.label).joined(separator: ", ")
        StateStore.save(DesiredState(mode: .armed, armedAt: Date(), reason: "monitoring \(who)"))
        guard PowerManager.arm() else {
            state.lastStatus = "Couldn't arm (permission denied)"
            return
        }
        armedAt = Date()
        state.mode = .armed
        state.lastStatus = "Armed — watching \(who)"
        startWatchdog()
        schedulePoll()   // slow to 60s while armed
    }

    func disarm(_ note: String = "Reverted to normal sleep") {
        stopWatchdog()
        armedAt = nil
        StateStore.save(DesiredState(mode: .normal, armedAt: nil, reason: note))
        _ = PowerManager.disarm()
        state.mode = .normal
        state.lastStatus = note
        schedulePoll()   // back to 15s
    }

    /// Hard reset: force normal sleep (lid closes → sleep) no matter the current state, and clear
    /// all monitoring choices. Always runs the pmset revert, even if Astopos didn't arm it — useful
    /// if pmset was left awake by a crash or another tool.
    func reset() {
        stopWatchdog()
        armedAt = nil
        state.setAll(.off)
        StateStore.save(DesiredState(mode: .normal, armedAt: nil, reason: "reset"))
        _ = PowerManager.disarm()
        state.mode = .normal
        state.lastStatus = "Reset — normal sleep restored (lid sleeps)"
        schedulePoll()
    }

    // MARK: - the done-policy evaluator (WHEN)

    private func evaluateDone() {
        guard state.mode == .armed, state.hasSelection else { return }
        let sessions = state.monitoredSessions
        guard !sessions.isEmpty else { return }   // monitor-all but nothing seen yet

        // Every monitored session must be done per ITS OWN policy. A `.never` session never is,
        // so the Mac stays awake as long as it's in the set (the server / keep-running case).
        let now = Date()
        let allDone = sessions.allSatisfy {
            DoneRule.isDone($0, policy: state.policy(for: $0.id), armedAt: armedAt, now: now)
        }
        guard allDone else { return }
        fireAction()
    }

    private func fireAction() {
        // TODO(lid-guard): sleeps even with the lid OPEN. Could add "only sleep if lid closed" later.
        // All monitored sessions met their criteria → restore normal sleep, then sleep the Mac.
        disarm("Done — all sessions finished; sleeping")
        PowerManager.sleepNow()
    }

    // MARK: - watchdog (PLAN.md §5, layer 2)

    private func startWatchdog() {
        stopWatchdog()
        guard state.watchdogMinutes > 0 else { return }
        watchdog = Timer.scheduledTimer(withTimeInterval: TimeInterval(state.watchdogMinutes * 60),
                                        repeats: false) { [weak self] _ in
            Task { @MainActor in self?.disarm("Watchdog hard-cap reached — reverted") }
        }
    }

    private func stopWatchdog() { watchdog?.invalidate(); watchdog = nil }

    // MARK: - lifecycle

    /// Called on quit / signal: best-effort revert (PLAN.md §5, layer 3).
    func shutdown() {
        if state.mode == .armed { _ = PowerManager.disarm() }
        StateStore.save(DesiredState(mode: .normal, armedAt: nil, reason: "app-quit"))
    }
}
