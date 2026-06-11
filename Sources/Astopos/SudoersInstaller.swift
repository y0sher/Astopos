import Foundation

/// Tier-2 (opt-in): install a scoped /etc/sudoers.d/astopos drop-in so the pmset toggles run
/// silently. Locked to the two exact command lines PowerManager runs — no wildcards, so nothing
/// else can ride along. Validated with `visudo -cf` before install. (PLAN.md §2.)
/// Requires one admin prompt to install/remove.
enum SudoersInstaller {
    private static let path = "/etc/sudoers.d/astopos"

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: path) }

    /// True if silent sudo actually authorizes the commands we run. `sudo -n -l <command>` checks
    /// the rule without executing anything; a drop-in left over from an older Astopos (different
    /// pmset flags) exists on disk but fails this — surfacing "stale, reinstall" in the UI instead
    /// of a password dialog popping on a closed-lid Mac later.
    static func works() -> Bool {
        sudoCanRun(arm: true) && sudoCanRun(arm: false)
    }

    static func sudoCheckArguments(arm: Bool) -> [String] {
        ["-n", "-l", "/usr/bin/pmset"] + PowerManager.pmsetArgs(arm: arm)
    }

    private static func sudoCanRun(arm: Bool) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = sudoCheckArguments(arm: arm)
        // nullDevice, not an undrained Pipe(): output nobody reads can deadlock the child.
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
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

    /// Returns true on success. Creates, validates, and installs a root-owned temp file under
    /// /etc/sudoers.d in one privileged shell, so a user-writable temp path cannot be swapped between
    /// validation and install.
    @discardableResult
    static func install() -> Bool {
        runPrivileged(installShell(user: NSUserName()))
    }

    @discardableResult
    static func remove() -> Bool { runPrivileged("/bin/rm -f \(shellQuote(path))") }

    static func installShell(user: String, id: UUID = UUID()) -> String {
        let tmp = "/etc/sudoers.d/.astopos.\(id.uuidString).tmp"
        let encoded = Data(content(user: user).utf8).base64EncodedString()
        return [
            "set -e",
            "tmp=\(shellQuote(tmp))",
            "trap '/bin/rm -f \"$tmp\"' EXIT",
            "/usr/bin/install -m 0600 -o root -g wheel /dev/null \"$tmp\"",
            "/usr/bin/printf %s \(shellQuote(encoded)) | /usr/bin/base64 -D > \"$tmp\"",
            "/usr/sbin/visudo -cf \"$tmp\"",
            "/bin/chmod 0440 \"$tmp\"",
            "/bin/mv -f \"$tmp\" \(shellQuote(path))",
            "trap - EXIT"
        ].joined(separator: "; ")
    }

    static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

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
