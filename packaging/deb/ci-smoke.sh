#!/bin/bash
#
# ci-smoke.sh — install the built .deb on this system and prove it works.
#
# Meant to run inside a throwaway Ubuntu container (it installs packages and
# writes to $HOME), one per release we claim to support:
#
#   docker run --rm -v "$PWD:/pkg" -w /pkg ubuntu:22.04 \
#     bash packaging/deb/ci-smoke.sh dist/tower_3.1.0_all.deb
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
set -euo pipefail

DEB="${1:?usage: ci-smoke.sh <path-to-.deb>}"
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

step "removal"
apt-get remove -y -qq tower >/dev/null
test ! -e /usr/lib/tower/towerd.py
test ! -e /usr/bin/tower

printf '\n✓ %s is good on %s\n' "$DEB" "$(. /etc/os-release && echo "$PRETTY_NAME")"
