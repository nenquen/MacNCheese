"""Discord Rich Presence for MacOBlox over Discord IPC Unix sockets."""

from __future__ import annotations

import json
import logging
import os
import re
import socket
import struct
import threading
import time
import urllib.request
import uuid
from pathlib import Path

log = logging.getLogger("macoblox.discord")

CLIENT_ID = "1468188794309050523"

CACHE_FILE = (
    Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local" / "share"))
    / "MacOBlox"
    / "game_cache.json"
)

_GAME_CACHE: dict[int, dict] = {}


def _load_cache():
    global _GAME_CACHE
    try:
        if CACHE_FILE.exists():
            with open(CACHE_FILE, "r", encoding="utf-8") as f:
                raw = json.load(f)
                _GAME_CACHE = {int(k): v for k, v in raw.items()}
    except Exception as e:
        log.debug("Failed to load game cache: %s", e)


def _save_cache():
    try:
        CACHE_FILE.parent.mkdir(parents=True, exist_ok=True)
        with open(CACHE_FILE, "w", encoding="utf-8") as f:
            json.dump({str(k): v for k, v in _GAME_CACHE.items()}, f)
    except Exception as e:
        log.debug("Failed to save game cache: %s", e)


_load_cache()


def fetch_game_info(place_id: int, universe_id: int | None = None) -> dict | None:
    """Fetch experience title, creator, and icon from public Roblox APIs."""
    if place_id in _GAME_CACHE:
        return _GAME_CACHE[place_id]

    try:
        if not universe_id:
            req = urllib.request.Request(
                f"https://apis.roblox.com/universes/v1/places/{place_id}/universe",
                headers={"User-Agent": "Mozilla/5.0"}
            )
            with urllib.request.urlopen(req, timeout=5) as resp:
                data = json.loads(resp.read().decode("utf-8"))
                universe_id = data.get("universeId")

        if not universe_id:
            return None

        req = urllib.request.Request(
            f"https://games.roblox.com/v1/games?universeIds={universe_id}",
            headers={"User-Agent": "Mozilla/5.0"}
        )
        with urllib.request.urlopen(req, timeout=5) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            entries = data.get("data", [])
            if not entries:
                return None
            entry = entries[0]
            name = entry.get("name", "Roblox")
            creator = entry.get("creator", {}).get("name", "")

        icon_url = None
        try:
            req_icon = urllib.request.Request(
                f"https://thumbnails.roblox.com/v1/games/icons?universeIds={universe_id}&returnPolicy=PlaceHolder&size=512x512&format=Png&isCircular=false",
                headers={"User-Agent": "Mozilla/5.0"}
            )
            with urllib.request.urlopen(req_icon, timeout=5) as resp:
                idata = json.loads(resp.read().decode("utf-8"))
                ientries = idata.get("data", [])
                if ientries and ientries[0].get("imageUrl"):
                    icon_url = ientries[0]["imageUrl"]
        except Exception:
            pass

        info = {
            "place_id": place_id,
            "universe_id": universe_id,
            "name": name,
            "creator": creator,
            "icon_url": icon_url,
        }
        _GAME_CACHE[place_id] = info
        _save_cache()
        return info
    except Exception as e:
        log.debug("Failed to fetch game info for place %s: %s", place_id, e)
        return None


class GameActivityTracker:
    """Watches the active Roblox launch log to detect experience joins/leaves."""

    def __init__(self, log_path: Path, on_change):
        self.log_path = log_path
        self.on_change = on_change
        self.running = True
        self.current_place_id: int | None = None
        self.current_universe_id: int | None = None
        self._resolve_thread: threading.Thread | None = None
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()

    def stop(self):
        self.running = False

    def _resolve_in_background(self, place_id: int, universe_id: int | None):
        def _worker():
            for attempt in range(6):
                if not self.running or self.current_place_id != place_id:
                    return
                info = fetch_game_info(place_id, universe_id)
                if info:
                    if self.running and self.current_place_id == place_id:
                        self.on_change(info)
                    return
                time.sleep(1.0 + attempt * 0.5)

        self._resolve_thread = threading.Thread(target=_worker, daemon=True)
        self._resolve_thread.start()

    def _run(self):
        join_re = re.compile(
            r"!\s*Joining game\s+['\"][^'\"]*['\"]\s+place\s+(\d+)|"
            r"GameJoinUtil::joinGamePost.*BODY:.*[\"']placeId[\"']:\s*(\d+)|"
            r"status code:.*[\"']PlaceId[\"']:\s*(\d+)|"
            r"Report game_join_loadtime:.*placeid:(\d+)",
            re.IGNORECASE
        )
        uid_re = re.compile(
            r"[\"']UniverseId[\"']:\s*(\d+)|"
            r"universeid:(\d+)",
            re.IGNORECASE
        )
        leave_re = re.compile(
            r"leaveUGCGame|returnToLuaApp|stage:LuaApp|destroyCaptureModeDataModelIfExists|Destroying MegaReplicator",
            re.IGNORECASE
        )

        last_pos = 0
        universe_id = None

        while self.running:
            if not self.log_path.exists():
                time.sleep(0.5)
                continue
            try:
                with open(self.log_path, "rb") as f:
                    f.seek(last_pos)
                    chunk = f.read()
                    if chunk:
                        idx = chunk.rfind(b"\n")
                        if idx != -1:
                            raw_lines = chunk[:idx + 1]
                            last_pos += idx + 1
                            lines = raw_lines.decode("utf-8", errors="replace").splitlines()
                            for line in lines:
                                if not self.running:
                                    break

                                um = uid_re.search(line)
                                if um:
                                    for g in um.groups():
                                        if g:
                                            universe_id = int(g)
                                            break

                                jm = join_re.search(line)
                                if jm:
                                    place_id = None
                                    for g in jm.groups():
                                        if g:
                                            place_id = int(g)
                                            break
                                    if place_id and place_id != self.current_place_id:
                                        self.current_place_id = place_id
                                        self.current_universe_id = universe_id
                                        cached = _GAME_CACHE.get(place_id)
                                        if cached:
                                            self.on_change(cached)
                                        else:
                                            self.on_change({"place_id": place_id, "name": "Roblox", "loading": True})
                                            self._resolve_in_background(place_id, universe_id)
                                    continue

                                if self.current_place_id is not None and leave_re.search(line):
                                    self.current_place_id = None
                                    self.current_universe_id = None
                                    universe_id = None
                                    if self.running:
                                        self.on_change(None)
            except Exception as e:
                log.debug("Log tracker error: %s", e)
            time.sleep(0.5)


class DiscordRPC:
    """Manages connection to local Discord client and Rich Presence updates."""

    def __init__(self, client_id: str = CLIENT_ID):
        self.client_id = client_id
        self.sock: socket.socket | None = None
        self._connected = False

    def _find_socket(self) -> list[str]:
        candidates = []
        uid = os.getuid()
        runtime = os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{uid}")
        for base in (runtime, os.environ.get("TMPDIR", "/tmp"), "/tmp"):
            if not base or not os.path.isdir(base):
                continue
            for i in range(10):
                path = os.path.join(base, f"discord-ipc-{i}")
                if os.path.exists(path):
                    candidates.append(path)
        return candidates

    def _read_exact(self, s: socket.socket, length: int) -> bytes | None:
        """Read exactly `length` bytes from socket. Returns None if EOF or error."""
        buf = bytearray()
        while len(buf) < length:
            try:
                chunk = s.recv(length - len(buf))
                if not chunk:
                    return None
                buf.extend(chunk)
            except Exception:
                return None
        return bytes(buf)

    def connect(self) -> bool:
        if self._connected and self.sock:
            return True
        for path in self._find_socket():
            s: socket.socket | None = None
            try:
                s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                s.settimeout(2.0)
                s.connect(path)
                # Opcode 0: Handshake
                payload = json.dumps({"v": 1, "client_id": self.client_id}).encode("utf-8")
                s.sendall(struct.pack("<II", 0, len(payload)) + payload)
                hdr = self._read_exact(s, 8)
                if hdr and len(hdr) == 8:
                    _op, length = struct.unpack("<II", hdr)
                    body = self._read_exact(s, length)
                    if body:
                        data = json.loads(body.decode("utf-8"))
                        if data.get("cmd") == "DISPATCH" and data.get("evt") == "READY":
                            self.sock = s
                            self._connected = True
                            log.info("Connected to Discord IPC on %s", path)
                            return True
                s.close()
            except Exception as e:
                log.debug("Failed connecting to %s: %s", path, e)
                if s:
                    try:
                        s.close()
                    except Exception:
                        pass
        return False

    def update_presence(
        self,
        details: str = "Playing Roblox",
        state: str | None = None,
        start_time: float | None = None,
        large_image: str = "macoblox",
        large_text: str = "Mac O’ Blox",
        small_image: str | None = None,
        small_text: str | None = None,
    ) -> bool:
        if not self._connected:
            if not self.connect():
                return False
        assets: dict = {
            "large_image": large_image,
            "large_text": large_text,
        }
        if small_image:
            assets["small_image"] = small_image
            if small_text:
                assets["small_text"] = small_text
        activity: dict = {
            "details": details,
            "assets": assets,
        }
        if state:
            activity["state"] = state
        if start_time:
            activity["timestamps"] = {"start": int(start_time)}
        message = {
            "cmd": "SET_ACTIVITY",
            "args": {
                "pid": os.getpid(),
                "activity": activity,
            },
            "nonce": str(uuid.uuid4()),
        }
        try:
            payload = json.dumps(message).encode("utf-8")
            assert self.sock is not None
            self.sock.sendall(struct.pack("<II", 1, len(payload)) + payload)
            hdr = self._read_exact(self.sock, 8)
            if hdr and len(hdr) == 8:
                _op, length = struct.unpack("<II", hdr)
                self._read_exact(self.sock, length)
            return True
        except Exception as e:
            log.debug("Failed to send presence: %s", e)
            self.close()
            return False

    def clear_presence(self):
        if not self._connected or not self.sock:
            return
        try:
            message = {
                "cmd": "SET_ACTIVITY",
                "args": {
                    "pid": os.getpid(),
                    "activity": None,
                },
                "nonce": str(uuid.uuid4()),
            }
            payload = json.dumps(message).encode("utf-8")
            self.sock.sendall(struct.pack("<II", 1, len(payload)) + payload)
            hdr = self._read_exact(self.sock, 8)
            if hdr and len(hdr) == 8:
                _op, length = struct.unpack("<II", hdr)
                self._read_exact(self.sock, length)
        except Exception:
            pass

    def close(self):
        self.clear_presence()
        self._connected = False
        if self.sock:
            try:
                self.sock.close()
            except Exception:
                pass
            self.sock = None
