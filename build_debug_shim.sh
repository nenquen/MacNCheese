#!/usr/bin/env bash
set -euo pipefail
project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# C/Objective-C shim sources live in shim/; entry scripts stay at the root.
src_dir="$project_dir/shim"
# Output goes to MACNCHEESE_BUILD_DIR when the sources are read-only (a package).
build_dir=${MACNCHEESE_BUILD_DIR:-$project_dir/build}
# Packages put Darling's macOS root in /usr/libexec, a source build in /usr/local.
sysroot=${DARLING_SYSROOT:-/usr/libexec/darling}
[[ -d $sysroot || -n ${DARLING_SYSROOT:-} || ! -d /usr/local/libexec/darling ]] || sysroot=/usr/local/libexec/darling
mkdir -p "$build_dir"
# Native Wayland windowing lives in a Linux helper behind a versioned ABI.
if pkg-config --exists sdl2 wayland-client wayland-egl wayland-cursor; then
  wayland_output=$(mktemp "$build_dir/.wayland.XXXXXX")
  if clang++ -std=c++17 -O2 -fPIC -shared -pthread \
      $(pkg-config --cflags sdl2 wayland-client wayland-egl wayland-cursor) \
      "$src_dir/wayland_host.cpp" \
      $(pkg-config --libs sdl2 wayland-client wayland-egl wayland-cursor) \
      -o "$wayland_output"; then
    chmod 755 "$wayland_output"
    mv -- "$wayland_output" "$build_dir/libmacncheese-wayland.so"
  else
    rm -f -- "$wayland_output"
    exit 1
  fi
else
  rm -f -- "$build_dir/libmacncheese-wayland.so"
  printf '%s\n' 'Native Wayland helper skipped: install SDL2 and Wayland development libraries.' >&2
fi
tmp_output=$(mktemp "$build_dir/.shim.XXXXXX")
trap 'rm -f -- "$tmp_output"' EXIT
# Memory/string functions replacing Darling's unoptimized ones: -O2 and no
# builtins, compiled on their own (see fast_libc.c).
clang -target x86_64-apple-darwin -isysroot "$sysroot" -mmacosx-version-min=11.0 \
  -O2 -fno-builtin -c "$src_dir/fast_libc.c" -o "$build_dir/fast_libc.o"
# Newer clang compiles Objective-C literals (@1, @[], @{}) to constant objects
# of classes Darling's runtime does not have; -fno-objc-constant-literals turns
# that off. Older clang (22 and before) has neither the feature nor the flag
# and stops with "unknown argument", so it is passed only where it exists.
objc_literal_flag=
if clang -target x86_64-apple-darwin -fno-objc-constant-literals -x objective-c -fsyntax-only /dev/null 2>/dev/null; then
  objc_literal_flag=-fno-objc-constant-literals
fi
clang -target x86_64-apple-darwin -fuse-ld=lld \
  -isysroot "$sysroot" -mmacosx-version-min=11.0 \
  -O2 -fno-omit-frame-pointer -dynamiclib -fno-objc-arc $objc_literal_flag -Werror=incompatible-function-pointer-types \
  -Wl,-undefined,dynamic_lookup \
  -install_name @rpath/libMacNCheeseShims.dylib \
  "$src_dir/libMacNCheeseShims.m" "$src_dir/xattr_compat.c" "$src_dir/exit_compat.c" "$src_dir/missing_symbols.c" "$src_dir/net_trace.c" "$src_dir/darling_fixes.c" "$src_dir/thread_kick.c" "$src_dir/xfixes_raw.c" "$src_dir/raw_mouse.c" "$src_dir/cursor_overlay.c" "$src_dir/worker_wake.c" "$src_dir/shader_compat.c" "$src_dir/mangohud_bridge.c" "$src_dir/dns_override.c" "$src_dir/audio_hal.c" "$src_dir/gpu_info.c" "$src_dir/power_info.c" "$src_dir/layer_image.c" "$src_dir/gl_profile.c" "$src_dir/graphics_context.c" "$src_dir/wayland_appkit.m" "$src_dir/connectx_compat.c" "$src_dir/memory_stats.c" "$src_dir/web_bridge.m" "$build_dir/fast_libc.o" \
  -lobjc -lc++ -lc++abi -framework Foundation -framework AppKit -framework WebKit -framework Metal \
  -o "$tmp_output"
chmod 755 "$tmp_output"
mv -- "$tmp_output" "$build_dir/libMacNCheeseShims.dylib"
printf 'Built: %s\n' "$build_dir/libMacNCheeseShims.dylib"

# Frameworks RobloxPlayer links that Darling does not have (see frameworks/).
# The launcher copies them into the Darling prefix.
for name in CoreML CoreHaptics DeviceCheck; do
  framework="$build_dir/frameworks/$name.framework"
  mkdir -p "$framework/Versions/A"
  clang -target x86_64-apple-darwin -fuse-ld=lld \
    -isysroot "$sysroot" -mmacosx-version-min=11.0 \
    -dynamiclib -fno-objc-arc \
    -install_name "/System/Library/Frameworks/$name.framework/Versions/A/$name" \
    "$project_dir/frameworks/$name.m" -lobjc -framework CoreFoundation \
    -o "$framework/Versions/A/$name"
  ln -sfn A "$framework/Versions/Current"
  ln -sfn "Versions/Current/$name" "$framework/$name"
done
printf 'Built: %s\n' "$build_dir/frameworks"
