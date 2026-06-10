import Foundation

/// Tier-2 (opt-in): install a scoped /etc/sudoers.d/astopos drop-in so the pmset toggles run
/// silently. Locked to the two exact command lines PowerManager runs — no wildcards, so nothing
/// else can ride along. Validated with `visudo -cf` before install. (PLAN.md §2.)
/// Requires one admin prompt to install/remove.
enum SudoersInstaller {
    private static let path = "/etc/sudoers.d/astopos"

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: path) }

    /// True if silent sudo actually authorizes the command we run. `sudo -n -l <command>` checks
    /// the rule without executing anything; a drop-in left over from an older Astopos (different
    /// pmset flags) exists on disk but fails this — surfacing "stale, reinstall" in the UI instead
    /// of a password dialog popping on a closed-lid Mac later.
    static func works() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", "-l", "/usr/bin/pmset"] + PowerManager.pmsetArgs(arm: true)
        p.standardOutput = Pipe(); p.standardError = Pipe()
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 }
        catch { return false }
    }

    static func content(user: String) -> String {
        let on = (["/usr/bin/pmset"] + PowerManager.pmsetArgs(arm: true)).joined(separator: " ")
        let off = (["/usr/bin/pmset"] + PowerManager.pmsetArgs(arm: false)).joined(separator: " ")
        return """
        # Installed by Astopos. Allows ONLY the exact keep-awake pmset toggles, no password.
        \(user) ALL=(root) NOPASSWD: \(on), \(off)
        """
    }

    /// Returns true on success. Writes to a temp file, validates with visudo, then installs — all
    /// inside one privileged osascript invocation so the user authenticates once.
    @discardableResult
    static func install() -> Bool {
        let user = NSUserName()
        let tmp = NSTemporaryDirectory() + "astopos.sudoers"
        try? content(user: user).write(toFile: tmp, atomically: true, encoding: .utf8)
        let shell = """
        /usr/sbin/visudo -cf '\(tmp)' && \
        /usr/bin/install -m 0440 -o root -g wheel '\(tmp)' '\(path)' && \
        /bin/rm -f '\(tmp)'
        """
        return runPrivileged(shell)
    }

    @discardableResult
    static func remove() -> Bool { runPrivileged("/bin/rm -f '\(path)'") }

    private static func runPrivileged(_ shell: String) -> Bool {
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\")
                           .replacingOccurrences(of: "\"", with: "\\\"")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "do shell script \"\(escaped)\" with administrator privileges"]
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 }
        catch { return false }
    }
}
