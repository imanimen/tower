# Tower on Linux

Tower on Linux is the **daemon plus the terminal dashboard**. The menu-bar app
is macOS-only (Swift/AppKit), so `tower` — the curses dashboard — is the whole
front-end here, and it is a complete one: everything the popover can do, the
TUI can do.

The split that makes this cheap is the same one the Windows port uses: **one
daemon owns all logic and state; the front-ends read `~/.tower/state.json` and
write `~/.tower/cmd/*.json`.** `towerd.py` is stdlib Python and already
portable; only four OS edges differ, and they live in `src/_linux.py`.

## Install

```sh
sudo apt install ./tower_<version>_all.deb
```

Ubuntu 22.04 through 26.04 (and Debian 12+). `Architecture: all` — Tower on
Linux compiles nothing, so one package covers amd64 and arm64.

Dependencies are `python3` (>= 3.9) and `procps`, both of which a stock Ubuntu
already has. `tmux` is a *Recommends*: without it the dashboard cannot raise an
agent's terminal tab and hands you `claude --resume <id>` instead. Nothing else
depends on it.

To build the package from a checkout:

```sh
packaging/deb/build.sh              # -> dist/tower_<version>_all.deb
packaging/deb/build.sh --install    # ...and apt-install it
```

It uses plain `dpkg-deb`, so the only build dependency is dpkg itself — no
debhelper, no build-essential, and the same script runs on 22.04 and 26.04.

## Running it

```sh
tower                                 # open the dashboard; starts the daemon
systemctl --user enable --now tower   # keep the guard running from login
systemctl --user status tower
journalctl --user -u tower -f
```

Installing the package **starts nothing**. That is deliberate: the daemon opens
a local proxy and edits `~/.claude/settings.json`, which should be something
you switch on knowingly, and it is per-user state that a root-run `postinst`
has no session to enable anyway. "On by default" still holds where it matters —
`tower` starts the daemon on demand, so opening the dashboard is enough. The
systemd **user** unit is the login-item analog, one command away.

Stopping the unit sends `SIGTERM`, which the daemon handles by removing the
proxy from `~/.claude/settings.json` before it exits. A stopped Tower always
leaves Claude Code on a working direct connection.

## What differs from macOS

Four edges, all in `src/_linux.py`:

| | macOS | Linux |
|---|---|---|
| Keep-awake | `caffeinate` + `pmset disablesleep` (lid mode needs an admin password and a sudoers rule) | `systemd-inhibit` — covers idle, sleep **and the lid switch**, for any user |
| A process's cwd | `lsof -d cwd` | `readlink /proc/<pid>/cwd` |
| Who is connected to the guard | `lsof -iTCP@127.0.0.1:<port>` | `/proc/net/tcp{,6}` inodes → `/proc/<pid>/fd` |
| Focus an agent's tab | Terminal.app / iTerm2 via `osascript`, then tmux | tmux only; otherwise the dashboard hands you `claude --resume <id>` |

Two macOS concerns simply do not exist here:

- **No TCC.** macOS makes Tower avoid ever reading under `~/Desktop`,
  `~/Documents`, `~/Pictures` and friends, because the first read triggers a
  permission prompt attributed to Tower. Linux has no such prompt, so
  `_PROTECTED_ROOTS` is empty and the agent monitor reads git roots and
  branches for agents working anywhere.
- **No admin password, ever.** The lid-closed keep-awake mode is the one macOS
  feature that needs `sudo`; logind grants the same inhibitor lock to any user,
  so on Linux it is free.

Everything else is shared code: the proxy, the fail-closed gate, multi-source
geolocation, the network probe, `claude -p /usage` parsing, the transcript
index, and the agent monitor.

## Where Claude Code has to be findable

Real plan usage comes from running `claude -p /usage` — Claude Code does the
auth, Tower never touches the token. A systemd user unit inherits almost no
`PATH`, so the shipped unit sets one that includes `~/.local/bin`,
`~/.npm-global/bin` and `/snap/bin`, and `find_claude()` checks those paths
directly as well. If the dashboard says *claude CLI not found*, that is what to
check.

## Files

| Path | |
|---|---|
| `/usr/bin/tower` | the dashboard |
| `/usr/bin/towerd` | the daemon (you rarely run this by hand) |
| `/usr/lib/tower/` | `towerd.py`, `tower-tui.py`, `_linux.py` |
| `/usr/lib/systemd/user/tower.service` | the login-item analog |
| `~/.tower/` | state, config, log, command files |
| `~/.claude/settings.json` | where routing is installed — the `env` block only |

Removing the package stops any running daemon first (so each one un-routes on
its way out) and leaves `~/.tower` alone. To clear it: `rm -rf ~/.tower`.

## Not on Linux

- **The menu-bar app.** A tray front-end would be the GTK/Qt analog of
  `AppIndicator`; nothing in the daemon is in its way — it would read the same
  `state.json` and write the same command files — but it is not written.
- **Desktop notifications.** macOS gets them from the app (`Notifier.swift`);
  the daemon itself has never sent any, on any platform, so the dashboard is
  where status shows up here.
