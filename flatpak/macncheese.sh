#!/bin/sh
# Mac'n Cheese inside the Flatpak: a Darling prefix of its own, Darling
# without root (darling-noroot.c) and the shim built with the package.
export DPREFIX="${DPREFIX:-$XDG_DATA_HOME/darling}"
export MACNCHEESE_NOROOT_LIB=/app/lib/macncheese/darling-noroot.so
export MACNCHEESE_PID1_DYLIB=/app/lib/macncheese/launchd_pid1.dylib
export MACNCHEESE_PREBUILT_SHIM=/app/lib/macncheese/shim
exec python3 /app/share/macncheese/launcher/macncheese-launcher "$@"
