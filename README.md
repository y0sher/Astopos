# Astopos

<p align="center">
  <img src="https://github.com/y0sher/Astopos/releases/latest/download/readme_image.jpg" alt="Astopos" width="320">
</p>

**Keep your Mac awake — lid closed — only for as long as your AI coding sessions actually need it, then let it sleep.**

A tiny menu-bar app for the moment your agent is mid-flight and you have to get up.

---

### Sound familiar?

- Need to head home and **Claude is still Clauding…**?
- Have to shut the lid for a meeting but **Codex is mid–huge refactor**?
- Kicked off a long run, want to walk away, but closing the lid kills it?

**Astopos.** Close the lid, the screen turns off, the work keeps going — and the moment your sessions are actually done, your Mac goes to sleep on its own.

> ⚠️ **We don't recommend leaving a running laptop in a closed bag** — lid shut with the CPU working means little airflow, and it can get hot.

---

## What it does

- **Keeps the Mac awake with the lid closed** (`pmset -a disablesleep 1` — covers battery *and* charger) so `claude` / `codex` keep running. Your sleep-timer settings are left untouched.
- **Turns the screen off when you close the lid** and **back on when you open it** — saves the display's battery while the work continues. (Automatic; not a setting.)
- **Watches your sessions** and, once **every** one you're monitoring has finished, **sleeps the Mac** (when the lid's closed — lid open means you're there, so it doesn't). Sleeping needs no password. Turning the keep-awake setting back off afterward does — that's what *Auto-restore sleep* is for (below).
- **No setup in Claude or Codex.** It figures out what's happening purely by reading their session transcripts — nothing is installed into either tool, no config, no network port.

## How it tracks sessions (no hooks, no config)

Astopos polls the transcripts both tools already write:

- Claude → `~/.claude/projects/<cwd>/<id>.jsonl`
- Codex → `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`

From those + the process list it knows each session's **project folder**, a **name** (its first prompt), and whether it's **working / idle / running a tool**. A session counts as *stopped* when it has yielded the turn and gone quiet — a tool still executing mid-turn (a long build the agent is waiting on) always keeps it "working". **Background processes the session left running (a dev server, a backgrounded build) don't block sleep by default** — tick **Wait for background processes** on that session if they should, or pin it to **Never**.

## Use it

1. Click the menu-bar icon (🌙 → ⚡️ when armed).
2. Sessions are grouped by **folder**. Open a folder, find your session by its name (ⓘ shows the full prompt), and pick when it should let the Mac sleep:
   - **On stop** — as soon as it yields a turn (finished, or asking you something).
   - **Idle N min** — sleeps once it's been quiet for N minutes. This doubles as a **remote-control window**: if you're driving the session from your phone (SSH'd in) with the lid closed, the quiet timer gives you N minutes to send the next prompt before the Mac sleeps. Send something and the window resets; don't, and it sleeps on its own — so you get a chance to keep going without burning battery if you walk away for good.
   - **Never** — keep awake until you stop it (for a server / long-runner you want to reach).
   - **Off** — don't monitor.

   Each monitored session also has a **Wait for background processes** checkbox (off by default): tick it if servers or backgrounded builds the session spawned should hold the Mac awake too.
3. Hit **Arm keep-awake** (one password prompt). Close the lid and go. In a hurry? Hit **Arm** without picking anything — it monitors your most recent session (sleep on stop) automatically.
   > Astopos sleeps the Mac when your sessions finish — no password needed. *Turning the keep-awake setting back off* afterward (so the next lid-close sleeps normally) does need admin: enable **Auto-restore sleep** once (in Advanced) to have it happen without a prompt. Skip it and the Mac still sleeps — the setting just stays on until you revert it yourself (**Stop & revert** / **Reset**).
4. When every monitored session is done, Astopos sleeps the Mac (if the lid's closed). Or hit **Stop & revert** / **Reset** anytime.

**Arming mid-flight just works** — and it's the normal case. The quiet timer counts from the later of the session's last activity and the moment you armed, so arming an already-stopped session works too: it gets the full "On stop" grace / idle window from the arm (no insta-sleep), and the Mac only force-sleeps once the lid is closed anyway.

> 📶 **On the move? Tether to your phone's hotspot before you go.** Astopos keeps the Mac running, but most agent sessions need the network — if your Wi-Fi drops (leaving the office, between buildings), the session can stall waiting on the connection. A hotspot lets you walk anywhere and keep it going.

## Build & run

Requires macOS 13+ and the Swift toolchain (Xcode or Command Line Tools).

```bash
swift build          # compile
swift run            # run from the terminal
make app             # bundle Astopos.app (menu-bar only) — then drag to /Applications
make dmg             # universal (arm64 + x86_64) ad-hoc-signed .app in a drag-to-Applications DMG
```

## Safety nets

- **Hard cap** — a watchdog (default 2h, configurable in Advanced) reverts keep-awake no matter what; if the revert can't run it retries every 5 minutes.
- **Reset** — one button forces normal sleep (lid closes → sleeps), even if something else left the Mac awake.
- **Self-healing** — reverts on quit, and reconciles on next launch if it ever crashed while armed.

## Heads-up

- **Sleeping the Mac when done needs nothing** — it sleeps regardless. The keep-awake toggle (`pmset -a disablesleep`) is the privileged bit: admin to turn **on** (the one prompt you answer when arming) and to turn **off** again. After Astopos sleeps the Mac, that setting is normally still on, so the *next* lid-close won't sleep until it's turned back off. **Auto-restore sleep** (Advanced → scoped `sudoers` entry, locked to the two exact pmset commands) does that turn-off automatically, no password. Without it the Mac still sleeps; you just restore the setting yourself afterward (**Stop & revert** / **Reset**, or it reconciles on next launch). Enabled it with an older Astopos? Advanced shows **needs update** — hit Update once.
- **Amphetamine** plays nicely alongside Astopos — they do different jobs: Amphetamine keeps the *display* awake/unlocked while you work with the lid open; Astopos keeps the *system* awake with the lid closed and sleeps it when you're done. Just leave Amphetamine's **"Allow when display is closed"** option **off** — that one fights Astopos for the lid-closed setting. Everything else can stay on.
- A dark/locked screen while armed is normal — the Mac is still awake and your sessions keep running. The password on reopen is just macOS's screen lock (tied to the display turning off), not a wake-from-sleep.
