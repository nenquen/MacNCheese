#!/bin/sh
# Mac'n Cheese inside the Flatpak: its own Darling prefix, Darling
# without root (darling-noroot.c) and the prebuilt shim + native launcher.
export DPREFIX="${DPREFIX:-$XDG_DATA_HOME/darling}"
export MACNCHEESE_NOROOT_LIB=/app/lib/macncheese/darling-noroot.so
export MACNCHEESE_PID1_DYLIB=/app/lib/macncheese/launchd_pid1.dylib
export MACNCHEESE_PREBUILT_SHIM=/app/lib/macncheese/shim
# Every launch records the env it got — launch mysteries otherwise end
# up as screenshot archaeology.
mkdir -p "${XDG_DATA_HOME:-$HOME/.local/share}/macncheese/logs" 2>/dev/null
{
  echo "--- $(date '+%F %T') pid=$$ args=$*"
  env | grep -E '^(MACNCHEESE|DPREFIX|PATH)' | sed 's/^/    /'
} >> "${XDG_DATA_HOME:-$HOME/.local/share}/macncheese/logs/launcher-env.log" 2>/dev/null
exec /app/lib/macncheese/macncheese "$@"
