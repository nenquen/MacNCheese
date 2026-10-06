#!/bin/sh
# Mac'n Cheese inside the Flatpak: its own Darling prefix, Darling
# without root (darling-noroot.c) and the prebuilt shim + native launcher.
export DPREFIX="${DPREFIX:-$XDG_DATA_HOME/darling}"
export MACNCHEESE_NOROOT_LIB=/app/lib/macncheese/darling-noroot.so
export MACNCHEESE_PID1_DYLIB=/app/lib/macncheese/launchd_pid1.dylib
export MACNCHEESE_PREBUILT_SHIM=/app/lib/macncheese/shim
# ld.so's cache does not cover /app/lib, and Darling's mldr dlopens ELF
# libraries from there by bare soname (libjpeg.so.8 and friends).
export LD_LIBRARY_PATH="/app/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
# Debug on: every launch records the env it got — launch mysteries
# otherwise end up as screenshot archaeology. Debug off: the launcher
# keeps nothing (the Rust side gates session.log and the launch log the
# same way; this file is the third one).
settings="${XDG_CONFIG_HOME:-$HOME/.config}/macncheese/settings.json"
if grep -q '"debug": *true' "$settings" 2>/dev/null; then
  mkdir -p "${XDG_DATA_HOME:-$HOME/.local/share}/macncheese/logs" 2>/dev/null
  {
    echo "--- $(date '+%F %T') pid=$$ args=$*"
    env | grep -E '^(MACNCHEESE|DPREFIX|PATH)' | sed 's/^/    /'
  } >> "${XDG_DATA_HOME:-$HOME/.local/share}/macncheese/logs/launcher-env.log" 2>/dev/null
fi
exec /app/lib/macncheese/macncheese "$@"
