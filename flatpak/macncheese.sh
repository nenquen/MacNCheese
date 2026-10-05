#!/bin/sh
# Mac'n Cheese inside the Flatpak: its own Darling prefix, Darling
# without root (darling-noroot.c) and the prebuilt shim + native launcher.
export DPREFIX="${DPREFIX:-$XDG_DATA_HOME/darling}"
export MACNCHEESE_NOROOT_LIB=/app/lib/macncheese/darling-noroot.so
export MACNCHEESE_PID1_DYLIB=/app/lib/macncheese/launchd_pid1.dylib
export MACNCHEESE_PREBUILT_SHIM=/app/lib/macncheese/shim
exec /app/bin/macncheese "$@"
