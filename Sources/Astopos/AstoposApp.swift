import SwiftUI
import AppKit
import ServiceManagement

struct AstoposApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var coord = Coordinator()

    var body: some Scene {
        MenuBarExtra {
            PanelView(coord: coord, state: coord.state)
        } label: {
            MenuIcon(state: coord.state)
        }
        .menuBarExtraStyle(.window)   // real SwiftUI panel — reliable toggles / pickers / enable-state
    }
}

/// "1h 5m" / "12m" / "40s" for compact countdowns.
func shortDuration(_ seconds: Int) -> String {
    let s = max(0, seconds)
    if s >= 3600 { return "\(s / 3600)h \((s % 3600) / 60)m" }
    if s >= 60 { return "\(s / 60)m" }
    return "\(s)s"
}

/// Menu-bar icon; observes state so it flips on arm/disarm. While armed it also shows how many
/// monitored sessions are still working — a glance answers "how many left" without opening it.
struct MenuIcon: View {
    @ObservedObject var state: AppState
    var body: some View {
        if state.mode == .armed {
            let working = state.monitoredSessions.filter(\.isWorking).count
            HStack(spacing: 2) {
                Image(systemName: "bolt.fill")
                if working > 0 { Text("\(working)") }
            }
        } else {
            Image(systemName: "moon")
        }
    }
}

/// Wires the coordinator into the AppKit lifecycle so we revert on quit / signals.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var coord: Coordinator?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ note: Notification) {
        // DispatchSourceSignal, not a signal() handler: a handler that touches GCD isn't
        // async-signal-safe, and dispatching sync to main deadlocks when the signal is delivered
        // on the main thread (the usual case for Ctrl-C).
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler {
                AppDelegate.coord?.shutdown()
                exit(0)
            }
            src.resume()
            signalSources.append(src)
        }
    }
    func applicationWillTerminate(_ note: Notification) { AppDelegate.coord?.shutdown() }
}

struct PanelView: View {
    let coord: Coordinator
    @ObservedObject var state: AppState
    @State private var expandedFolders: Set<String> = []
    @State private var showAdvanced = false
    @State private var confirmReset = false
    @State private var launchAtLogin = false

    private var monitored: [AgentSession] { state.monitoredSessions.sorted { $0.lastSeen > $1.lastSeen } }

    /// Un-monitored sessions grouped by project folder, most-recently-active folder first.
    private var otherFolders: [(cwd: String, sessions: [AgentSession])] {
        let others = state.sessions.filter { !state.isMonitored($0.id) }
        return Dictionary(grouping: others, by: { $0.cwd })
            .map { (cwd: $0.key, sessions: $0.value.sorted { $0.lastSeen > $1.lastSeen }) }
            .sorted { ($0.sessions.first?.lastSeen ?? .distantPast) > ($1.sessions.first?.lastSeen ?? .distantPast) }
    }

    var body: some View {
        // Pinned layout: the header (state) and controls (the CTA) never scroll away — only the
        // session list scrolls. With a couple of folders expanded the Arm button used to slide
        // below the fold.
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                header
                if state.mode == .armed {
                    VStack(alignment: .leading, spacing: 3) {
                        Label("A dark screen is normal — the Mac is awake and your sessions keep running.",
                              systemImage: "bolt.fill")
                            .font(.caption2).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        if let deadline = state.watchdogDeadline {
                            Text("Hard cap: reverts in \(shortDuration(Int(deadline.timeIntervalSinceNow))) if nothing is active.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    sessionsSection
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
            .frame(maxHeight: 330)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                controlButtons
                Divider()
                advancedSection
                Divider()
                HStack {
                    Button("Quit Astopos") { coord.shutdown(); NSApp.terminate(nil) }
                    Spacer()
                    if let polled = state.lastPollAt {
                        Text("checked \(shortDuration(Int(Date().timeIntervalSince(polled)))) ago · every \(state.pollIntervalSeconds)s")
                            .font(.caption2).foregroundStyle(.tertiary)
                            .help("Astopos re-scans sessions on this cadence; the lid watcher ticks every 3s")
                    }
                }
            }
            .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 14)
        }
        .frame(width: 340)
        .onAppear {
            AppDelegate.coord = coord
            coord.refreshSudoStatus()
            launchAtLogin = Bundle.main.bundleIdentifier != nil && SMAppService.mainApp.status == .enabled
        }
    }

    /// Status message with an age suffix once it's no longer fresh — "Couldn't arm (permission
    /// denied) · 2h ago" reads as history; without the suffix it reads as a live problem.
    private var agedStatus: String {
        let age = Int(Date().timeIntervalSince(state.lastStatusAt))
        guard state.lastStatus != "Normal", age > 120 else { return state.lastStatus }
        return "\(state.lastStatus) · \(shortDuration(age)) ago"
    }

    // MARK: header
    private var header: some View {
        HStack {
            Image(systemName: state.mode == .armed ? "bolt.fill" : "moon")
                .foregroundStyle(state.mode == .armed ? .yellow : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Astopos").font(.headline)
                Text(agedStatus).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .help(agedStatus)
            }
            Spacer()
            Text(state.mode == .armed ? "AWAKE" : "NORMAL")
                .font(.caption2.bold())
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(state.mode == .armed ? Color.yellow.opacity(0.25) : Color.secondary.opacity(0.15))
                .clipShape(Capsule())
        }
    }

    // MARK: sessions — monitored always visible; the rest grouped into big per-folder buttons.
    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("MONITORED · \(monitored.count)").font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
                if !monitored.isEmpty { Button("Clear") { state.setAll(.off) }.font(.caption) }
            }
            if monitored.isEmpty {
                Text(state.sessions.isEmpty ? "No Claude/Codex sessions detected"
                                            : "Nothing monitored yet — open a folder below to pick a session")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(monitored) { SessionRow(sess: $0, state: state) }

            ForEach(otherFolders, id: \.cwd) { folderGroup($0.cwd, $0.sessions) }
        }
    }

    /// A big, full-width tappable folder header expanding its sessions.
    @ViewBuilder
    private func folderGroup(_ cwd: String, _ list: [AgentSession]) -> some View {
        let leaf = (cwd as NSString).lastPathComponent
        let expanded = expandedFolders.contains(cwd)
        let agents = Set(list.map(\.agent))
        Button {
            if expanded { expandedFolders.remove(cwd) } else { expandedFolders.insert(cwd) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill").foregroundStyle(.secondary)
                Text(leaf.isEmpty ? cwd : leaf).fontWeight(.medium).lineLimit(1)
                Text("· \(list.count)").foregroundStyle(.secondary)
                if agents.contains(.claude) { AgentBadge(agent: .claude) }
                if agents.contains(.codex) { AgentBadge(agent: .codex) }
                Spacer()
                Image(systemName: expanded ? "chevron.down" : "chevron.right").foregroundStyle(.secondary)
            }
            .padding(.vertical, 9).padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(leaf.isEmpty ? cwd : leaf), \(list.count) sessions, \(expanded ? "expanded" : "collapsed")")
        if expanded {
            ForEach(list) { SessionRow(sess: $0, state: state) }
        }
    }

    // MARK: control buttons
    private var controlButtons: some View {
        VStack(spacing: 8) {
            if state.mode == .armed {
                Button { Task { await coord.disarm("Stopped manually") } } label: {
                    Label("Stop & revert now", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).tint(.orange)
            } else {
                Button { coord.arm() } label: {
                    Label("Arm keep-awake", systemImage: "bolt.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Text(state.hasSelection
                     ? "Stays awake (screen off when lid shut). Sleeps once every monitored session finishes."
                     : "Nothing picked — Arm monitors your most recent session (sleeps when it stops).")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            // Network reminder — shown while armed (when it matters most) and pre-arm once a
            // session is picked.
            if state.mode == .armed || state.hasSelection {
                Label("On the move? Tether to your phone's hotspot — if the network drops, a session can stall.",
                      systemImage: "wifi")
                    .font(.caption2).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Toggle("Keep screen on while armed (no auto-lock)", isOn: Binding(
                get: { state.keepScreenAwake },
                set: { state.keepScreenAwake = $0; coord.syncDisplayAwake() }))
                .toggleStyle(.checkbox).font(.caption2)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Button("Sleep now") { PowerManager.sleepNow() }.frame(maxWidth: .infinity)
                    .help("Put the Mac to sleep immediately (does not change any settings)")
                Button {
                    if confirmReset {
                        confirmReset = false
                        coord.reset()
                    } else {
                        confirmReset = true
                        Task { try? await Task.sleep(for: .seconds(3)); confirmReset = false }
                    }
                } label: {
                    Text(confirmReset ? "Really reset?" : "Reset").frame(maxWidth: .infinity)
                }
                .tint(confirmReset ? .red : nil)
                .help("Force normal sleep and clear every monitoring choice")
            }
        }
    }

    // MARK: advanced (collapsed)
    private var advancedSection: some View {
        DisclosureGroup(isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Tracks Claude & Codex sessions by polling their transcripts — nothing is installed into either tool.")
                    .font(.caption2).foregroundStyle(.secondary)
                HStack {
                    Text("Auto-restore sleep:").font(.caption).foregroundStyle(.secondary)
                    if state.silentSudoWorks {
                        Text("on").font(.caption).foregroundStyle(.green)
                        Button("Turn off") {
                            if SudoersInstaller.remove() { coord.refreshSudoStatus() }
                        }.font(.caption)
                    } else if state.silentSudoInstalled {
                        Text("needs update").font(.caption).foregroundStyle(.orange)
                        Button("Update…") {
                            if SudoersInstaller.install() { coord.refreshSudoStatus() }
                        }.font(.caption)
                    } else {
                        Text("off").font(.caption).foregroundStyle(.secondary)
                        Button("Enable…") {
                            if SudoersInstaller.install() { coord.refreshSudoStatus() }
                        }.font(.caption)
                    }
                }
                Text("The Mac sleeps when your sessions finish either way. This also turns the keep-awake setting back off without a password, so the next time you close the lid it sleeps normally. Without it the Mac still sleeps, but the setting stays on until you hit Stop/Reset. Installs a scoped sudoers rule, locked to the two pmset commands (one admin prompt).")
                    .font(.caption2).foregroundStyle(.secondary)
                HStack {
                    Text("Hard cap:").font(.caption).foregroundStyle(.secondary)
                    Picker("Hard cap", selection: Binding(
                        get: { state.watchdogMinutes },
                        set: { state.watchdogMinutes = $0; coord.watchdogChanged() })) {
                        Text("Off").tag(0)
                        Text("30 min").tag(30)
                        Text("1 h").tag(60)
                        Text("2 h").tag(120)
                        Text("4 h").tag(240)
                        Text("8 h").tag(480)
                    }
                    .labelsHidden().fixedSize()
                }
                Text("Safety net: while armed, reverts to normal sleep after this long with nothing active.")
                    .font(.caption2).foregroundStyle(.secondary)
                if Bundle.main.bundleIdentifier != nil {
                    Toggle("Launch at login", isOn: Binding(
                        get: { launchAtLogin },
                        set: { on in
                            do {
                                if on { try SMAppService.mainApp.register() }
                                else { try SMAppService.mainApp.unregister() }
                                launchAtLogin = on
                            } catch {
                                state.lastStatus = "Launch-at-login change failed: \(error.localizedDescription)"
                            }
                        }))
                        .toggleStyle(.checkbox).font(.caption)
                }
            }.padding(.top, 4)
        } label: {
            Text("Advanced").font(.caption.bold()).foregroundStyle(.secondary)
        }
    }
}

/// Small colored tag distinguishing claude vs codex sessions.
struct AgentBadge: View {
    let agent: ProcessProbe.Agent
    var body: some View {
        Text(agent == .claude ? "claude" : "codex")
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background((agent == .claude ? Color.orange : Color.teal).opacity(0.22))
            .foregroundStyle(agent == .claude ? Color.orange : Color.teal)
            .clipShape(Capsule())
    }
}

/// One compact session row: agent badge, status dot, live activity, trigger picker, per-session guard.
struct SessionRow: View {
    let sess: AgentSession
    @ObservedObject var state: AppState
    @State private var showInfo = false
    private var pol: SessionPolicy { state.policy(for: sess.id) }
    private var monitored: Bool { pol.isMonitored }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Toggle("", isOn: monitorBinding).toggleStyle(.checkbox).labelsHidden()
                    .accessibilityLabel("Monitor \(sess.label)")
                AgentBadge(agent: sess.agent)
                VStack(alignment: .leading, spacing: 0) {
                    Text(sess.label).fontWeight(.medium).lineLimit(1)
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                .help(sess.summary)   // hover shows full prompt
                if !sess.summary.isEmpty {
                    Button { showInfo.toggle() } label: {
                        Image(systemName: "info.circle").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Show full prompt")
                    .popover(isPresented: $showInfo, arrowEdge: .leading) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                AgentBadge(agent: sess.agent)
                                Text(sess.folderName).font(.caption.bold())
                            }
                            Text(sess.summary).font(.callout).textSelection(.enabled)
                            Text(sess.cwd).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        .padding(12).frame(width: 300)
                    }
                }
                Spacer()
            }
            if monitored {
                HStack(spacing: 6) {
                    pill("On stop", .onStop)
                    pill("Idle", .idle)
                    pill("Never", .never)
                    if pol.kind == .idle {
                        Menu {
                            ForEach([1, 2, 5, 10, 15, 30, 60, 120], id: \.self) { m in
                                Button("\(m) min") { state.updatePolicy(sess.id) { $0.idleMinutes = m } }
                            }
                        } label: {
                            Text("\(pol.idleMinutes)m").font(.caption)
                        }
                        .fixedSize()
                        .accessibilityLabel("Idle minutes, currently \(pol.idleMinutes)")
                    }
                }
                .padding(.leading, 20)   // align under the title, past the checkbox
                if pol.kind != .never {
                    Toggle("Wait for background processes (servers) too", isOn: Binding(
                        get: { pol.waitForChildren },
                        set: { on in state.updatePolicy(sess.id) { $0.waitForChildren = on } }))
                        .toggleStyle(.checkbox).font(.caption2).foregroundStyle(.secondary)
                        .padding(.leading, 20)
                }
            }
        }
        .padding(7)
        .background(monitored ? Color.green.opacity(0.08) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    /// A capsule "radio" pill; the selected trigger is filled with the accent color.
    private func pill(_ title: String, _ kind: SessionPolicy.Kind) -> some View {
        let on = pol.kind == kind
        return Button { state.updatePolicy(sess.id) { $0.kind = kind } } label: {
            Text(title)
                .font(.caption).fontWeight(on ? .semibold : .regular)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(on ? Color.accentColor : Color.secondary.opacity(0.15))
                .foregroundStyle(on ? Color.white : Color.primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sleep trigger: \(kind.label)")
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    private var stateText: String {
        if sess.endedAt != nil { return "ended" }
        if sess.subagentsActive { return "subagent" }
        if sess.midTurn { return "running a tool" }
        if sess.agentBusy { return "working" }   // generating (claude holds its keep-awake)
        if monitored, pol.waitForChildren, sess.toolRunning { return "background process running" }
        if sess.idleSeconds < 15 { return "working" }
        let s = sess.idleSeconds
        var idle = s >= 60 ? "idle \(s / 60)m" : "idle \(s)s"
        if sess.toolRunning { idle += " · bg running" }   // informational: not blocking sleep
        if let extra = countdown { return "\(idle) · \(extra)" }
        return idle
    }

    /// While armed: how close this idle session is to meeting its own trigger. The quiet window
    /// counts from the later of last activity and the arm (mirrors DoneRule).
    private var countdown: String? {
        guard state.mode == .armed, monitored, sess.endedAt == nil else { return nil }
        if pol.kind == .never { return "pinned awake" }
        guard let quiet = pol.quietSeconds, let armed = state.armedAt else { return nil }
        let reference = max(sess.lastSeen, armed)
        let remain = quiet - max(0, Int(Date().timeIntervalSince(reference)))
        return remain > 0 ? "done in \(shortDuration(remain))" : "done ✓"
    }

    // Show the folder for context only when the title is a prompt summary (else it'd repeat).
    private var subtitle: String {
        sess.summary.isEmpty ? stateText : "\(sess.folderName) · \(stateText)"
    }

    // Checkbox: on → monitor (default to Idle if it was Off), off → don't monitor.
    private var monitorBinding: Binding<Bool> {
        Binding(get: { pol.kind != .off },
                set: { on in state.updatePolicy(sess.id) { $0.kind = on ? ($0.kind == .off ? .idle : $0.kind) : .off } })
    }
}
