import Testing
import Foundation
@testable import Astopos

/// The sudoers drop-in must allowlist the EXACT command lines PowerManager executes via
/// `sudo -n` — pmset invoked directly, not through a shell — or "silent mode" silently never
/// works and a password dialog pops on a closed-lid Mac. (Regression: the rule once said
/// `pmset -b ... *` while the code ran `sudo /bin/sh -c "pmset ..."`.)
@Suite struct SudoersLockstepTests {
    @Test func ruleMatchesArmAndDisarmCommands() {
        let content = SudoersInstaller.content(user: "alice")
        let on = (["/usr/bin/pmset"] + PowerManager.pmsetArgs(arm: true)).joined(separator: " ")
        let off = (["/usr/bin/pmset"] + PowerManager.pmsetArgs(arm: false)).joined(separator: " ")
        #expect(content.contains("NOPASSWD: \(on), \(off)"))
        #expect(!content.contains("*"))          // exact commands only, no wildcards
        #expect(!content.contains("/bin/sh"))    // never authorize a shell
    }

    @Test func armCoversAllPowerProfiles() {
        // `-b` alone does nothing when plugged in; the toggles must use `-a`.
        #expect(PowerManager.pmsetArgs(arm: true) == ["-a", "disablesleep", "1"])
        #expect(PowerManager.pmsetArgs(arm: false) == ["-a", "disablesleep", "0"])
    }
}
