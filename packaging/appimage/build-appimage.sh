#!/usr/bin/env bash
# Mac'n Cheese AppImage: native TUI binary + shim sources.
# No Python, no GTK, no sharun: the static-ish Rust binary only needs
# the host libc and terminal. Darling stays on the system (setuid cannot
# live in an AppImage).
set -euo pipefail

WORK=${WORK:-$(pwd)/work}
OUT=${OUT:-$(pwd)/MacNCheese-x86_64.AppImage}

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
APPDIR=$WORK/AppDir

[[ $(uname -m) == x86_64 ]] || { echo "AppImage builds run only on x86_64" >&2; exit 1; }
command -v cargo >/dev/null || { echo "cargo is required" >&2; exit 1; }

fetch() { # fetch <url> <file>
  [[ -f $2 ]] || curl -fL --progress-bar -o "$2" "$1"
  chmod +x "$2"
}

mkdir -p -- "$WORK"
cd -- "$WORK"
fetch https://github.com/VHSgunzo/uruntime/releases/latest/download/uruntime-appimage-x86_64 uruntime

echo "==> building native launcher"
(cd "$REPO_ROOT/native" && cargo build --release)

echo "==> staging AppDir"
rm -rf -- "$APPDIR"
mkdir -p -- "$APPDIR/usr/share/macncheese" "$APPDIR/usr/bin"
cp -r -- "$REPO_ROOT/branding" "$REPO_ROOT/shim" \
  "$REPO_ROOT/frameworks" \
  "$REPO_ROOT/build_debug_shim.sh" "$REPO_ROOT/LICENSE" "$APPDIR/usr/share/macncheese/"
install -m755 "$REPO_ROOT/native/target/release/macncheese" "$APPDIR/usr/bin/macncheese"

echo "==> desktop integration"
sed "s|^Exec=.*|Exec=macncheese %u|; s|^Icon=.*|Icon=macncheese|; s|^Terminal=.*|Terminal=true|" \
  "$REPO_ROOT/packaging/org.macncheese.MacNCheese.desktop" \
  > "$APPDIR/org.macncheese.MacNCheese.desktop"
cp -- "$REPO_ROOT/branding/icons/macncheese-256.png" "$APPDIR/macncheese.png"
ln -sf macncheese.png "$APPDIR/.DirIcon"

# AppRun is a real file (not a symlink): readlink -f on a symlink would
# resolve into usr/bin and double the share path at runtime.
cat > "$APPDIR/AppRun" <<'APPRUN'
#!/bin/sh
HERE=$(dirname "$0")
case "$HERE" in
  /*) ;;
  *) HERE="$PWD/$HERE" ;;
esac
if [ -z "${DARLING_SYSROOT:-}" ] && [ ! -d /usr/libexec/darling ] && [ ! -d /usr/local/libexec/darling ]; then
  echo "Mac'n Cheese AppImage needs Darling on the system." >&2
  echo "Install it first: https://github.com/nenquen/MacNCheese#install" >&2
  exit 1
fi
export MACNCHEESE_PROJECT="$HERE/usr/share/macncheese"
exec "$HERE/usr/bin/macncheese" "$@"
APPRUN
chmod +x -- "$APPDIR/AppRun"

echo "==> packing with uruntime (squashfs + append)"
./uruntime --uruntime-mksquashfs "$APPDIR" "$WORK/macncheese.squashfs" -comp zstd -b 1M
cat ./uruntime "$WORK/macncheese.squashfs" > "$OUT"
chmod +x -- "$OUT"
rm -f -- "$WORK/macncheese.squashfs"
echo "Built: $OUT"
