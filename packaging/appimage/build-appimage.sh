#!/usr/bin/env bash
# Experimental AppImage builder: launcher only, Darling stays on the host.
# See README.md in this directory for the rationale and risks.
set -euo pipefail

WORK=${WORK:-$(pwd)/work}
OUT=${OUT:-$(pwd)/MacNCheese-x86_64.AppImage}
RUN_TEST=0
[[ ${1:-} == "--run" ]] && RUN_TEST=1

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
APPDIR=$WORK/AppDir

command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 1; }
[[ $(uname -m) == x86_64 ]] || { echo "AppImage builds run only on x86_64" >&2; exit 1; }

mkdir -p -- "$WORK"
cd -- "$WORK"

fetch() { # fetch <url> <file>
  [[ -f $2 ]] || curl -fL --progress-bar -o "$2" "$1"
  chmod +x "$2"
}

echo "==> fetching sharun toolchain"
fetch https://github.com/VHSgunzo/sharun/releases/latest/download/sharun-x86_64 sharun
fetch https://raw.githubusercontent.com/pkgforge-dev/AnyLinux-AppImages/main/useful-tools/quick-sharun.sh quick-sharun.sh
fetch https://github.com/VHSgunzo/uruntime/releases/latest/download/uruntime-appimage-x86_64 uruntime

echo "==> staging AppDir"
rm -rf -- "$APPDIR"
mkdir -p -- "$APPDIR/usr/share/macncheese" "$APPDIR/usr/bin"
cp -r -- "$REPO_ROOT/launcher" "$REPO_ROOT/branding" "$REPO_ROOT/shim" \
  "$REPO_ROOT/build_debug_shim.sh" "$REPO_ROOT/LICENSE" "$APPDIR/usr/share/macncheese/"
rm -f -- "$APPDIR/usr/share/macncheese/launcher/install.sh"
cat > "$APPDIR/usr/bin/macncheese" <<'LAUNCHER'
#!/bin/sh
# Scrub bundled-library leakage so the shim build sees host clang/lld.
HERE=$(dirname "$(readlink -f "$0")")
APPIMAGE_SHARE="$HERE/../share/macncheese"
if [ -z "${DARLING_SYSROOT:-}" ] && [ ! -d /usr/libexec/darling ] && [ ! -d /usr/local/libexec/darling ]; then
  echo "Mac'n Cheese AppImage needs Darling on the system." >&2
  echo "Install it first: https://github.com/nenquen/MacNCheese#install" >&2
  exit 1
fi
unset LD_LIBRARY_PATH
exec python3 "$APPIMAGE_SHARE/launcher/macncheese-launcher" "$@"
LAUNCHER
chmod +x -- "$APPDIR/usr/bin/macncheese"

echo "==> desktop integration"
sed "s|^Exec=.*|Exec=macncheese %u|; s|^Icon=.*|Icon=macncheese|" \
  "$REPO_ROOT/packaging/org.macncheese.MacNCheese.desktop" \
  > "$APPDIR/org.macncheese.MacNCheese.desktop"
cp -- "$REPO_ROOT/branding/icons/macncheese-256.png" "$APPDIR/macncheese.png"
# AppRun is a real file (not a symlink): readlink -f on a symlink would
# resolve into usr/bin and double the share path at runtime.
cat > "$APPDIR/AppRun" <<'APPRUN'
#!/bin/sh
HERE=$(dirname "$0")
case "$HERE" in
  /*) ;;
  *) HERE="$PWD/$HERE" ;;
esac
export APPDIR="$HERE"
export LD_LIBRARY_PATH="$HERE/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export GI_TYPELIB_PATH="$HERE/lib/girepository-1.0"
export GSETTINGS_SCHEMA_DIR="$HERE/share/glib-2.0/schemas"
export GIO_MODULE_DIR="$HERE/lib/gio/modules"
export PYTHONPATH="$HERE/lib/python3.14/site-packages${PYTHONPATH:+:$PYTHONPATH}"
export XDG_DATA_DIRS="$HERE/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
if [ -z "${DARLING_SYSROOT:-}" ] && [ ! -d /usr/libexec/darling ] && [ ! -d /usr/local/libexec/darling ]; then
  echo "Mac'n Cheese AppImage needs Darling on the system." >&2
  echo "Install it first: https://github.com/nenquen/MacNCheese#install" >&2
  exit 1
fi
exec python3 "$HERE/usr/share/macncheese/launcher/macncheese-launcher" "$@"
APPRUN
chmod +x -- "$APPDIR/AppRun"

echo "==> deploying dependencies with sharun (strace mode)"
export DISPLAY="${DISPLAY:-:0}"
./quick-sharun.sh "$APPDIR/usr/bin/macncheese" -- --help

echo "==> removing host-owned GPU stack from the bundle"
# Mesa DRI drivers, GL/EGL/GLES, Vulkan loaders and ICDs must come from
# the host, or the Zink probe tests the wrong driver.
find "$APPDIR" \( -path "*/dri/*" \
  -o -name "libGL*" -o -name "libEGL*" -o -name "libGLES*" \
  -o -name "libvulkan*" -o -name "*.icd.json" \) -delete || true

echo "==> packing with uruntime (squashfs + append)"
./uruntime --uruntime-mksquashfs "$APPDIR" "$WORK/macncheese.squashfs" -comp zstd -b 1M
cat ./uruntime "$WORK/macncheese.squashfs" > "$OUT"
chmod +x -- "$OUT"
rm -f -- "$WORK/macncheese.squashfs"

if [[ $RUN_TEST == 1 ]]; then
  echo "==> smoke test"
  "$OUT" --help
fi
echo "Built: $OUT"
