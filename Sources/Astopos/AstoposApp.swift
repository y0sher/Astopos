import SwiftUI
import AppKit

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

/// Menu-bar icon; observes state so it flips on arm/disarm.
struct MenuIcon: View {
    @ObservedObject var state: AppState
    var body: some View {
        Image(systemName: state.mode == .armed ? "bolt.fill" : "moon")
    }
}

/// Wires the coordinator into the AppKit lifecycle so we revert on quit / signals.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var coord: Coordinator?
    func applicationDidFinishLaunching(_ note: Notification) {
        for sig in [SIGINT, SIGTERM] {
            signal(sig) { _ in
                DispatchQueue.main.sync { AppDelegate.coord?.shutdown() }
                exit(0)
            }
        }
    }
    func applicationWillTerminate(_ note: Notification) { AppDelegate.coord?.shutdown() }
}

struct PanelView: View {
    let coord: Coordinator
    @ObservedObject var state: AppState
    @State private var expandedFolders: Set<String> = []
    @State private var showSetup = false

    private var monitored: [AgentSession] { state.monitoredSessions.sorted { $0.lastSeen > $1.lastSeen } }

    /// Un-monitored sessions grouped by project folder, most-recently-active folder first.
    private var otherFolders: [(cwd: String, sessions: [AgentSession])] {
        let others = state.sessions.filter { !state.isMonitored($0.id) }
        return Dictionary(grouping: others, by: { $0.cwd })
            .map { (cwd: $0.key, sessions: $0.value.sorted { $0.lastSeen > $1.lastSeen }) }
            .sorted { ($0.sessions.first?.lastSeen ?? .distantPast) > ($1.sessions.first?.lastSeen ?? .distantPast) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                header
                Divider()
                sessionsSection
                Divider()
                controlButtons
                Divider()
                setupSection
            }
            .padding(14)
            .frame(width: 340)
        }
        .frame(maxHeight: 620)
        .onAppear { AppDelegate.coord = coord }
    }

    // MARK: header
    private var header: some View {
        HStack {
            Image(systemName: state.mode == .armed ? "bolt.fill" : "moon")
                .foregroundStyle(state.mode == .armed ? .yellow : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Astopos").font(.headline)
                Text(state.lastStatus).font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
        if expanded {
            ForEach(list) { SessionRow(sess: $0, state: state) }
        }
    }

    // MARK: control buttons
    private var controlButtons: some View {
        VStack(spacing: 8) {
            if state.mode == .armed {
                Button { coord.disarm("Stopped manually") } label: {
                    Label("Stop & revert now", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).tint(.orange)
            } else {
                Button { coord.arm() } label: {
                    Label("Arm keep-awake", systemImage: "bolt.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!state.hasSelection)
                if state.hasSelection {
                    Text("Stays awake (screen off when lid shut). Sleeps once every monitored session finishes.")
                        .font(.caption2).foregroundStyle(.secondary)
                    Label("On the move? Tether to your phone's hotspot — if the network drops, a session can stall.",
                          systemImage: "wifi")
                        .font(.caption2).foregroundStyle(.orange)
                } else {
                    Text("Pick a “sleep when” for a session to enable Arm.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Sleep now") { PowerManager.sleepNow() }.frame(maxWidth: .infinity)
                Button("Reset") { coord.reset() }.frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: setup (collapsed)
    private var setupSection: some View {
        DisclosureGroup(isExpanded: $showSetup) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Tracks Claude & Codex sessions by polling their transcripts — nothing is installed into either tool.")
                    .font(.caption2).foregroundStyle(.secondary)
                HStack {
                    Text("Privileged toggles:").font(.caption).foregroundStyle(.secondary)
                    if state.silentSudoInstalled {
                        Text("silent").font(.caption).foregroundStyle(.green)
                        Button("Remove") { if SudoersInstaller.remove() { state.silentSudoInstalled = false } }.font(.caption)
                    } else {
                        Text("prompts").font(.caption)
                        Button("Make silent…") { if SudoersInstaller.install() { state.silentSudoInstalled = true } }.font(.caption)
                    }
                }
                Button("Quit Astopos") { coord.shutdown(); NSApp.terminate(nil) }.padding(.top, 2)
            }.padding(.top, 4)
        } label: {
            Text("Setup").font(.caption.bold()).foregroundStyle(.secondary)
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
                        Stepper("\(pol.idleMinutes)m", value: idleBinding, in: 1...120)
                            .font(.caption).fixedSize()
                    }
                }
                .padding(.leading, 20)   // align under the title, past the checkbox
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
    }

    private var stateText: String {
        if sess.endedAt != nil { return "ended" }
        if sess.subagentsActive { return "subagent" }
        if sess.toolRunning { return "running" }
        if sess.idleSeconds < 15 { return "working" }
        let s = sess.idleSeconds
        return s >= 60 ? "idle \(s / 60)m" : "idle \(s)s"
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
    private var idleBinding: Binding<Int> {
        Binding(get: { pol.idleMinutes }, set: { v in state.updatePolicy(sess.id) { $0.idleMinutes = v } })
    }
}
