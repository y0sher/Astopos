import Foundation
import IOKit.pwr_mgt

/// Runs the privileged pmset toggles and the unprivileged sleep commands.
///
/// Strategy (matches PLAN.md §2):
///   1. try `sudo -n pmset ...`  (silent — works once the Tier-2 sudoers file is installed,
///      or while macOS still has a cached auth)
///   2. on failure, fall back to an osascript admin-privileges dialog (Tier 1)
///
/// Sleep / display-off need no privileges at all.
enum PowerManager {

    // MARK: - privileged toggles

    /// Keep the Mac awake with the lid closed (battery profile, per the user's commands).
    @discardableResult
    static func arm() -> Bool {
        privileged("/usr/bin/pmset -b disablesleep 1; /usr/bin/pmset -b sleep 0")
    }

    /// Restore normal sleep behaviour.
    @discardableResult
    static func disarm() -> Bool {
        privileged("/usr/bin/pmset -b disablesleep 0; /usr/bin/pmset -b sleep 5")
    }

    // MARK: - unprivileged actions

    /// Sleep the whole machine immediately — no sudo needed. Sends the Apple Event in-process
    /// (no `osascript` spawn). This is the no-root path; IOPMSleepSystem would require root.
    static func sleepNow() {
        var err: NSDictionary?
        NSAppleScript(source: "tell application \"System Events\" to sleep")?.executeAndReturnError(&err)
        if err != nil {
            run("/usr/bin/osascript", ["-e", "tell application \"System Events\" to sleep"])
        }
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

    /// True if the system currently has disablesleep set (battery profile).
    static func isDisableSleepActive() -> Bool {
        guard let out = capture("/usr/bin/pmset", ["-g", "custom"]) else { return false }
        // crude but sufficient: look at the Battery Power block for "sleep 0"/"disablesleep"
        return out.contains("disablesleep 1") || out.range(of: #"\n sleep\s+0"#, options: .regularExpression) != nil
    }

    // MARK: - implementation

    /// Try silent sudo first, then prompt via osascript.
    private static func privileged(_ shell: String) -> Bool {
        if runOK("/usr/bin/sudo", ["-n", "/bin/sh", "-c", shell]) { return true }
        // Fallback: native admin dialog. Escape double quotes for AppleScript string.
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\")
                           .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        return runOK("/usr/bin/osascript", ["-e", script])
    }

    @discardableResult
    private static func run(_ path: String, _ args: [String]) -> Bool { runOK(path, args) }

    private static func runOK(_ path: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
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
        do {
            try p.run()
            p.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
