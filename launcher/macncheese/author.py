"""Author card and community links for the Info page. No GTK here."""

import json
import time
import urllib.error
import urllib.request

from . import core

NAME = "Narezany"
ROBLOX_USER = "H4Ru_456"
ROBLOX_ID = 8847914296
PROFILE_URL = f"https://www.roblox.com/users/{ROBLOX_ID}/profile"
DISCORD_URL = "https://discord.gg/jCjHYYNq48"
GITHUB_URL = "https://github.com/nenquen/MacNCheese"

# Maintainer of this version; the picture ships with the launcher.
MAINTAINER = "nenquen"
MAINTAINER_URL = "https://github.com/nenquen"
MAINTAINER_AVATAR = core.PROJECT / "branding" / "contributors" / "nenquen.png"

UI_CONTRIBUTOR = "TinyTosha"
UI_CONTRIBUTOR_URL = "https://github.com/amethyst-bin"
UI_CONTRIBUTOR_AVATAR = core.CACHE_DIR / "tinytosha-avatar.png"
TINYTOSHA_AVATAR_URL = "https://avatars.githubusercontent.com/u/259899852"

AVATAR = core.CACHE_DIR / "author-avatar.png"
THUMBNAIL_API = ("https://thumbnails.roblox.com/v1/users/avatar-headshot"
                 f"?userIds={ROBLOX_ID}&size=150x150&format=Png&isCircular=false")


def avatar(settings, max_age=86400):
    """Path to the cached avatar headshot, refreshed once a day. Returns the
    old copy (or None) when Roblox is unreachable."""
    try:
        if time.time() - AVATAR.stat().st_mtime < max_age:
            return AVATAR
    except OSError:
        pass
    try:
        info = json.loads(_get(THUMBNAIL_API))
        image = _get(info["data"][0]["imageUrl"])
        if not image.startswith(b"\x89PNG"):
            raise ValueError("not a PNG")
        core.CACHE_DIR.mkdir(parents=True, exist_ok=True)
        partial = AVATAR.with_suffix(".part")
        partial.write_bytes(image)
        partial.replace(AVATAR)
    except (OSError, ValueError, KeyError, IndexError):
        pass
    return AVATAR if AVATAR.exists() else None


def tinytosha_avatar(max_age=86400):
    """Path to the cached GitHub avatar for TinyTosha, refreshed once a day."""
    try:
        if time.time() - UI_CONTRIBUTOR_AVATAR.stat().st_mtime < max_age:
            return UI_CONTRIBUTOR_AVATAR
    except OSError:
        pass
    try:
        req = urllib.request.Request(TINYTOSHA_AVATAR_URL, headers={"User-Agent": "MacNCheese"})
        with urllib.request.urlopen(req, timeout=5) as response:
            image = response.read()
        core.CACHE_DIR.mkdir(parents=True, exist_ok=True)
        partial = UI_CONTRIBUTOR_AVATAR.with_suffix(".part")
        partial.write_bytes(image)
        partial.replace(UI_CONTRIBUTOR_AVATAR)
    except (OSError, urllib.error.URLError):
        pass
    return UI_CONTRIBUTOR_AVATAR if UI_CONTRIBUTOR_AVATAR.exists() else None
