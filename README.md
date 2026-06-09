# Astopos

**Keep your Mac awake — lid closed — only for as long as your AI coding sessions actually need it, then let it sleep.**

A tiny menu-bar app for the moment your agent is mid-flight and you have to get up.

---

### Sound familiar?

- Need to head home and **Claude is still Clauding…**?
- Have to shut the lid for a meeting but **Codex is mid–huge refactor**?
- Kicked off a long run, want to walk away, but closing the lid kills it?

**Astopos.** Close the lid, the screen turns off, the work keeps going — and the moment your sessions are actually done, your Mac goes to sleep on its own.

> ⚠️ **Please don't put a running laptop in a closed bag.** With the lid shut and the CPU working, there's no airflow — it can get hot. Astopos is for a laptop sitting on a desk/table with the lid closed, not stuffed in a backpack. Use common sense; we don't recommend leaving it running unattended in an enclosed space.

---

## What it does

- **Keeps the Mac awake with the lid closed** (`pmset disablesleep`) so `claude` / `codex` keep running.
- **Turns the screen off when you close the lid** and **back on when you open it** — saves the display's battery while the work continues. (Automatic; not a setting.)
- **Watches your sessions** and, once **every** one you're monitoring has finished, **restores normal sleep and sleeps the Mac**.
- **No setup in Claude or Codex.** It figures out what's happening purely by reading their session transcripts — nothing is installed into either tool, no config, no network port.

## How it tracks sessions (no hooks, no config)

Astopos polls the transcripts both tools already write:

- Claude → `~/.claude/projects/<cwd>/<id>.jsonl`
- Codex → `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`

From those + the process list it knows each session's **project folder**, a **name** (its first prompt), and whether it's **working / idle / running a tool**. A session counts as *idle* only when it's quiet **and** nothing is executing (no running tool, no subagent) — so "waiting on your question" reads as idle, but a running build keeps it awake.

## Use it

1. Click the menu-bar icon (🌙 → ⚡️ when armed).
2. Sessions are grouped by **folder**. Open a folder, find your session by its name (ⓘ shows the full prompt), and pick when it should let the Mac sleep:
   - **On stop** — as soon as it yields a turn (finished, or asking you something).
   - **Idle N min** — after it's been quiet for N minutes.
   - **Never** — keep awake until you stop it (for a server / long-runner you want to reach).
   - **Off** — don't monitor.
3. Hit **Arm keep-awake** (one password prompt). Close the lid and go.
4. When every monitored session is done, Astopos reverts sleep and sleeps the Mac. Or hit **Stop & revert** / **Reset** anytime.

Only work that happens **after** you arm counts — arming a session that's already idle won't sleep immediately.

> 📶 **On the move? Tether to your phone's hotspot before you go.** Astopos keeps the Mac running, but most agent sessions need the network — if your Wi-Fi drops (leaving the office, between buildings), the session can stall waiting on the connection. A hotspot lets you walk anywhere and keep it going.

## Build & run

Requires macOS 13+ and the Swift toolchain (Xcode or Command Line Tools).

```bash
swift build          # compile
swift run            # run from the terminal
make app             # bundle Astopos.app (menu-bar only) — then drag to /Applications
```

## Safety nets

- **Watchdog** — a hard cap (default 2h) reverts keep-awake no matter what.
- **Reset** — one button forces normal sleep (lid closes → sleeps), even if something else left the Mac awake.
- **Self-healing** — reverts on quit, and reconciles on next launch if it ever crashed while armed.

## Heads-up

- The privileged toggle (`pmset disablesleep`) needs an admin password each arm/revert. Install **silent mode** (Setup → scoped `sudoers` entry) for hands-off, prompt-free operation.
- **Amphetamine** plays nicely alongside Astopos — they do different jobs: Amphetamine keeps the *display* awake/unlocked while you work with the lid open; Astopos keeps the *system* awake with the lid closed and sleeps it when you're done. Just leave Amphetamine's **"Allow when display is closed"** option **off** — that one fights Astopos for the lid-closed setting. Everything else can stay on.
- A dark/locked screen while armed is normal — the Mac is still awake and your sessions keep running. The password on reopen is just macOS's screen lock (tied to the display turning off), not a wake-from-sleep.
