"""Roblox's embedded web pages, shown in a WebKit window of the launcher.

Roblox's macOS client opens web views for signing in with a password (and
its captcha), purchases and account pages. Darling's WebKit is a stub, so the
shim (web_bridge.m) forwards those views over a Unix socket to this bridge,
which shows them with WebKitGTK. The protocol is JSON, one object per line:
the game sends requests ({"op": ...}), this side events ({"event": ...}).
It is the protocol of spidercraft's Roblox Mac Linux Port
(runtime/browser/host.cpp), adapted with their permission.
"""

import json
import os
import socket
import urllib.parse

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gdk, GLib, Gtk  # noqa: E402

from . import core  # noqa: E402
from .i18n import _  # noqa: E402

GUEST_PREFIX = "/Volumes/SystemRoot"  # the host filesystem as the game sees it


def _webkit():
    """WebKit and Soup, imported on first use (an optional dependency)."""
    if "X11" in type(Gdk.Display.get_default()).__name__:
        # WebKit's DMA-BUF renderer fails on X11 with NVIDIA's driver.
        os.environ.setdefault("WEBKIT_DISABLE_DMABUF_RENDERER", "1")
    gi.require_version("WebKit", "6.0")
    gi.require_version("Soup", "3.0")
    from gi.repository import Soup, WebKit
    return WebKit, Soup


def _web_url(url):
    """Only plain http(s) pages with a host and no credentials are shown."""
    if not isinstance(url, str) or len(url) > 16384 or any(ord(c) < 32 or ord(c) == 127 for c in url):
        return False
    try:
        parts = urllib.parse.urlsplit(url)
        return parts.scheme in ("http", "https") and bool(parts.hostname) and "@" not in parts.netloc
    except ValueError:
        return False


def _client_url(url):
    """roblox:// links belong to the running client, never to a browser."""
    lower = url.lower() if isinstance(url, str) else ""
    return (lower.startswith("roblox:") and len(lower) > 7) or \
        (lower.startswith("roblox-player:") and len(lower) > 14)


def _compatible_user_agent(agent):
    """Roblox's user agent, as WebKitGTK accepts it. Apple's WebKit takes
    Roblox's concatenated products; WebKitGTK's parser rejects the second
    slash and keeps its desktop agent. Pages must also pick their macOS
    bridge, not a Linux fallback, so app-tagged agents get a Mac platform."""
    result = agent or ""
    result = result.replace("Roblox/DarwinRobloxApp/", "Roblox/Darwin RobloxApp/")
    if "RobloxApp/" in result:
        result = result.replace("(X11; Linux x86_64)", "(Macintosh; Intel Mac OS X 10_15_7)")
    return result


def _header_ok(name, value):
    if not name or len(name) > 256 or len(value) > 16384:
        return False
    if any(not (c.isalnum() or c in "!#$%&'*+-.^_`|~") for c in name):
        return False
    if any((ord(c) < 32 and c != "\t") or ord(c) == 127 for c in value):
        return False
    return name.lower() not in ("host", "content-length", "connection", "transfer-encoding")


class _Page:
    def __init__(self, page_id, view):
        self.id = page_id
        self.view = view
        self.delegate = False
        self.panel_title = ""


class WebBridge:
    """One socket for the game, one window with a stack of pages."""

    def __init__(self, launcher):
        self.WebKit, self.Soup = _webkit()
        self.launcher = launcher
        self.user_agent = self.WebKit.Settings.new().get_user_agent()
        # Unix socket paths are limited to 104 bytes, prefix included.
        name = f"macncheese-web-{os.getpid()}.sock"
        candidates = [os.path.join(d, name) for d in (GLib.get_user_runtime_dir(), "/tmp") if d]
        fitting = [p for p in candidates if len(GUEST_PREFIX + p) < 104]
        if not fitting:
            raise RuntimeError("socket path too long")
        self.path = fitting[0]
        self.guest_path = GUEST_PREFIX + self.path
        try:
            os.unlink(self.path)
        except FileNotFoundError:
            pass
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.setblocking(False)
        self.listener.bind(self.path)
        os.chmod(self.path, 0o600)
        self.listener.listen(4)
        self.listen_watch = GLib.io_add_watch(self.listener.fileno(), GLib.PRIORITY_DEFAULT,
                                              GLib.IOCondition.IN, self._accept)
        self.peer = None
        self.peer_watch = 0
        self.write_watch = 0
        self.received = b""
        self.outgoing = []
        self.pages = {}
        self.decisions = {}
        self.decision_id = 0
        self.session = None
        self.current = None
        self.window = None

    # ---------------------------------------------------------------- socket
    def stop(self):
        for page in self.pages.values():
            if page.view:
                page.view.stop_loading()
        self._drop_peer()
        if self.listen_watch:
            GLib.source_remove(self.listen_watch)
            self.listen_watch = 0
        self.listener.close()
        try:
            os.unlink(self.path)
        except OSError:
            pass
        if self.window:
            self.window.destroy()
            self.window = None

    def _accept(self, _fd, _condition):
        try:
            client, _address = self.listener.accept()
        except OSError:
            return True
        if self.peer:
            client.close()  # one game at a time
            return True
        client.setblocking(False)
        self.peer = client
        self.received = b""
        self.peer_watch = GLib.io_add_watch(client.fileno(), GLib.PRIORITY_DEFAULT,
                                            GLib.IOCondition.IN | GLib.IOCondition.HUP | GLib.IOCondition.ERR,
                                            self._incoming)
        return True

    def _drop_peer(self):
        for decision in self.decisions.values():
            decision.ignore()
        self.decisions.clear()
        if self.peer_watch:
            GLib.source_remove(self.peer_watch)
            self.peer_watch = 0
        if self.write_watch:
            GLib.source_remove(self.write_watch)
            self.write_watch = 0
        if self.peer:
            self.peer.close()
            self.peer = None
        self.received = b""
        self.outgoing = []

    def _incoming(self, _fd, condition):
        if self.peer is None:
            return False
        closed = bool(condition & (GLib.IOCondition.HUP | GLib.IOCondition.ERR))
        try:
            while True:
                chunk = self.peer.recv(8192)
                if not chunk:
                    closed = True
                    break
                self.received += chunk
                if len(self.received) > 1024 * 1024:
                    closed = True
                    break
        except BlockingIOError:
            pass
        except OSError:
            closed = True
        while b"\n" in self.received:
            line, self.received = self.received.split(b"\n", 1)
            try:
                message = json.loads(line)
            except ValueError:
                continue
            if isinstance(message, dict):
                try:
                    self._handle(message)
                except Exception as error:  # one bad request must not end the bridge
                    print("Embedded web page request failed:", error)
                    self._reply_error(message.get("request"), "The embedded browser request failed")
        if closed:
            self._drop_peer()
            return False
        return True

    def send(self, message):
        if not self.peer:
            return
        if len(self.outgoing) >= 128:
            # Closing the stream lets the guest finish pending callbacks with
            # an error. Silently dropping a reply leaves them waiting forever.
            self._drop_peer()
            return
        self.outgoing.append(json.dumps(message).encode() + b"\n")
        if not self.write_watch:
            self.write_watch = GLib.io_add_watch(self.peer.fileno(), GLib.PRIORITY_DEFAULT,
                                                 GLib.IOCondition.OUT, self._flush)

    def _flush(self, _fd, _condition):
        while self.outgoing and self.peer:
            try:
                sent = self.peer.send(self.outgoing[0])
            except BlockingIOError:
                return True
            except OSError:
                self._drop_peer()
                return False
            if sent == 0:
                self._drop_peer()
                return False
            self.outgoing[0] = self.outgoing[0][sent:]
            if not self.outgoing[0]:
                self.outgoing.pop(0)
        self.write_watch = 0
        return False

    def _event(self, page, kind, **fields):
        message = {"view": page.id if page else 0, "event": kind}
        message.update(fields)
        self.send(message)

    def _reply_error(self, number, reason, page_id=0):
        if isinstance(number, int) and not isinstance(number, bool):
            self.send({"view": page_id, "event": "reply", "request": number, "error": reason})

    # ---------------------------------------------------------------- window
    def _build_window(self):
        WebKit = self.WebKit
        self.window = Adw.Window(title="Roblox", default_width=1100, default_height=800, hide_on_close=True)
        self.window.connect("close-request", self._closed)
        self.title = Adw.WindowTitle(title="Roblox")
        header = Adw.HeaderBar(title_widget=self.title)
        self.back = Gtk.Button(icon_name="go-previous-symbolic", tooltip_text=_("Back"))
        self.forward = Gtk.Button(icon_name="go-next-symbolic", tooltip_text=_("Forward"))
        self.reload = Gtk.Button(icon_name="view-refresh-symbolic", tooltip_text=_("Reload"))
        self.back.connect("clicked", lambda *_args: self.current and self.current.view.go_back())
        self.forward.connect("clicked", lambda *_args: self.current and self.current.view.go_forward())
        self.reload.connect("clicked", lambda *_args: self.current and self.current.view.reload())
        for button in (self.back, self.forward, self.reload):
            header.pack_start(button)
        self.done = Gtk.Button(label=_("Back to Roblox"))
        self.done.add_css_class("suggested-action")
        self.done.connect("clicked", lambda *_args: self._return_to_game())
        header.pack_end(self.done)
        self.stack = Gtk.Stack()
        view = Adw.ToolbarView(content=self.stack)
        view.add_top_bar(header)
        self.window.set_content(view)
        data = core.WEB_DATA_DIR
        cache = core.CACHE_DIR / "web"
        data.mkdir(parents=True, exist_ok=True)
        self.session = WebKit.NetworkSession.new(str(data), str(cache))
        self.session.get_cookie_manager().set_persistent_storage(
            str(data / "cookies.sqlite"), WebKit.CookiePersistentStorage.SQLITE)

    def _controls(self):
        page = self.current
        panel = bool(page and page.panel_title)
        for button in (self.back, self.forward, self.reload):
            button.set_visible(page is not None and not panel)
        self.done.set_label(_("Close") if panel else _("Back to Roblox"))
        if page:
            self.back.set_sensitive(page.view.can_go_back())
            self.forward.set_sensitive(page.view.can_go_forward())
            title = page.panel_title if panel else (page.view.get_title() or "")
            self.title.set_title(title or "Roblox")
            uri = page.view.get_uri() if not panel else None
            self.title.set_subtitle((urllib.parse.urlsplit(uri).hostname or "") if uri else "")
        else:
            self.title.set_title("Roblox")
            self.title.set_subtitle("")

    def _closed(self, _window):
        self._return_to_game()
        return True  # hidden, not destroyed

    def _return_to_game(self):
        if self.current:
            self._event(self.current, "closed")
        self.current = None
        if self.window:
            self.window.set_visible(False)

    # ---------------------------------------------------------------- pages
    def _page(self, page_id):
        if page_id in self.pages:
            return self.pages[page_id]
        WebKit = self.WebKit
        if not self.window:
            self._build_window()
        manager = WebKit.UserContentManager()
        view = WebKit.WebView(network_session=self.session, user_content_manager=manager)
        page = _Page(page_id, view)
        self.pages[page_id] = page
        self.stack.add_named(view, str(page_id))
        view.connect("load-changed", self._load_changed, page)
        view.connect("load-failed", self._load_failed, page)
        view.connect("web-process-terminated", self._terminated, page)
        view.connect("notify::title", self._state, page)
        view.connect("notify::uri", self._state, page)
        view.connect("decide-policy", self._policy, page)
        return page

    def _state(self, view, _pspec, page):
        self._event(page, "state", url=view.get_uri() or "", title=view.get_title() or "",
                    back=view.can_go_back(), forward=view.can_go_forward(), loading=view.is_loading())
        if self.current is page:
            self._controls()

    def _load_changed(self, view, event, page):
        self._event(page, "load", stage=int(event))
        self._state(view, None, page)

    def _load_failed(self, _view, _event, _uri, _error, page):
        # Never the URL: sign-in flows may put transient secrets in it.
        self._event(page, "error", message="The embedded page could not be loaded.")
        return False

    def _terminated(self, _view, _reason, page):
        self._event(page, "error", message="The embedded browser process stopped unexpectedly.")

    def _policy(self, view, decision, kind, page):
        WebKit = self.WebKit
        if kind == WebKit.PolicyDecisionType.RESPONSE:
            return False
        action = decision.get_navigation_action()
        url = action.get_request().get_uri()
        if _client_url(url):
            # Server IDs, follow-user IDs and authentication tickets belong to
            # the running client's URL handler, never to a browser.
            self._event(page, "launch-url", url=url)
            decision.ignore()
            return True
        if not _web_url(url) and url != "about:blank":
            decision.ignore()
            return True
        if kind == WebKit.PolicyDecisionType.NEW_WINDOW_ACTION:
            decision.ignore()
            view.load_uri(url)
            return True
        if not page.delegate:
            return False
        self.decision_id += 1
        number = self.decision_id
        self.decisions[number] = decision
        GLib.timeout_add_seconds(15, self._expire_decision, number)
        self._event(page, "navigation", decision=number, url=url, type=int(action.get_navigation_type()))
        return True

    def _expire_decision(self, number):
        decision = self.decisions.pop(number, None)
        if decision:
            decision.ignore()
        return False

    def _message(self, _manager, value, page, name):
        text = value.to_json(0)
        body = None
        if text:
            try:
                body = json.loads(text)
            except ValueError:
                body = None
        self._event(page, "message", name=name, body=body)

    # ---------------------------------------------------------------- requests
    def _handle(self, message):
        op = message.get("op")
        page_id = message.get("view", 0)
        if op == "return-to-game":
            self._return_to_game()
            return
        if op == "attach":
            return  # the game's window: the browser stays a window of its own
        if op == "policy":
            decision = self.decisions.pop(message.get("decision"), None)
            if decision:
                decision.use() if message.get("allow") else decision.ignore()
            return
        if op == "close":
            if self.current and self.current.id == page_id:
                self.current = None
                self._return_to_game()
            page = self.pages.pop(page_id, None)
            if page and page.view:
                page.view.stop_loading()
                self.stack.remove(page.view)
                page.view = None
            return
        if not isinstance(page_id, int) or isinstance(page_id, bool) or page_id < 0 or page_id > 1000000:
            self._reply_error(message.get("request"), "Invalid embedded page")
            return
        if op == "cookies-get":
            if not self.session:
                self._build_window()
            self._cookies_get(message.get("request"))
            return
        elif op == "cookie-set":
            if not self.session:
                self._build_window()
            self._cookie_set(message.get("request"), message.get("cookie"))
            return
        if op not in ("load", "user-agent", "eval", "back", "forward", "reload", "stop", "handler", "script"):
            self._reply_error(message.get("request"), "Unknown embedded browser operation")
            return
        if op in ("eval", "back", "forward", "reload", "stop") and page_id not in self.pages:
            self._reply_error(message.get("request"), "The embedded page was closed", page_id)
            return
        page = self._page(page_id)
        if op == "load":
            self._load(page, message)
        elif op == "user-agent":
            self._set_user_agent(page, message.get("agent"))
        elif op == "eval":
            self._eval(page, message.get("request"), message.get("script"))
        elif op == "back":
            page.view.go_back()
        elif op == "forward":
            page.view.go_forward()
        elif op == "reload":
            page.view.reload()
        elif op == "stop":
            page.view.stop_loading()
        elif op == "handler":
            self._handler(page, message.get("name"))
        elif op == "script":
            self._script(page, message)

    def _set_user_agent(self, page, agent):
        valid = isinstance(agent, str) and agent and all(32 <= ord(c) <= 126 for c in agent)
        page.view.get_settings().set_user_agent(_compatible_user_agent(agent) if valid else None)

    def _load(self, page, message):
        url = message.get("url")
        if not _web_url(url):
            self._event(page, "error", message="The embedded page URL is invalid.")
            return
        page.delegate = bool(message.get("delegate"))
        page.panel_title = message.get("panelTitle") if isinstance(message.get("panelTitle"), str) else ""
        self._set_user_agent(page, message.get("agent"))
        self.current = page
        self.stack.set_visible_child(page.view)
        self._controls()
        request = self.WebKit.URIRequest.new(url)
        headers = message.get("headers")
        if isinstance(headers, dict):
            fields = request.get_http_headers()
            for name, value in list(headers.items())[:128]:
                if isinstance(name, str) and isinstance(value, str) and _header_ok(name, value):
                    fields.replace(name, value)
        page.view.load_request(request)
        self.window.present()
        page.view.grab_focus()

    def _eval(self, page, number, script):
        if not isinstance(script, str):
            self._reply_error(number, "Invalid JavaScript request", page.id)
            return

        def done(view, result):
            reply = {"view": page.id, "event": "reply", "request": number}
            try:
                value = view.evaluate_javascript_finish(result)
                text = value.to_json(0) if value else None
                if text:
                    reply["value"] = json.loads(text)
            except (GLib.Error, ValueError):
                reply["error"] = "JavaScript evaluation failed"
            self.send(reply)

        page.view.evaluate_javascript(script, -1, None, None, None, done)

    def _handler(self, page, name):
        if not isinstance(name, str) or not name or len(name) > 128:
            return
        manager = page.view.get_user_content_manager()
        if manager.register_script_message_handler(name, None):
            manager.connect(f"script-message-received::{name}", self._message, page, name)

    def _script(self, page, message):
        WebKit = self.WebKit
        source = message.get("script")
        if not isinstance(source, str):
            return
        script = WebKit.UserScript.new(
            source,
            WebKit.UserContentInjectedFrames.TOP_FRAME if message.get("mainOnly") else WebKit.UserContentInjectedFrames.ALL_FRAMES,
            WebKit.UserScriptInjectionTime.END if message.get("atEnd") else WebKit.UserScriptInjectionTime.START,
            None, None)
        page.view.get_user_content_manager().add_script(script)

    def _cookies_get(self, number):
        manager = self.session.get_cookie_manager()

        def done(manager, result):
            reply = {"view": 0, "event": "reply", "request": number}
            try:
                cookies = manager.get_all_cookies_finish(result)
                values = []
                for c in cookies:
                    value = {"name": c.get_name(), "value": c.get_value(), "domain": c.get_domain(),
                             "path": c.get_path(), "secure": c.get_secure(), "httpOnly": c.get_http_only()}
                    expires = c.get_expires()
                    if expires:
                        value["expires"] = expires.to_unix()
                    values.append(value)
                reply["value"] = values
            except GLib.Error:
                reply["error"] = "Could not read browser cookies"
            self.send(reply)

        manager.get_all_cookies(None, done)

    def _cookie_set(self, number, cookie):
        if not isinstance(cookie, dict):
            self._reply_error(number, "Invalid browser cookie")
            return
        name, value, domain = cookie.get("name"), cookie.get("value"), cookie.get("domain")
        path = cookie.get("path") or "/"
        if not all(isinstance(v, str) for v in (name, value, domain, path)) or not name or not domain:
            self._reply_error(number, "Invalid browser cookie")
            return
        soup_cookie = self.Soup.Cookie.new(name, value, domain, path, -1)
        soup_cookie.set_secure(bool(cookie.get("secure")))
        soup_cookie.set_http_only(bool(cookie.get("httpOnly")))
        expires = cookie.get("expires")
        if isinstance(expires, (int, float)) and not isinstance(expires, bool):
            date = GLib.DateTime.new_from_unix_utc(int(expires))
            if date:
                soup_cookie.set_expires(date)

        def done(manager, result):
            reply = {"view": 0, "event": "reply", "request": number}
            try:
                manager.add_cookie_finish(result)
            except GLib.Error:
                reply["error"] = "Could not write browser cookie"
            self.send(reply)

        self.session.get_cookie_manager().add_cookie(soup_cookie, None, done)
