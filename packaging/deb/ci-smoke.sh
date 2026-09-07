#!/bin/bash
#
# ci-smoke.sh — install the built .deb on this system and prove it works.
#
# Meant to run inside a throwaway Ubuntu container (it installs packages and
# writes to $HOME), one per release we claim to support:
#
#   docker run --rm -v "$PWD:/pkg" -w /pkg ubuntu:22.04 \
#     bash packaging/deb/ci-smoke.sh dist/tower_3.1.0_all.deb \
#                                    dist/tower-tray_3.1.0_all.deb
#
# The second argument is optional; given, it also installs the top-bar package
# and checks the parts of it that do not need a session.
#
# What it actually checks — the packaging claims, not the app's features:
#   * apt can resolve the declared Depends on this Ubuntu (so `apt install`,
#     never `dpkg -i`, which would skip exactly that half),
#   * the daemon starts on this Ubuntu's Python and writes state,
#   * it reports platform "linux" and brings its proxy up,
#   * it installs routing into ~/.claude/settings.json,
#   * SIGTERM takes that routing back out — the invariant that a stopped Tower
#     leaves Claude Code on a working direct connection,
#   * removing the package removes the files.
#
# And for tower-tray:
#   * apt can resolve GTK3 + the Ayatana indicator bindings on this Ubuntu,
#   * the module byte-compiles and its GI typelibs actually import,
#   * with no session it exits 1 with one honest line instead of a traceback.
set -euo pipefail

DEB="${1:?usage: ci-smoke.sh <path-to-.deb> [<path-to-tray.deb>]}"
TRAY_DEB="${2:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"
export DEBIAN_FRONTEND=noninteractive

step() { printf '\n▸ %s\n' "$*"; }

step "installing $DEB"
apt-get update -qq
# `apt install ./file.deb` (not dpkg -i) so Depends are resolved for real.
apt-get install -y -qq "./$DEB" >/dev/null
command -v tower
command -v towerd
test -f /usr/lib/systemd/user/tower.service
# Ask dpkg, not the filesystem: the official Ubuntu container images ship a
# dpkg exclude for /usr/share/man, so an installed man page is legitimately
# absent there while still being in the package.
dpkg -L tower | grep -q 'man1/tower\.1\.gz'

step "python version on this release"
python3 -V
# The build machine byte-compiles with its own (newer) Python; this is the one
# that matters — 22.04 ships 3.10, so a newer-syntax slip has to fail here.
python3 -m py_compile /usr/lib/tower/towerd.py \
                      /usr/lib/tower/tower-tui.py \
                      /usr/lib/tower/_linux.py
echo "  byte-compiles"

step "the daemon comes up and guards"
export HOME=/tmp/towerhome
rm -rf "$HOME"
mkdir -p "$HOME/.claude"
echo '{}' > "$HOME/.claude/settings.json"
TOWER_PORT=18888 towerd &
pid=$!

for _ in $(seq 1 40); do
  [ -f "$HOME/.tower/state.json" ] && break
  sleep 1
done
test -f "$HOME/.tower/state.json" || { echo "no state.json"; exit 1; }

python3 "$HERE/ci-assert.py"

grep -q HTTPS_PROXY "$HOME/.claude/settings.json" \
  || { echo "routing was not installed"; cat "$HOME/.claude/settings.json"; exit 1; }
echo "  routing installed"

step "SIGTERM un-routes"
kill -TERM "$pid"
for _ in $(seq 1 25); do
  grep -q HTTPS_PROXY "$HOME/.claude/settings.json" || break
  sleep 1
done
if grep -q HTTPS_PROXY "$HOME/.claude/settings.json"; then
  echo "FAIL: settings.json still routed after SIGTERM"
  cat "$HOME/.claude/settings.json"
  exit 1
fi
echo "  un-routed"
cat "$HOME/.tower/daemon.log"

if [ -n "$TRAY_DEB" ]; then
  step "installing $TRAY_DEB"
  # --no-install-recommends on purpose, twice over: the Recommends is
  # gnome-shell-extension-appindicator, which pulls the whole of GNOME Shell
  # into a container that will never draw a pixel, and the thing worth testing
  # is that the *hard* dependencies are enough to import the toolkit.
  apt-get install -y -qq --no-install-recommends "./$TRAY_DEB" >/dev/null
  command -v tower-tray
  test -f /usr/lib/systemd/user/tower-tray.service
  dpkg -L tower-tray | grep -q 'man1/tower-tray\.1\.gz'

  step "the tray's toolkit is really there"
  python3 -m py_compile /usr/lib/tower/tower-tray.py
  # A satisfied Depends line is not proof: the typelibs have to load.
  python3 - <<'PYCHECK'
import gi
gi.require_version("Gtk", "3.0")
for name in ("AyatanaAppIndicator3", "AppIndicator3"):
    try:
        gi.require_version(name, "0.1")
        __import__("gi.repository." + name)
        print("  indicator bindings:", name)
        break
    except (ValueError, ImportError):
        continue
else:
    raise SystemExit("no AppIndicator typelib after installing tower-tray")
from gi.repository import Gtk          # noqa: F401
import cairo                            # noqa: F401  (python3-gi-cairo)
print("  gtk3 + cairo import clean")
PYCHECK

  step "with no session it says so, once, and exits"
  set +e
  out=$(tower-tray 2>&1); rc=$?
  set -e
  [ "$rc" = "1" ] || { echo "FAIL: expected exit 1, got $rc"; echo "$out"; exit 1; }
  case "$out" in
    *"no graphical session"*) echo "  $out" ;;
    *) echo "FAIL: unhelpful output with no session:"; echo "$out"; exit 1 ;;
  esac
fi

step "removal"
if [ -n "$TRAY_DEB" ]; then
  apt-get remove -y -qq tower-tray >/dev/null
  test ! -e /usr/bin/tower-tray
fi
apt-get remove -y -qq tower >/dev/null
test ! -e /usr/lib/tower/towerd.py
test ! -e /usr/bin/tower

printf '\n✓ %s is good on %s\n' "$DEB" "$(. /etc/os-release && echo "$PRETTY_NAME")"
