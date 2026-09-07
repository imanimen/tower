#!/bin/bash
#
# build.sh — build the Tower .debs for Ubuntu 22.04 through 26.04.
#
#   packaging/deb/build.sh                 # → dist/tower_<v>_all.deb + tower-tray
#   packaging/deb/build.sh --version 3.1.1 # override the version
#   packaging/deb/build.sh --install       # build, then `sudo apt install` both
#
# Two packages, because they have different reasons to exist:
#
#   tower       the daemon + the curses dashboard. python3 and procps, both on
#               a stock Ubuntu already — installable on a headless server.
#   tower-tray  the top-bar radar. Pulls GTK3 and the Ayatana indicator
#               bindings, which have no business on a server.
#
# Architecture: all — Tower on Linux compiles nothing (the Swift menu-bar app
# is macOS-only and is not in either package), so one build covers amd64 and
# arm64 alike.
#
# Deliberately built with plain `dpkg-deb --build --root-owner-group`, not
# debhelper: nothing here needs compiling, so the only build dependency is dpkg
# itself — the same script runs on 22.04 and on 26.04, and in a CI container
# with no build-essential.
#
# The version comes from src/Info.plist (CFBundleShortVersionString), the same
# single source release.sh uses, so the .debs and the macOS app can never
# disagree about what version they are.
set -euo pipefail

# The build must not inherit the caller's umask: on Ubuntu it is 002, which
# would ship group-writable directories and man pages (and dpkg-deb only
# rewrites ownership, not modes).
umask 022

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
DIST="$ROOT/dist"
MAINTAINER="${DEB_MAINTAINER:-Tower contributors <noreply@github.com>}"

VERSION=""
DO_INSTALL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION="${2:?--version needs a value}"; shift 2 ;;
    --install) DO_INSTALL=1; shift ;;
    -h|--help) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "build.sh: unknown argument '$1'" >&2; exit 1 ;;
  esac
done

command -v dpkg-deb >/dev/null 2>&1 || {
  echo "error: dpkg-deb not found — this script builds Debian packages." >&2
  exit 1
}
command -v python3 >/dev/null 2>&1 || {
  echo "error: python3 not found (needed to read src/Info.plist)." >&2
  exit 1
}

if [ -z "$VERSION" ]; then
  VERSION="$(python3 - "$ROOT/src/Info.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], "rb") as f:
    print(plistlib.load(f)["CFBundleShortVersionString"])
PY
)"
fi

# Debian versions are ordered, and an X.Y that sorts next to an existing X.Y.Z
# is the same trap release.sh guards against for tags.
case "$VERSION" in
  [0-9]*.[0-9]*.[0-9]*) : ;;
  *) echo "error: version '$VERSION' must be X.Y.Z." >&2; exit 1 ;;
esac

mkdir -p "$DIST"

# ---------------------------------------------------------------------------
# changelog + man page + control, shared by both packages.
# ---------------------------------------------------------------------------
# gzip -n: no timestamp in the header, so two builds of the same source produce
# byte-identical files.
write_docs() {           # $1 = pkgdir, $2 = package name, $3.. = man pages
  local pkgdir="$1" pkg="$2"; shift 2
  install -m 0644 "$HERE/copyright" "$pkgdir/usr/share/doc/$pkg/copyright"
  {
    printf 'tower (%s) unstable; urgency=medium\n\n' "$VERSION"
    printf '  * Tower %s for Debian/Ubuntu.\n' "$VERSION"
    printf '    Release notes: https://github.com/imanimen/tower/releases\n\n'
    printf ' -- %s  %s\n' "$MAINTAINER" "$(date -R)"
  } > "$pkgdir/usr/share/doc/$pkg/changelog.Debian"
  gzip -9n "$pkgdir/usr/share/doc/$pkg/changelog.Debian"
  chmod 0644 "$pkgdir/usr/share/doc/$pkg/changelog.Debian.gz"
  for m in "$@"; do
    sed "s/@VERSION@/$VERSION/g" "$HERE/$m.1" \
      > "$pkgdir/usr/share/man/man1/$m.1"
    gzip -9n "$pkgdir/usr/share/man/man1/$m.1"
    chmod 0644 "$pkgdir/usr/share/man/man1/$m.1.gz"
  done
}

write_control() {        # $1 = pkgdir, $2 = control template basename
  local pkgdir="$1" tmpl="$2"
  local size
  size="$(du -sk --apparent-size "$pkgdir" | cut -f1)"
  sed -e "s/@VERSION@/$VERSION/g" \
      -e "s|@MAINTAINER@|$MAINTAINER|g" \
      -e "s/@SIZE@/$size/g" \
      "$HERE/$tmpl" > "$pkgdir/DEBIAN/control"
}

finish() {               # $1 = pkgdir, $2 = package name
  local pkgdir="$1" pkg="$2"
  # md5sums, which dpkg-deb does not generate for us. Paths relative to /.
  ( cd "$pkgdir" && find . -type f ! -path './DEBIAN/*' -printf '%P\0' \
    | sort -z | xargs -0 md5sum > DEBIAN/md5sums )
  local deb="$DIST/${pkg}_${VERSION}_all.deb"
  rm -f "$deb"
  # --root-owner-group: every file lands as root:root without needing fakeroot.
  dpkg-deb --build --root-owner-group "$pkgdir" "$deb" >/dev/null
  echo "✓ $deb"
}

echo "▸ building tower $VERSION"

# ---------------------------------------------------------------------------
# tower — the daemon and the terminal dashboard.
# ---------------------------------------------------------------------------
PKG="$ROOT/build/deb/tower_${VERSION}_all"
rm -rf "$PKG"
mkdir -p "$PKG/DEBIAN" "$PKG/usr/lib/tower" "$PKG/usr/bin" \
         "$PKG/usr/lib/systemd/user" "$PKG/usr/share/applications" \
         "$PKG/usr/share/icons/hicolor/scalable/apps" \
         "$PKG/usr/share/man/man1" "$PKG/usr/share/doc/tower"

# _win.py/_wincurses.py are left out on purpose: they are imported only when
# os.name == "nt", so on a Debian system they are dead weight.
install -m 0644 "$ROOT/src/towerd.py"    "$PKG/usr/lib/tower/towerd.py"
install -m 0644 "$ROOT/src/tower-tui.py" "$PKG/usr/lib/tower/tower-tui.py"
install -m 0644 "$ROOT/src/_linux.py"    "$PKG/usr/lib/tower/_linux.py"
install -m 0755 "$HERE/bin/tower"        "$PKG/usr/bin/tower"
install -m 0755 "$HERE/bin/towerd"       "$PKG/usr/bin/towerd"
install -m 0644 "$HERE/tower.service" "$PKG/usr/lib/systemd/user/tower.service"
install -m 0644 "$HERE/tower.desktop" "$PKG/usr/share/applications/tower.desktop"
install -m 0644 "$HERE/tower.svg" \
  "$PKG/usr/share/icons/hicolor/scalable/apps/tower.svg"
install -m 0644 "$ROOT/README.md" "$PKG/usr/share/doc/tower/README.md"
[ -f "$ROOT/docs/LINUX.md" ] && \
  install -m 0644 "$ROOT/docs/LINUX.md" "$PKG/usr/share/doc/tower/LINUX.md"
write_docs "$PKG" tower tower towerd
install -m 0755 "$HERE/postinst-tower" "$PKG/DEBIAN/postinst"
install -m 0755 "$HERE/prerm-tower"    "$PKG/DEBIAN/prerm"
install -m 0755 "$HERE/postrm-tower"   "$PKG/DEBIAN/postrm"
write_control "$PKG" control-tower.in

# ---------------------------------------------------------------------------
# tower-tray — the top-bar radar (GTK3 + Ayatana indicator).
# ---------------------------------------------------------------------------
TRAY="$ROOT/build/deb/tower-tray_${VERSION}_all"
rm -rf "$TRAY"
mkdir -p "$TRAY/DEBIAN" "$TRAY/usr/lib/tower" "$TRAY/usr/bin" \
         "$TRAY/usr/lib/systemd/user" "$TRAY/usr/share/applications" \
         "$TRAY/usr/share/man/man1" "$TRAY/usr/share/doc/tower-tray"

install -m 0644 "$ROOT/src/tower-tray.py" "$TRAY/usr/lib/tower/tower-tray.py"
install -m 0755 "$HERE/bin/tower-tray"    "$TRAY/usr/bin/tower-tray"
install -m 0644 "$HERE/tower-tray.service" \
  "$TRAY/usr/lib/systemd/user/tower-tray.service"
install -m 0644 "$HERE/tower-tray.desktop" \
  "$TRAY/usr/share/applications/tower-tray.desktop"
write_docs "$TRAY" tower-tray tower-tray
install -m 0755 "$HERE/postinst-tray" "$TRAY/DEBIAN/postinst"
install -m 0755 "$HERE/prerm-tray"    "$TRAY/DEBIAN/prerm"
install -m 0755 "$HERE/postrm-tray"   "$TRAY/DEBIAN/postrm"
write_control "$TRAY" control-tray.in

# ---------------------------------------------------------------------------
# Byte-compile check: fail the build rather than ship a syntax error. 22.04
# runs Python 3.10, so a newer-syntax slip has to be caught here, not by a user.
# ---------------------------------------------------------------------------
python3 -m py_compile "$PKG/usr/lib/tower/towerd.py" \
                      "$PKG/usr/lib/tower/tower-tui.py" \
                      "$PKG/usr/lib/tower/_linux.py" \
                      "$TRAY/usr/lib/tower/tower-tray.py"
find "$PKG" "$TRAY" -name '__pycache__' -type d -exec rm -rf {} +

finish "$PKG" tower
finish "$TRAY" tower-tray

for deb in "$DIST/tower_${VERSION}_all.deb" "$DIST/tower-tray_${VERSION}_all.deb"; do
  dpkg-deb --info "$deb" | sed -n '/^ Package:/,/^ Description:/p'
done

if command -v lintian >/dev/null 2>&1; then
  echo "▸ lintian (advisory)"
  lintian --no-tag-display-limit "$DIST/tower_${VERSION}_all.deb" \
          "$DIST/tower-tray_${VERSION}_all.deb" || true
fi

if [ "$DO_INSTALL" = "1" ]; then
  echo "▸ installing"
  sudo apt install -y "$DIST/tower_${VERSION}_all.deb" \
                      "$DIST/tower-tray_${VERSION}_all.deb"
fi
