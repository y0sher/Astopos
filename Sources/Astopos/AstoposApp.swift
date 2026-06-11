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

/// "3d 4h" / "1h 5m" / "12m" / "40s" — compact, scales past minutes ("idle 1006m" is unreadable).
func shortDuration(_ seconds: Int) -> String {
    let s = max(0, seconds)
    if s >= 86_400 { return "\(s / 86_400)d \((s % 86_400) / 3600)h" }
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
            if state.allMonitoredDone {
                // Everything finished but keep-awake is still on (lid open, or revert pending).
                Image(systemName: "bolt.badge.checkmark")
            } else {
                let working = state.monitoredSessions.filter(\.isWorking).count
                HStack(spacing: 2) {
                    Image(systemName: "bolt.fill")
                    if working > 0 { Text("\(working)") }
                }
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

/// Reports the natural height of the session list so the scroll area can size to content.
private struct SessionsHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct PanelView: View {
    let coord: Coordinator
    @ObservedObject var state: AppState
    @State private var expandedFolders: Set<String> = []
    @State private var showAdvanced = false
    @State private var confirmReset = false
    @State private var launchAtLogin = false
    @State private var sessionsHeight: CGFloat = 0
    @State private var showAutoRestoreHelp = false

    private var monitored: [AgentSession] { state.monitoredSessions.sorted { $0.lastSeen > $1.lastSeen } }

    /// Agent badges are pure noise when only one tool is in use — show them only when both are.
    private var multiAgent: Bool { Set(state.sessions.map(\.agent)).count > 1 }

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
            // The session list is the panel's most important area: it gets its full natural
            // height (measured via preference) and only becomes scrollable past the cap.
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    sessionsSection
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(GeometryReader { g in
                    Color.clear.preference(key: SessionsHeightKey.self, value: g.size.height)
                })
            }
            .onPreferenceChange(SessionsHeightKey.self) { sessionsHeight = $0 }
            .frame(height: min(max(sessionsHeight, 44), 380))
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                controlButtons
                Divider()
                advancedSection
                Divider()
                HStack {
                    Button("Quit Astopos") { coord.requestQuit() }
                    Spacer()
                    if let polled = state.lastPollAt {
                        // The element that tells you it's stale is also the cure: click to re-scan.
                        Button { coord.refreshNow() } label: {
                            // The label is only visible while the panel is open — when the cadence
                            // IS 15s. Say so, or it reads as the permanent background rate.
                            Text("checked \(shortDuration(Int(Date().timeIntervalSince(polled)))) ago · 15s while open")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help("Click to re-scan now. Battery-light when closed: every 60s while armed, 120s otherwise.")
                        .accessibilityLabel("Refresh sessions now")
                    }
                }
            }
            .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 14)
        }
        .frame(width: 340)
        .onAppear {
            AppDelegate.coord = coord
            coord.panelDidAppear()
            coord.refreshSudoStatus()
            launchAtLogin = Bundle.main.bundleIdentifier != nil && SMAppService.mainApp.status == .enabled
        }
        .onDisappear { coord.panelDidDisappear() }
    }

    /// Status message with an age suffix once it's no longer fresh — "Couldn't arm (permission
    /// denied) · 2h ago" reads as history; without the suffix it reads as a live problem.
    private var agedStatus: String {
        let age = Int(Date().timeIntervalSince(state.lastStatusAt))
        guard state.lastStatus != "Normal", age > 120 else { return state.lastStatus }
        return "\(state.lastStatus) · \(shortDuration(age)) ago"
    }

    /// One consolidated headline while armed (live summary), instead of the static "Armed —
    /// monitoring x, y, z" wall. Transient messages (errors, done-notes) still win.
    private var headerStatus: String {
        if state.mode == .armed, state.lastStatus.hasPrefix("Armed") {
            if state.allMonitoredDone { return "All sessions done — sleeps once the lid is closed" }
            let m = state.monitoredSessions
            let working = m.filter(\.isWorking).count
            return "Monitoring \(m.count) session\(m.count == 1 ? "" : "s") · \(working) working · sleeps when all finish"
        }
        return agedStatus
    }

    // MARK: header
    private var header: some View {
        HStack {
            Image(systemName: state.mode == .armed ? "bolt.fill" : "moon")
                .foregroundStyle(state.mode == .armed ? .yellow : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Astopos").font(.headline)
                Text(headerStatus).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .help(headerStatus)
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
                Text("Monitored · \(monitored.count)").font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
                if !monitored.isEmpty { Button("Clear") { state.setAll(.off) }.font(.caption) }
            }
            if monitored.isEmpty {
                Text(state.sessions.isEmpty ? "No Claude/Codex sessions detected"
                                            : "Nothing monitored yet — open a folder below to pick a session")
                    .font(.caption).foregroundStyle(.secondary)
            }
            // Monitored rows live outside their folder, so they keep the folder in the subtitle.
            ForEach(monitored) { SessionRow(sess: $0, state: state, showFolder: true, showBadge: multiAgent) }

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
                if multiAgent {
                    if agents.contains(.claude) { AgentBadge(agent: .claude) }
                    if agents.contains(.codex) { AgentBadge(agent: .codex) }
                }
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
            // Inside their own folder group, repeating the folder name per row is pure noise.
            ForEach(list) { SessionRow(sess: $0, state: state, showFolder: false, showBadge: multiAgent) }
        }
    }

    // MARK: control buttons
    private var controlButtons: some View {
        VStack(spacing: 8) {
            if state.mode == .armed {
                Button { coord.stopAndRevert() } label: {
                    Label("Stop & revert now", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).tint(.orange)
            } else {
                Button { coord.arm() } label: {
                    Label("Arm keep-awake", systemImage: "bolt.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Text(state.hasSelection
                     ? "Stays awake (screen off when lid shut). Sleeps once every monitored session finishes. One password prompt."
                     : "Nothing picked — Arm monitors your most recent session (sleeps when it stops). One password prompt.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Network reminder — pre-arm only: tethering is actionable BEFORE you leave; once
            // armed it's too late to act on and just trains banner-blindness.
            if state.mode == .normal && state.hasSelection {
                Label("On the move? Tether to your phone's hotspot — if the network drops, a session can stall.",
                      systemImage: "wifi")
                    .font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
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
                    Button { showAutoRestoreHelp.toggle() } label: {
                        Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("What does auto-restore sleep do?")
                    .popover(isPresented: $showAutoRestoreHelp, arrowEdge: .trailing) {
                        Text("The Mac sleeps when your sessions finish either way. Auto-restore also turns the keep-awake setting back off without a password, so the next time you close the lid it sleeps normally. Without it the Mac still sleeps — the setting just stays on until you hit Stop & revert or Reset.\n\nEnabling installs a scoped sudoers rule, locked to the two exact pmset commands (one admin prompt).")
                            .font(.caption)
                            .padding(12)
                            .frame(width: 280)
                    }
                }
                Text("Turns keep-awake back off afterward, no password needed.")
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

/// Small colored tag distinguishing claude vs codex sessions. Text is adaptive primary — the
/// color lives in the capsule tint; tone-on-tone (orange on orange) was unreadable on popover
/// material.
struct AgentBadge: View {
    let agent: ProcessProbe.Agent
    var body: some View {
        Text(agent == .claude ? "claude" : "codex")
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background((agent == .claude ? Color.orange : Color.teal).opacity(0.3))
            .foregroundStyle(.primary)
            .clipShape(Capsule())
    }
}

/// One compact session row: status dot, live activity, trigger picker, per-session guard.
/// `showFolder` / `showBadge` keep subtitles deduplicated by context (no folder name inside its
/// own group; no agent badge when only one tool is in use).
struct SessionRow: View {
    let sess: AgentSession
    @ObservedObject var state: AppState
    var showFolder: Bool = true
    var showBadge: Bool = true
    @State private var showInfo = false
    private var pol: SessionPolicy { state.policy(for: sess.id) }
    private var monitored: Bool { pol.isMonitored }

    /// Recognition over recall: state as color, text reserved for detail.
    /// Green = working · gray = idle · blue = met its trigger · faded = ended.
    private var dotColor: Color {
        if sess.endedAt != nil { return .gray.opacity(0.4) }
        if doneNow { return .blue }
        return sess.isWorking ? .green : .gray
    }
    private var doneNow: Bool {
        state.mode == .armed && monitored
            && DoneRule.isDone(sess, policy: pol, armedAt: state.armedAt, now: Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Toggle("", isOn: monitorBinding).toggleStyle(.checkbox).labelsHidden()
                    .accessibilityLabel("Monitor \(sess.label)")
                Circle().fill(dotColor).frame(width: 7, height: 7)
                    .accessibilityLabel("Status: \(stateText)")
                if showBadge { AgentBadge(agent: sess.agent) }
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
                                Spacer()
                                Text("active \(sess.lastSeen.formatted(date: .omitted, time: .shortened))")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Text(sess.summary).font(.callout).textSelection(.enabled)
                            Text(sess.cwd).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                            // Definitive identification: /status inside a claude terminal prints
                            // its session id — match it against this.
                            Text(sess.id).font(.caption2.monospaced()).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Text("Which terminal is this? Run /status in it — the session id must match.")
                                .font(.caption2).foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
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
                        // Styled as a VALUE control (stroked, with chevron) — a filled capsule
                        // here reads as a second selected pill in the radio group.
                        Menu {
                            ForEach([1, 2, 5, 10, 15, 30, 60, 120], id: \.self) { m in
                                Button("\(m) min") { state.updatePolicy(sess.id) { $0.idleMinutes = m } }
                            }
                        } label: {
                            HStack(spacing: 3) {
                                Text("\(pol.idleMinutes)m")
                                Image(systemName: "chevron.up.chevron.down").font(.system(size: 7))
                            }
                            .font(.caption)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1))
                        }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .menuIndicator(.hidden)
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
        .background(monitored ? Color.green.opacity(0.12) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7)
            .strokeBorder(Color.green.opacity(monitored ? 0.35 : 0), lineWidth: 1))
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
        var idle = "idle \(shortDuration(sess.idleSeconds))"
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

    // Folder shown only where the row lacks folder context (the Monitored section) and the title
    // is a prompt summary (else it'd repeat the title).
    private var subtitle: String {
        (showFolder && !sess.summary.isEmpty) ? "\(sess.folderName) · \(stateText)" : stateText
    }

    // Checkbox: on → monitor (default to Idle if it was Off), off → don't monitor.
    private var monitorBinding: Binding<Bool> {
        Binding(get: { pol.kind != .off },
                set: { on in state.updatePolicy(sess.id) { $0.kind = on ? ($0.kind == .off ? .idle : $0.kind) : .off } })
    }
}
