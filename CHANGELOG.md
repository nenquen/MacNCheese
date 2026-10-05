# Release notes

## 0.19 — 2026-10-04

### Bug fixes and settings

- Fix invisible X11 cursors with Vulkan (Zink), including fast image creation,
  cursor changes and recreated drawable windows.
- Allow independent Darwin DNS lookups to run concurrently instead of waiting
  behind one slow lookup. Retain serialized fallback when resolver isolation
  cannot be confirmed.
- Add **Roblox UI scale** in Game settings, from 100–400%. The `dpi_scale`
  setting now reaches Roblox; 200% enlarges its interface while preserving the
  rendering resolution. Default scaling stays at 100%.
- Stop adding `DFFlagDisableDPIScale` through the texture-quality preset.
  Existing custom flags are preserved; remove that flag to use UI scaling.
- Preserve the Flatpak Mesa driver discovery improvements and show useful
  Vulkan probe failures without inheriting Darling's preload library.

### Experimental Wayland

- Give concurrent AppKit views separate EGL drawables; repair resizing,
  hide/show and drawable lifetime handling.
- Repair recursive window lookup and display initialization cleanup.
- Improve NVIDIA Vulkan discovery without X11, while preserving explicit
  Vulkan driver selections and filters.
- Keep Native Wayland opt-in and experimental; X11 / Xwayland stays the default.

### Verification and remaining work

The native shim and helper built successfully. Sixteen compiled regression
fixtures and 99 Python tests passed. Actual Darling/X11 cursor and concurrent
DNS fixtures passed. The production UI scaling wrapper visibly enlarged the
actual Roblox interface at 200%; scaled click alignment still needs an
end-to-end check. Hardware EGL, shared contexts and Wayland window lifecycle
fixtures passed, but full native Wayland client presentation is not verified.

The pause after leaving a game remains unresolved; a focused client reproduced
an approximately 14-second frame gap. Intermittent Vulkan stutters, direct
client Vulkan and the other user's exact crash remain under investigation.
Vulkan rendering still uses Mesa Zink. Custom Darlingserver multiworker builds
are isolated experiments and are not included in this release.
The Flatpak is a testing package; this release does not claim new Flatpak
gameplay verification.

## 0.18 — 2026-10-04

### Setup

- The terminal installer now welcomes you, explains its destination and system
  packages, shows four installation steps, and gives clear next steps.
- First launch has a welcome, installation overview, download progress, retry
  screen and sign-in guidance. Reopen it from **Setup guide** in the menu.
- Existing installations keep their settings and Roblox session. Source updates
  back up local changes before replacing tracked files and preserve other files.

### Bug fixes

- Fix raw mouse and right-click camera freezes caused by synchronous modifier
  queries. Bound event processing and preserve mouse deltas and button events.
- Restore requested mouse capture after Alt-Tab or another focus change.
- Fix crashes while rendering Private Servers and other embedded pages; improve
  browser bridge timeouts and page closure handling.
- Improve Zink context switching, drawable handling, shader compatibility,
  GPU memory reporting and frame pacing.
- Reduce Darling file-close cleanup costs during the initial leave-game
  transition. Repair event wakeups and lock error handling.
- Keep cleanup within the selected Darling prefix and use stable process
  handles to avoid affecting other app environments.

### Verification and remaining work

The repaired input, focus, Private Servers and initial leave transition were
checked with the actual macOS client on an RTX 3060 Ti using Xwayland. Native
regressions and mocked launcher/process regressions passed. The installer and
setup changes received syntax/build checks and a local visual preview; system
package installation was not repeated for this release.

A later approximately 10–11 second pause after leaving a game is still under
investigation. Intermittent graphics stutters need more gameplay measurements.
Vulkan gameplay still uses Mesa Zink; the Metal-to-Vulkan work is a prototype.
Native Wayland is an opt-in experimental feature and is not complete.
