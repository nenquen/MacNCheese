"""Window backend selection; native Wayland remains an explicit experiment."""
import ctypes
import json
import math
import os
import re
import subprocess
import xml.etree.ElementTree as ET
from pathlib import Path


def validated_dpi_scale(value):
    """Roblox UI scale; invalid stored/direct values use the 100% default."""
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        return 1.0
    try:
        scale = float(value)
    except (OverflowError, ValueError):
        return 1.0
    return scale if math.isfinite(scale) and 1.0 <= scale <= 4.0 else 1.0


def _valid_detected(value):
    """A detected system scale is only useful inside the supported range."""
    try:
        scale = float(value)
    except (TypeError, ValueError, OverflowError):
        return None
    if not math.isfinite(scale) or scale < 1.0 or scale > 4.0:
        return None
    return round(scale, 2)


def _env_override(env):
    """Explicit user overrides (GDK_SCALE, QT_SCALE_FACTOR, per-screen list)."""
    candidates = []
    for key in ("GDK_SCALE", "QT_SCALE_FACTOR"):
        value = (env.get(key) or "").strip()
        if value:
            candidates.append(value.split(";")[0].split(",")[0].strip())
    factors = (env.get("QT_SCREEN_SCALE_FACTORS") or "")
    for part in factors.replace(",", ";").split(";"):
        candidates.append(part.split("=")[-1].strip())
    valid = [_valid_detected(v) for v in candidates if v]
    valid = [v for v in valid if v is not None]
    return max(valid) if valid else None


def _kde_scale(run, read):
    """KDE Plasma 6: kscreen-doctor output, else kwinoutputconfig.json."""
    try:
        output = run(["kscreen-doctor", "-o"], timeout=5)
    except (OSError, subprocess.SubprocessError):
        output = ""
    scales = [_valid_detected(m.group(1))
              for m in re.finditer(r"Scale:\s*([0-9]+(?:\.[0-9]+)?)", output or "")]
    scales = [s for s in scales if s is not None]
    if scales:
        return max(scales)
    try:
        config = json.loads(read(Path.home() / ".config" / "kwinoutputconfig.json") or "")
    except (OSError, ValueError, TypeError):
        return None
    try:
        outputs = config.get("outputs", []) if isinstance(config, dict) else []
        scales = [_valid_detected(o.get("scale")) for o in outputs
                  if isinstance(o, dict)]
    except (AttributeError, TypeError):
        return None
    scales = [s for s in scales if s is not None]
    return max(scales) if scales else None


def _gnome_scale(run, read):
    """GNOME: monitors.xml active scale, else the integer scaling-factor."""
    try:
        xml_text = read(Path.home() / ".config" / "monitors.xml")
    except OSError:
        xml_text = None
    if xml_text:
        try:
            root = ET.fromstring(xml_text)
            scales = [_valid_detected(node.text)
                      for node in root.iter("scale")]
            scales = [s for s in scales if s is not None]
            if scales:
                return max(scales)
        except ET.ParseError:
            pass
    try:
        output = run(["gsettings", "get", "org.gnome.desktop.interface",
                      "scaling-factor"], timeout=5)
    except (OSError, subprocess.SubprocessError):
        return None
    match = re.search(r"uint32\s+(\d+)", output or "")
    return _valid_detected(match.group(1)) if match else None


def _xft_scale(run):
    """X11 fallback: Xft.dpi from the resource database (96 = 100%)."""
    try:
        output = run(["xrdb", "-query"], timeout=5)
    except (OSError, subprocess.SubprocessError):
        return None
    match = re.search(r"Xft\.dpi:\s*([0-9]+(?:\.[0-9]+)?)", output or "")
    if not match:
        return None
    scale = _valid_detected(float(match.group(1)) / 96.0)
    return scale if scale is not None and scale > 1.0 else None


def detect_system_scale(env=None, run=None, read=None):
    """Best-effort desktop scale factor for pre-filling Roblox UI scale.

    Priority: explicit toolkit overrides, then the running desktop
    (KDE/GNOME), then Xft.dpi. Never raises; unknown setups return 1.0.
    Only a suggestion: stored settings always win (see complete_setup).
    """
    env = os.environ if env is None else env
    if run is None:
        def run(cmd, timeout=5):
            try:
                result = subprocess.run(cmd, capture_output=True, text=True,
                                        timeout=timeout)
            except (OSError, subprocess.SubprocessError):
                return ""
            return result.stdout if result.returncode == 0 else ""
    if read is None:
        def read(path):
            try:
                return Path(path).read_text()
            except OSError:
                return None
    try:
        override = _env_override(env)
        if override is not None:
            return override
        desktop = (env.get("XDG_CURRENT_DESKTOP") or "").lower()
        if "kde" in desktop:
            scale = _kde_scale(run, read)
            if scale is not None:
                return scale
        elif "gnome" in desktop:
            scale = _gnome_scale(run, read)
            if scale is not None:
                return scale
        else:
            for probe in (_kde_scale, _gnome_scale):
                scale = probe(run, read)
                if scale is not None:
                    return scale
        return _xft_scale(run) or 1.0
    except Exception:
        return 1.0


def window_environment(settings, helper):
    backend = settings.get("display_backend", "x11")
    if os.environ.get("MACNCHEESE_WAYLAND") == "1":
        backend = "wayland"
    if backend == "x11":
        return {"MACNCHEESE_WAYLAND": "0", "EGL_PLATFORM": "x11"}
    if backend != "wayland":
        raise ValueError(f"Unknown window backend: {backend}")
    if not os.environ.get("WAYLAND_DISPLAY"):
        raise RuntimeError("Experimental Wayland requires a Wayland desktop session. Select X11 in Settings.")
    if not Path(helper).is_file():
        raise RuntimeError("The experimental Wayland helper is missing. Install SDL2/Wayland development libraries and rebuild, or select X11.")
    values = {"MACNCHEESE_WAYLAND": "1", "EGL_PLATFORM": "wayland",
              "MACNCHEESE_WAYLAND_HELPER": str(helper)}
    if settings.get("renderer", "opengl") == "vulkan":
        from .graphics import wayland_vulkan_environment
        values.update(wayland_vulkan_environment())
    return values


class WaylandProbeWindow:
    """The same Linux helper and EGL surface used by the experimental client."""
    def __init__(self):
        pointer, uint, integer = ctypes.c_void_p, ctypes.c_uint, ctypes.c_int
        display = ctypes.CFUNCTYPE(pointer)
        create = ctypes.CFUNCTYPE(uint, integer, integer)
        surface = ctypes.CFUNCTYPE(pointer, uint)
        action = ctypes.CFUNCTYPE(None, uint, integer, ctypes.c_double, ctypes.c_double, ctypes.c_char_p)
        error = ctypes.CFUNCTYPE(ctypes.c_char_p)
        create_subwindow = ctypes.CFUNCTYPE(uint, uint, integer, integer, integer, integer)
        subwindow_frame = ctypes.CFUNCTYPE(None, uint, integer, integer, integer, integer)
        subwindow_visible = ctypes.CFUNCTYPE(None, uint, integer)
        destroy_subwindow = ctypes.CFUNCTYPE(None, uint)

        class API(ctypes.Structure):
            _fields_ = [("version", uint), ("display", display), ("create", create),
                        ("surface", surface), ("action", action), ("poll", pointer),
                        ("screen", pointer), ("cursor", pointer), ("clipboard", pointer),
                        ("error", error), ("create_subwindow", create_subwindow),
                        ("subwindow_surface", surface), ("subwindow_frame", subwindow_frame),
                        ("subwindow_visible", subwindow_visible), ("destroy_subwindow", destroy_subwindow)]

        self.library = ctypes.CDLL(os.environ["MACNCHEESE_WAYLAND_HELPER"])
        get_api = self.library.macncheese_wayland_host_api
        get_api.restype = ctypes.POINTER(API)
        value = get_api()
        # Check only the ABI header before reading newly added function slots.
        if not value or ctypes.cast(value, ctypes.POINTER(uint)).contents.value != 3:
            raise RuntimeError("Experimental Wayland helper failed to initialize or is outdated. Rebuild MacNCheese before using Native Wayland.")
        self.api = value.contents
        self.native = self.api.display()
        self.children = set()
        self.handle = self.api.create(16, 16)
        try:
            self.drawable = self.create_drawable(0, 0, 16, 16) if self.handle else 0
        except Exception:
            self.close()
            raise
        self.surface = self.api.subwindow_surface(self.drawable) if self.drawable else None
        if not self.native or not self.surface:
            self.close()
            raise RuntimeError((self.api.error() or b"Wayland test window failed").decode(errors="replace"))

    def create_drawable(self, x, y, width, height):
        handle = self.api.create_subwindow(self.handle, x, y, width, height)
        if not handle:
            raise RuntimeError((self.api.error() or b"Wayland test view failed").decode(errors="replace"))
        self.children.add(handle)
        return handle

    def destroy_drawable(self, handle):
        if handle in self.children:
            self.api.destroy_subwindow(handle)
            self.children.remove(handle)

    def close(self):
        for handle in tuple(self.children):
            self.destroy_drawable(handle)
        if self.handle:
            self.api.action(self.handle, 10, 0, 0, None)  # MW_DESTROY
            self.handle = 0
