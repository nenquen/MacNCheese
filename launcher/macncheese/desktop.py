"""Desktop integration: look native on GNOME and on Qt-based desktops.

Ghostty-grade behavior without a second UI toolkit: follow the system
color scheme live (portal Settings, so KDE dark mode just works), use the
system interface font instead of Cantarell, and keep everything else stock
libadwaita. File dialogs are already portal-native (FileChooserNative).
"""
import configparser
import re
import subprocess
from pathlib import Path


def _gsettings(key):
    try:
        result = subprocess.run(
            ["gsettings", "get", "org.gnome.desktop.interface", key],
            capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return None
    if result.returncode != 0:
        return None
    return result.stdout.strip().strip("'\"")


def _kde_config():
    path = Path.home() / ".config" / "kdeglobals"
    parser = configparser.ConfigParser()
    try:
        with open(path, encoding="utf-8") as file:
            parser.read_file(file)
    except OSError:
        return None
    if not parser.has_section("General"):
        return None
    return dict(parser.items("General"))


def system_color_scheme(env=None, gsettings=_gsettings, kde_config=_kde_config,
                        portal=None):
    """'dark', 'light' or None (unknown: let libadwaita decide)."""
    import os
    env = os.environ if env is None else env
    if portal is None:
        portal = _portal_appearance()
    if portal:
        # 0 = no preference, 1 = dark, 2 = light.
        scheme = portal.get("color-scheme")
        if scheme == 1:
            return "dark"
        if scheme == 2:
            return "light"
    desktop = (env.get("XDG_CURRENT_DESKTOP") or "").lower()
    if "gnome" in desktop or not desktop:
        value = gsettings("color-scheme")
        if value == "prefer-dark":
            return "dark"
        if value in ("prefer-light", "default"):
            return "light" if value == "prefer-light" else None
    if "kde" in desktop or not desktop:
        general = kde_config()
        if general:
            scheme = (general.get("colorscheme", "") or "").lower()
            if "dark" in scheme:
                return "dark"
            if scheme:
                return "light"
    return None


def _portal_appearance():
    """org.freedesktop.appearance dict via the XDG Settings portal."""
    try:
        from gi.repository import Gio
        bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        result = bus.call_sync(
            "org.freedesktop.portal.Desktop",
            "/org/freedesktop/portal/desktop",
            "org.freedesktop.portal.Settings", "Read",
            GLib_Variant("(ss)", ("org.freedesktop.appearance", "color-scheme")),
            None, Gio.DBusCallFlags.NONE, 2000, None)
        return {"color-scheme": result.unpack()[0]}
    except Exception:
        return {}


def GLib_Variant(fmt, value):
    from gi.repository import GLib
    return GLib.Variant(fmt, value)


def system_font(env=None, gsettings=_gsettings, kde_config=_kde_config):
    """(family, size_pt) of the desktop interface font, or None."""
    import os
    env = os.environ if env is None else env
    desktop = (env.get("XDG_CURRENT_DESKTOP") or "").lower()
    if "kde" in desktop or not desktop:
        general = kde_config()
        if general and general.get("font"):
            # "Noto Sans,10,-1,5,400,0,0,0,0,0,0,0,0,0,0,1"
            parts = general["font"].split(",")
            family = parts[0].strip()
            size = _valid_size(parts[1] if len(parts) > 1 else "")
            if family:
                return family, size
    if "gnome" in desktop or not desktop:
        value = gsettings("font-name")  # e.g. "Cantarell 11"
        match = re.match(r"(.+?)\s+(\d+(?:\.\d+)?)$", (value or "").strip())
        if match:
            return match.group(1), _valid_size(match.group(2))
    return None


def _valid_size(value):
    try:
        size = float(value)
    except (TypeError, ValueError):
        return 11.0
    return size if 6.0 <= size <= 32.0 else 11.0


def font_css(family, size):
    """Minimal CSS: interface font only, Adwaita metrics untouched."""
    safe = re.sub(r"[^0-9A-Za-z \-]", "", family) or "sans-serif"
    return f"* {{ font-family: '{safe}'; font-size: {size:.1f}pt; }}"


def watch_color_scheme(callback):
    """Call callback('dark'/'light'/None) when the portal setting changes."""
    try:
        from gi.repository import Gio
        bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)

        def _on_signal(_conn, _sender, _path, _iface, _signal, params):
            namespace, name, _value = params.unpack()
            if namespace == "org.freedesktop.appearance" and name == "color-scheme":
                callback(system_color_scheme())
        bus.signal_subscribe("org.freedesktop.portal.Desktop",
                             "org.freedesktop.portal.Settings",
                             "SettingChanged",
                             "/org/freedesktop/portal/desktop",
                             None, Gio.DBusSignalFlags.NONE, _on_signal)
        return True
    except Exception:
        return False
