# Tower on Linux

Tower on Linux is the **daemon**, the **terminal dashboard**, and the **top-bar
radar** — the Linux answer to the macOS menu-bar app. One package with all
three:

| Command | What it is |
|---|---|
| `tower-tray` | the radar in your top bar, and the panel behind it |
| `tower` | the curses terminal dashboard |
| `towerd` | the daemon (you rarely run this by hand) |

The only hard dependencies are `python3` and `procps`, both on a stock Ubuntu
already. GTK3 and the Ayatana indicator bindings are **Recommends**, not
Depends: apt pulls them by default on a desktop, and
`apt install --no-install-recommends` gives a headless machine the daemon and
the dashboard without dragging GTK onto a server. Without them `tower-tray`
says so and names the packages it wants.

The split that makes all of this cheap is the same one the Windows port uses:
**one daemon owns all logic and state; the front-ends read
`~/.tower/state.json` and write `~/.tower/cmd/*.json`.** `towerd.py` is stdlib
Python and already portable; only four OS edges differ, and they live in
`src/_linux.py`.

## Install

```sh
sudo apt install ./tower_<version>_all.deb                       # desktop
sudo apt install --no-install-recommends ./tower_<version>_all.deb   # server
```

Ubuntu 22.04 through 26.04 (and Debian 12+). `Architecture: all` — Tower on
Linux compiles nothing, so one package covers amd64 and arm64.

`tmux` is another *Recommends*: without it neither front-end can raise an
agent's terminal tab, and both hand you `claude --resume <id>` instead.
`gnome-shell-extension-appindicator` is a *Suggests* — Ubuntu's GNOME session
already enables it, and making it a Recommends would drag GNOME Shell onto
machines that will never draw a pixel.

To build it from a checkout:

```sh
packaging/deb/build.sh              # -> dist/tower_<version>_all.deb
packaging/deb/build.sh --install    # ...and apt-install it
```

It uses plain `dpkg-deb`, so the only build dependency is dpkg itself — no
debhelper, no build-essential, and the same script runs on 22.04 and 26.04.

## Running it

```sh
tower-tray                                 # the radar in your top bar
tower                                      # the terminal dashboard
systemctl --user enable --now tower-tray   # the radar there from login
systemctl --user enable --now tower        # the guard alone, no session needed
systemctl --user status tower
journalctl --user -u tower -f
```

Either front-end starts the daemon on demand, so `tower-tray` on its own is the
whole setup. The `tower.service` unit is for a machine with no session — a
build box you still want guarded.

Installing the package **starts nothing**. That is deliberate: the daemon opens
a local proxy and edits `~/.claude/settings.json`, which should be something
you switch on knowingly, and it is per-user state that a root-run `postinst`
has no session to enable anyway. "On by default" still holds where it matters —
`tower` starts the daemon on demand, so opening the dashboard is enough. The
systemd **user** unit is the login-item analog, one command away.

Stopping the unit sends `SIGTERM`, which the daemon handles by removing the
proxy from `~/.claude/settings.json` before it exits. A stopped Tower always
leaves Claude Code on a working direct connection.

## The top bar

`tower-tray` draws Tower's radar as a **StatusNotifierItem**: the same five
looks as the macOS menu bar (a calm pulse while guarding, a rotating sweep
while confirming your location, amber dashed with sonar pings when there is no
path to Anthropic, an amber fence and a lunging blip when you are off-country,
a red dashed ring with a hollow core when routing is off), with the keep-awake
lamp lighting the core underneath. The geometry is a Cairo port of
`drawRadar()` in `src/Glyph.swift` — one mark, two toolkits — and the desktop's
own *reduce animations* setting freezes each state at its legible still frame.

Left-click is the menu: status, the guard toggle, keep-awake, target country,
the running agents (click one to raise its tab), and **Open Tower…** for the
full panel — network weather, the needs-you queue, agents, location,
keep-awake, and plan usage, in the popover's fixed attention order.
Middle-click opens the panel directly. Closing the panel never stops the guard.

Turning the guard off and quitting are warned and confirmed **twice**, and the
warning quotes how many agents are working right now (they would start sending
unguarded requests immediately); quitting also quotes how many chats are pinned
to the proxy and will lose their connection until restarted. Same rule, same
numbers, as the app and the TUI.

### Why AppIndicator, and what GNOME needs

GTK's own `StatusIcon` has been deprecated for a decade and does not appear on
GNOME under Wayland at all, so the tray is a StatusNotifierItem — which KDE,
XFCE, Cinnamon and Budgie render natively. **GNOME shows one only through the
shipped appindicator extension.** Ubuntu's GNOME session enables it by default;
if you see no radar:

```sh
sudo apt install gnome-shell-extension-appindicator
gnome-extensions enable ubuntu-appindicators@ubuntu.com
```

The toolkit is GTK3 through the distro's own `python3-gi`. That is the Linux
reading of Tower's *no third-party deps* rule: AppKit is macOS's platform
toolkit, GTK is Ubuntu's, and neither arrives through pip.

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
| `/usr/bin/tower-tray` | the top-bar radar |
| `/usr/lib/tower/` | `towerd.py`, `tower-tui.py`, `tower-tray.py`, `_linux.py` |
| `/usr/lib/systemd/user/tower{,-tray}.service` | the login-item analogs |
| `~/.tower/` | state, config, log, command files |
| `~/.cache/tower/icons` | rendered radar frames (a cache; safe to delete) |
| `~/.claude/settings.json` | where routing is installed — the `env` block only |

Removing the package stops any running daemon first (so each one un-routes on
its way out) and leaves `~/.tower` alone. To clear it: `rm -rf ~/.tower`.

## Not on Linux

- **Desktop notifications.** macOS gets them from the app
  (`src/Notifier.swift`); the daemon itself has never sent any, on any
  platform, so the top bar and the dashboard are where status shows up here.
- **The model marks.** The per-model glyphs (`drawModelMark`) are not ported;
  the tray names the model in the row's accent colour, which is what the TUI
  does too.
- **Popover placement.** Wayland gives a client no way to put a surface under a
  top-bar item, so **Open Tower…** opens a titled window rather than a panel
  pinned to the icon. Pretending otherwise would mean a panel that lands in the
  wrong place.
