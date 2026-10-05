# Mac'n Cheese AppImage (native TUI binary + shim sources)

The AppImage ships the Rust TUI launcher and the shim sources (built on
first launch against the system's Darling sysroot). No Python, no GTK,
no bundled libraries: the binary only needs the host libc and terminal.

Darling stays installed on the system: it needs setuid-root, a mount
namespace and overlayfs, none of which work from inside an AppImage
(FUSE mounts are `nosuid`). The AppRun refuses to start the game
without Darling and points at the installer instead.

## Build

```bash
cd packaging/appimage
./build-appimage.sh        # produces MacNCheese-x86_64.AppImage
```

Needs `cargo` and network (uruntime fetch, crates.io). The result is
~15 MB and runs anywhere with a compatible glibc.
