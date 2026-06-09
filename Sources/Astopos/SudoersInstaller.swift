import Foundation

/// Tier-2 (opt-in): install a scoped /etc/sudoers.d/astopos drop-in so the pmset toggles run
/// silently. Locked to the exact binary + flags. Validated with `visudo -cf` before install.
/// (PLAN.md §2.) Requires one admin prompt to install/remove.
enum SudoersInstaller {
    private static let path = "/etc/sudoers.d/astopos"

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: path) }

    private static func content(user: String) -> String {
        """
        # Installed by Astopos. Allows ONLY the keep-awake pmset toggles, no password.
        \(user) ALL=(root) NOPASSWD: /usr/bin/pmset -b disablesleep *, /usr/bin/pmset -b sleep *
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
