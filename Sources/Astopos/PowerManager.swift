import Foundation
import IOKit.pwr_mgt

/// Runs the privileged pmset toggles and the unprivileged sleep commands.
///
/// Strategy (matches PLAN.md §2):
///   1. try `sudo -n /usr/bin/pmset ...` — invoked directly (no shell wrapper) so it matches the
///      exact command line the Tier-2 sudoers drop-in allowlists and runs silently once installed
///      (or while macOS still has a cached auth)
///   2. on failure, fall back to an osascript admin-privileges dialog (Tier 1)
///
/// Sleep / display-off need no privileges at all.
enum PowerManager {

    // MARK: - privileged toggles

    /// The exact pmset arguments for arming/disarming. `-a` covers every power profile — battery
    /// AND charger; `-b` alone would silently do nothing when the Mac is plugged in. We
    /// deliberately don't touch the user's `sleep` timer: `disablesleep 1` already blocks all
    /// sleep (including clamshell), and overwriting `sleep` clobbers a setting we'd then have to
    /// restore. These must stay in lockstep with SudoersInstaller.content.
    static func pmsetArgs(arm: Bool) -> [String] { ["-a", "disablesleep", arm ? "1" : "0"] }

    /// Keep the Mac awake with the lid closed.
    @discardableResult
    static func arm() -> Bool { privileged(pmsetArgs(arm: true)) }

    /// Restore normal sleep behaviour.
    @discardableResult
    static func disarm() -> Bool { privileged(pmsetArgs(arm: false)) }

    /// Restore normal sleep WITHOUT ever prompting — silent sudo only, no osascript fallback.
    /// Used by the done-action so a closed-lid Mac never gets an unanswerable password dialog:
    /// we sleep the Mac either way, and only auto-restore the setting if it can be done silently.
    @discardableResult
    static func disarmSilent() -> Bool {
        runOK("/usr/bin/sudo", ["-n", "/usr/bin/pmset"] + pmsetArgs(arm: false))
    }

    // MARK: - unprivileged actions

    /// Sleep the whole machine immediately. `pmset sleepnow` needs no privileges and no TCC
    /// consent. The AppleScript fallback needs the Automation permission (a prompt the user can't
    /// answer with the lid closed), so it's last resort only.
    static func sleepNow() {
        if runOK("/usr/bin/pmset", ["sleepnow"]) { return }
        var err: NSDictionary?
        NSAppleScript(source: "tell application \"System Events\" to sleep")?.executeAndReturnError(&err)
    }

    /// Turn the display off immediately — no sudo needed.
    static func displayOff() {
        run("/usr/bin/pmset", ["displaysleepnow"])
    }

    // MARK: - keep display awake (optional)

    private static var displayAssertion: IOPMAssertionID = 0

    /// Hold a display-sleep-prevention assertion so the screen doesn't idle-sleep/lock (lid open).
    static func holdDisplayAwake() {
        guard displayAssertion == 0 else { return }
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                    "Astopos: keep screen awake while armed" as CFString,
                                    &displayAssertion)
    }

    static func releaseDisplayAwake() {
        if displayAssertion != 0 { IOPMAssertionRelease(displayAssertion); displayAssertion = 0 }
    }

    /// Wake the display on lid-open — no sudo, no external process. Uses the same IOKit mechanism
    /// `caffeinate -u` calls: declaring local user activity powers the display back on.
    static func wakeDisplay() {
        var id: IOPMAssertionID = 0
        let r = IOPMAssertionDeclareUserActivity(
            "Astopos: wake display on lid open" as CFString, kIOPMUserActiveLocal, &id)
        if r != kIOReturnSuccess {
            run("/usr/bin/caffeinate", ["-u", "-t", "1"])   // fallback (essentially never needed)
        }
    }

    // MARK: - introspection

    /// True if the system currently has disablesleep set. `pmset -g` reports the live state as a
    /// "SleepDisabled 1" line (it isn't part of any profile in `pmset -g custom`).
    static func isDisableSleepActive() -> Bool {
        guard let out = capture("/usr/bin/pmset", ["-g"]) else { return false }
        return out.range(of: #"SleepDisabled\s+1"#, options: .regularExpression) != nil
    }

    // MARK: - implementation

    /// Try silent sudo first, then prompt via osascript. The sudo invocation runs pmset directly:
    /// wrapping it in `sh -c` would make sudo check /bin/sh against the sudoers allowlist (which
    /// only permits pmset) and always fail.
    private static func privileged(_ args: [String]) -> Bool {
        if runOK("/usr/bin/sudo", ["-n", "/usr/bin/pmset"] + args) { return true }
        let script = "do shell script \"/usr/bin/pmset \(args.joined(separator: " "))\" with administrator privileges"
        return runOK("/usr/bin/osascript", ["-e", script])
    }

    @discardableResult
    private static func run(_ path: String, _ args: [String]) -> Bool { runOK(path, args) }

    private static func runOK(_ path: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        // nullDevice, not an undrained Pipe(): a pipe nobody reads deadlocks the child once its
        // output exceeds the 64KB buffer.
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func capture(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            // Drain before waiting — wait-then-read deadlocks once output exceeds the pipe buffer.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
