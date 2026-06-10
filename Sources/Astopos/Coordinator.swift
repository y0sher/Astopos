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
    private var polling = false              // a background probe pass is in flight
    private var privilegedInFlight = false   // at most one pmset/admin-dialog at a time
    private var prunedOnce = false           // stale persisted policies dropped after first scan
    private var sleptForDone = false         // one-shot: already slept for the current done-state

    init() {
        AppDelegate.coord = self   // so quit/signal paths can revert even if the panel never opened
        // Layer 1 safety: undo anything a previous run left armed.
        if let note = StateStore.reconcile() { state.lastStatus = note }
        refreshSudoStatus()

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

    func refreshSudoStatus() {
        state.silentSudoInstalled = SudoersInstaller.isInstalled
        state.silentSudoWorks = SudoersInstaller.works()
    }

    private func schedulePoll() {
        evalTimer?.invalidate()
        let interval: TimeInterval = state.mode == .armed ? 60 : 15
        state.pollIntervalSeconds = Int(interval)
        evalTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    /// What one background probe pass read for a transcript.
    private struct TranscriptScan {
        let mtime: Date?
        let subagent: Bool
        let midTurn: Bool
        let summary: String?
    }

    /// One poll cycle: discover running sessions, scan each transcript tail, mark ended ones, then
    /// evaluate the done-policy. All process spawning (pgrep/lsof can take seconds) and file
    /// reading happens off the main thread so the panel never freezes; results are applied back
    /// on the main actor.
    private func poll() {
        guard !polling else { return }
        polling = true
        let known = state.sessions.map { (transcript: $0.transcript, agent: $0.agent,
                                          needsSummary: $0.summary.isEmpty) }
        Task.detached(priority: .utility) { [weak self] in
            let running = ProcessProbe.runningSessions()
            let busy = ProcessProbe.busyState()   // children: real tools/servers + agent caffeinate
            var targets = known
            for r in running where !targets.contains(where: { $0.transcript == r.transcript }) {
                targets.append((transcript: r.transcript, agent: r.agent, needsSummary: true))
            }
            var scans: [String: TranscriptScan] = [:]
            for t in targets where scans[t.transcript] == nil {
                scans[t.transcript] = TranscriptScan(
                    mtime: ProcessProbe.mtime(t.transcript),
                    subagent: ProcessProbe.subagentActive(t.transcript, agent: t.agent),
                    midTurn: ProcessProbe.awaitingTool(t.transcript, agent: t.agent),
                    summary: t.needsSummary ? ProcessProbe.summarize(t.transcript, agent: t.agent) : nil)
            }
            let result = scans
            await MainActor.run { [weak self] in
                self?.apply(running: running, busy: busy, scans: result)
            }
        }
    }

    private func apply(running: [ProcessProbe.RunningSession],
                       busy: (busy: Set<String>, agentActive: Set<String>),
                       scans: [String: TranscriptScan]) {
        polling = false
        let runningIds = Set(running.map(\.id))
        // Drop sessions that have ended and are gone so the list stays bounded — but never a
        // monitored one while armed: a session that dies must stay in the done-evaluation set
        // (visible as "ended") instead of silently falling out and leaving the Mac armed forever.
        let dropped = state.sessions.filter {
            $0.endedAt != nil && !runningIds.contains($0.id)
                && !(state.mode == .armed && state.isMonitored($0.id))
        }.map(\.id)
        if !dropped.isEmpty {
            let gone = Set(dropped)
            state.sessions.removeAll { gone.contains($0.id) }
            for id in gone { state.policies.removeValue(forKey: id) }
        }
        for r in running { state.merge(discovered: r.id, agent: r.agent, cwd: r.cwd, transcript: r.transcript) }

        for i in state.sessions.indices {
            let s = state.sessions[i]
            guard let scan = scans[s.transcript] else { continue }
            state.sessions[i].lastSeen = scan.mtime ?? s.lastSeen
            state.sessions[i].subagentsActive = scan.subagent
            state.sessions[i].midTurn = scan.midTurn
            state.sessions[i].toolRunning = busy.busy.contains(s.cwd)
            state.sessions[i].agentBusy = busy.agentActive.contains(s.cwd)
            if s.summary.isEmpty, let sum = scan.summary, !sum.isEmpty {
                state.sessions[i].summary = sum
            }
            // Mark vanished sessions ended once gone from the process list and quiet a while.
            if state.sessions[i].endedAt == nil,
               !runningIds.contains(s.id),
               Date().timeIntervalSince(state.sessions[i].lastSeen) > 60 {
                state.sessions[i].endedAt = Date()
            }
        }
        // First scan done: drop persisted policies for sessions that no longer exist.
        if !prunedOnce { prunedOnce = true; state.prunePolicies() }

        state.lastPollAt = Date()
        // Status decay: an old message ("Couldn't arm…") must not haunt the header for hours —
        // after 10 quiet minutes in normal mode, return to the calm baseline.
        if state.mode == .normal, state.lastStatus != "Normal",
           Date().timeIntervalSince(state.lastStatusAt) > 600 {
            state.lastStatus = "Normal"
        }

        evaluateDone()
        // Keep the safety cap from firing mid-work: while any monitored session is genuinely
        // active, push the watchdog out. It only fires after a long stretch with nothing happening.
        if state.mode == .armed, state.monitoredSessions.contains(where: { $0.isWorking }) {
            startWatchdog()
        }
        state.objectWillChange.send()
    }

    private func checkLid() {
        guard let closed = ProcessProbe.lidClosed() else { return }
        defer { lidClosed = closed }
        guard closed != lidClosed, state.mode == .armed else { return }   // act on transitions only
        // Default: screen off on close, back on when it opens. If the user opted to keep the screen
        // awake, we hold a display assertion instead and don't force it off.
        if state.keepScreenAwake { return }
        if closed { PowerManager.displayOff() } else { PowerManager.wakeDisplay() }
    }

    /// Hold/release the display-awake assertion to match (armed && keepScreenAwake). Called on arm,
    /// disarm, and when the toggle changes.
    func syncDisplayAwake() {
        if state.mode == .armed && state.keepScreenAwake { PowerManager.holdDisplayAwake() }
        else { PowerManager.releaseDisplayAwake() }
    }

    /// Run one privileged pmset op off the main thread, one at a time — a hung password dialog
    /// (e.g. unattended, lid closed) must not freeze the app or stack more dialogs behind it.
    /// Returns nil if another op is already in flight.
    private func runPrivileged(_ op: @escaping @Sendable () -> Bool) async -> Bool? {
        guard !privilegedInFlight else { return nil }
        privilegedInFlight = true
        defer { privilegedInFlight = false }
        return await Task.detached { op() }.value
    }

    // MARK: - arming (called AFTER which/when/how is configured)

    func arm() {
        // Quick-pick: Arm with nothing selected monitors the most recent live session (sleep on
        // stop) — the 80% case is "watch the run I just kicked off", and a button that answers
        // beats a disabled one.
        if !state.hasSelection {
            guard let latest = state.sessions.filter({ $0.endedAt == nil })
                .max(by: { $0.lastSeen < $1.lastSeen }) else {
                state.lastStatus = "No Claude/Codex sessions detected"
                return
            }
            state.updatePolicy(latest.id) { $0.kind = .onStop }
        }
        guard !privilegedInFlight else { return }
        let who = state.monitoredSessions.map(\.label).joined(separator: ", ")
        // Written BEFORE touching pmset so a crash mid-arm still reconciles on next launch.
        StateStore.save(DesiredState(mode: .armed, armedAt: Date(), reason: "monitoring \(who)"))
        state.lastStatus = "Arming…"
        Task {
            guard await runPrivileged({ PowerManager.arm() }) == true else {
                // Didn't happen — put the persisted intent back so the next launch doesn't
                // "reconcile" an arm that never took effect.
                StateStore.save(DesiredState(mode: .normal, armedAt: nil, reason: "arm-failed"))
                state.lastStatus = "Couldn't arm (permission denied)"
                return
            }
            state.armedAt = Date()
            state.mode = .armed
            sleptForDone = false
            state.lastStatus = "Armed — watching \(who)"
            startWatchdog()
            schedulePoll()   // slow to 60s while armed
            syncDisplayAwake()
        }
    }

    @discardableResult
    func disarm(_ note: String = "Reverted to normal sleep") async -> Bool {
        // The revert needs admin rights. If it didn't actually happen (e.g. the password prompt was
        // dismissed), DON'T claim we're normal — we're still keeping the Mac awake.
        guard await runPrivileged({ PowerManager.disarm() }) == true else {
            state.lastStatus = "Revert needs your password — still awake (Stop again, or install silent mode)"
            return false
        }
        stopWatchdog()
        state.armedAt = nil
        PowerManager.releaseDisplayAwake()
        StateStore.save(DesiredState(mode: .normal, armedAt: nil, reason: note))
        state.mode = .normal
        state.lastStatus = note
        schedulePoll()   // back to 15s
        return true
    }

    /// Hard reset: force normal sleep (lid closes → sleep) no matter the current state, and clear
    /// all monitoring choices. Always runs the pmset revert, even if Astopos didn't arm it — useful
    /// if pmset was left awake by a crash or another tool.
    func reset() {
        stopWatchdog()
        state.armedAt = nil
        state.setAll(.off)
        StateStore.save(DesiredState(mode: .normal, armedAt: nil, reason: "reset"))
        PowerManager.releaseDisplayAwake()
        state.mode = .normal
        state.lastStatus = "Reset — normal sleep restored (lid sleeps)"
        schedulePoll()
        Task { _ = await runPrivileged({ PowerManager.disarm() }) }
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
            DoneRule.isDone($0, policy: state.policy(for: $0.id), armedAt: state.armedAt, now: now)
        }
        // Work resumed (a session is active again) → re-arm the one-shot so a later done-state can
        // sleep again.
        guard allDone else { sleptForDone = false; return }
        fireAction()
    }

    private func fireAction() {
        // All monitored sessions met their criteria. The headline action is to SLEEP the Mac — and
        // that's independent of restoring the keep-awake setting. `pmset sleepnow` needs no
        // privileges and sleeps the Mac whether or not `disablesleep` is still set, so we sleep
        // regardless. Restoring the setting (so the NEXT lid-close sleeps normally) is the
        // privileged part: we attempt it SILENTLY only — never a password dialog on a closed-lid
        // Mac. With Auto-restore (silent sudo) it succeeds and we're cleanly normal; without it we
        // leave the setting on (you revert later via Stop/Reset/relaunch) and the Mac still sleeps.
        // Sleep only with the lid closed (the walked-away case); lid open means you're here.
        // Unknown lid (no clamshell sensor) → treat as closed and sleep.
        let lidIsClosed = ProcessProbe.lidClosed() ?? true
        Task {
            let reverted = await runPrivileged({ PowerManager.disarmSilent() }) == true
            if reverted {
                stopWatchdog()
                state.armedAt = nil
                PowerManager.releaseDisplayAwake()
                StateStore.save(DesiredState(mode: .normal, armedAt: nil, reason: "done — restored normal sleep"))
                state.mode = .normal
                schedulePoll()
            }
            if lidIsClosed {
                guard !sleptForDone else { return }   // one-shot: don't re-sleep every poll
                sleptForDone = true
                state.lastStatus = reverted
                    ? "Done — all sessions finished; sleeping"
                    : "Done — sleeping (keep-awake still on; reopen the lid or hit Stop to restore)"
                PowerManager.sleepNow()
            } else if state.mode == .armed {
                // Lid open → you're here, so we don't sleep. We also don't pop a password dialog;
                // just say how to restore normal sleep if you want it now.
                state.lastStatus = "Done — all sessions finished. Hit Stop & revert to restore normal sleep."
            }
        }
    }

    // MARK: - watchdog (PLAN.md §5, layer 2)

    private func startWatchdog() {
        watchdog?.invalidate(); watchdog = nil; state.watchdogDeadline = nil
        guard state.watchdogMinutes > 0 else { return }
        // Don't cap sessions the user pinned to stay awake forever (the server / long-runner case).
        if state.monitoredSessions.contains(where: { state.policy(for: $0.id).kind == .never }) { return }
        scheduleWatchdog(after: TimeInterval(state.watchdogMinutes * 60))
    }

    private func scheduleWatchdog(after seconds: TimeInterval) {
        watchdog?.invalidate()
        state.watchdogDeadline = Date().addingTimeInterval(seconds)
        watchdog = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.watchdogFired() }
        }
    }

    private func watchdogFired() {
        Task {
            if !(await disarm("Watchdog hard-cap reached — reverted")) {
                // Revert didn't happen (needs a password nobody is there to type). Keep retrying
                // on a short leash instead of staying armed forever.
                scheduleWatchdog(after: 300)
            }
        }
    }

    private func stopWatchdog() {
        watchdog?.invalidate(); watchdog = nil
        state.watchdogDeadline = nil
    }

    /// Watchdog setting changed in the UI — re-apply immediately if we're armed.
    func watchdogChanged() {
        if state.mode == .armed { startWatchdog() }
    }

    // MARK: - lifecycle

    /// Called on quit / signal: best-effort synchronous revert (PLAN.md §5, layer 3) — the app is
    /// dying, an async hop would never complete.
    func shutdown() {
        if state.mode == .armed { _ = PowerManager.disarm() }
        StateStore.save(DesiredState(mode: .normal, armedAt: nil, reason: "app-quit"))
    }
}
