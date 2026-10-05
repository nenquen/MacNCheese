# Mac'n Cheese AppImage (experimental, launcher only)

The AppImage ships **only the launcher** (Python + GTK4/libadwaita +
WebKitGTK). Darling stays installed on the system: it needs setuid-root,
a mount namespace and overlayfs, none of which work from inside an
AppImage (FUSE mounts are `nosuid`). The AppRun refuses to start the game
without Darling and points at the installer instead.

Why launcher-only and not everything-in-one-file:

- Darling cannot live in an AppImage (see above); Flatpak solves the same
  problem with path rewrites + `darling-noroot.so`, which is not portable
  across hosts with different user-namespace/overlayfs permissions.
- GPU drivers (Mesa DRI, libGL/EGL, Vulkan ICDs, NVIDIA userspace) must
  always come from the host, or the Zink probe in `graphics.py` tests the
  wrong driver. They are explicitly excluded below.

## Build (needs network, ~1 GB work dir)

```bash
cd packaging/appimage
./build-appimage.sh        # produces MacNCheese-x86_64.AppImage
./build-appimage.sh --run  # ...and smoke-tests: --help + settings load
```

What the script does:

1. Fetches `sharun` + `quick-sharun.sh` (pkgforge) and `uruntime`.
2. Stages `AppDir` with the repo's `launcher/`, `branding/`, `shim/`
   (sources only; the shim is rebuilt on first launch against the
   system's Darling sysroot, same as a source install).
3. Runs `quick-sharun.sh` in strace mode against
   `python3 launcher/macncheese-launcher --help` to collect Python, GTK4,
   libadwaita, WebKitGTK 6.0, Soup, GSettings schemas, gdk-pixbuf
   loaders and GIO modules.
4. Post-deploy cleanup (the important part):
   - deletes bundled `dri/`, `libGL*`, `libEGL*`, `libGLES*`,
     `libvulkan*`, `*.icd.json` so the host GL/Vulkan stack is used;
   - keeps WebKitGTK helper processes next to the libraries with
     relative symlinks (WebKit bakes absolute helper paths in);
   - writes `.env` (`GSETTINGS_SCHEMA_DIR`, `GDK_PIXBUF_*`, `GIO_MODULE_DIR`,
     `GI_TYPELIB_PATH`, `FONTCONFIG_FILE`, `XDG_DATA_DIRS`) and `AppRun`.
5. Packs the AppDir with `uruntime` into a single file.

## Known risks (untested on real hardware yet)

- WebKitGTK 6.0 helper paths: proven recipe exists for 4.x, not 6.0.
  If the in-app browser stays blank, run with `WEBKIT_DEBUG=all` and
  compare helper paths against `shared/bin`.
- The shim build inside an AppImage session inherits the AppImage env;
  `build_debug_shim.sh` must still see the host clang/lld/pkg-config.
  The script scrubs `LD_LIBRARY_PATH` leakage for the build step.
