//! Roblox's embedded pages — sign-in with its captcha, purchases, account
//! pages — in a WebKitGTK window. The game side is shim/web_bridge.m: it
//! turns WKWebView calls into JSON requests over a Unix socket, this side
//! answers and shows the pages. One object per line: requests from the
//! game carry `"op"`, our messages carry `"event"`. Port of
//! launcher/macncheese/web.py (the protocol is spidercraft's Roblox Mac
//! Linux Port, used with their permission); session.rs starts this helper
//! and hands the socket to the game as MACNCHEESE_WEB_SOCKET.

use std::cell::RefCell;
use std::collections::{HashMap, VecDeque};
use std::io::{ErrorKind, Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::rc::Rc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{channel, Sender};
use std::sync::{Arc, Mutex, MutexGuard};
use std::thread;
use std::time::Duration;

use gtk4::gdk;
use gtk4::glib;
use gtk4::glib::translate::IntoGlib;
use gtk4::prelude::*;
use gtk4::{Stack, Window};
use serde_json::{json, Map, Value};
use webkit6::prelude::*;
use webkit6::soup;
use webkit6::{
    CookiePersistentStorage, LoadEvent, NetworkSession, NavigationPolicyDecision, PolicyDecision,
    PolicyDecisionType, SnapshotOptions, SnapshotRegion, URIRequest, UserContentInjectedFrames,
    UserContentManager, UserScript, UserScriptInjectionTime, WebView,
};

// ---------------------------------------------------------------- helpers

/// Only plain http(s) pages with a host and no credentials are shown.
fn web_url(url: &str) -> bool {
    if url.len() > 16384 || url.chars().any(|c| (c as u32) < 32 || c == '\u{7f}') {
        return false;
    }
    let Some(scheme_end) = url.find("://") else {
        return false;
    };
    let scheme = &url[..scheme_end];
    if !(scheme.eq_ignore_ascii_case("http") || scheme.eq_ignore_ascii_case("https")) {
        return false;
    }
    let rest = &url[scheme_end + 3..];
    let netloc = rest.split(['/', '?', '#']).next().unwrap_or("");
    if netloc.contains('@') {
        return false;
    }
    hostname(netloc).is_some()
}

/// The host part of a `host[:port]` authority (or an IPv6 literal).
fn hostname(netloc: &str) -> Option<&str> {
    let host = if let Some(rest) = netloc.strip_prefix('[') {
        let end = rest.find(']')?;
        &rest[..end]
    } else {
        match netloc.rfind(':') {
            Some(port) => &netloc[..port],
            None => netloc,
        }
    };
    (!host.is_empty()).then_some(host)
}

/// roblox:// links belong to the running client, never to a browser.
fn client_url(url: &str) -> bool {
    let lower = url.to_lowercase();
    (lower.starts_with("roblox:") && lower.len() > 7)
        || (lower.starts_with("roblox-player:") && lower.len() > 14)
}

/// Roblox's user agent, as WebKitGTK accepts it. Apple's WebKit takes
/// Roblox's concatenated products; WebKitGTK's parser rejects the second
/// slash and keeps its desktop agent. Pages must also pick their macOS
/// bridge, not a Linux fallback, so app-tagged agents get a Mac platform.
fn compatible_user_agent(agent: &str) -> String {
    let mut result = agent.replace("Roblox/DarwinRobloxApp/", "Roblox/Darwin RobloxApp/");
    if result.contains("RobloxApp/") {
        result = result.replace("(X11; Linux x86_64)", "(Macintosh; Intel Mac OS X 10_15_7)");
    }
    result
}

fn header_ok(name: &str, value: &str) -> bool {
    if name.is_empty() || name.len() > 256 || value.len() > 16384 {
        return false;
    }
    if !name
        .chars()
        .all(|c| c.is_alphanumeric() || "!#$%&'*+-.^_`|~".contains(c))
    {
        return false;
    }
    if value
        .chars()
        .any(|c| ((c as u32) < 32 && c != '\t') || c == '\u{7f}')
    {
        return false;
    }
    !matches!(
        name.to_ascii_lowercase().as_str(),
        "host" | "content-length" | "connection" | "transfer-encoding"
    )
}

/// JSON truthiness, the way the Python bridge read its fields.
fn truthy(value: Option<&Value>) -> bool {
    match value {
        None | Some(Value::Null) => false,
        Some(Value::Bool(flag)) => *flag,
        Some(Value::Number(number)) => number.as_f64().map_or(false, |f| f != 0.0),
        Some(Value::String(text)) => !text.is_empty(),
        Some(Value::Array(items)) => !items.is_empty(),
        Some(Value::Object(fields)) => !fields.is_empty(),
    }
}

/// A lock that survives a panicked holder: the socket thread must not die
/// because the main thread once panicked between lock and unlock.
fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|error| error.into_inner())
}

// ---------------------------------------------------------------- socket

/// The shared half between the main thread and the socket thread. Replies
/// go through this without borrowing the Bridge, so a callback that were
/// to fire while a request is being handled still sends its answer.
#[derive(Clone)]
struct Link {
    peer: Arc<AtomicBool>,
    outgoing: Arc<Mutex<VecDeque<Vec<u8>>>>,
    /// The main thread closes the stream when replies pile up past 128.
    dropping: Arc<AtomicBool>,
}

impl Link {
    fn send(&self, message: Value) {
        if !self.peer.load(Ordering::SeqCst) || self.dropping.load(Ordering::SeqCst) {
            return;
        }
        {
            let queue = lock(&self.outgoing);
            if queue.len() >= 128 {
                // Closing the stream lets the guest finish pending callbacks
                // with an error. Silently dropping a reply waits forever.
                drop(queue);
                self.dropping.store(true, Ordering::SeqCst);
                return;
            }
        }
        let Ok(mut line) = serde_json::to_vec(&message) else {
            return;
        };
        line.push(b'\n');
        lock(&self.outgoing).push_back(line);
    }
}

enum Incoming {
    PeerUp,
    PeerDown,
    Line(Value),
}

// ---------------------------------------------------------------- state

struct Page {
    view: WebView,
    delegate: bool,
    panel_title: String,
}

struct Bridge {
    window: Window,
    stack: Stack,
    session: NetworkSession,
    pages: HashMap<i64, Page>,
    decisions: HashMap<i64, PolicyDecision>,
    decision_id: i64,
    current: Option<i64>,
    link: Link,
    /// Opt-in pixel truth: when MACNCHEESE_WEB_SNAPSHOT names a file,
    /// every finished load snapshots its visible pixels there. Painting
    /// bugs (blank window, working scripts) are otherwise undebuggable.
    snapshot_path: Option<PathBuf>,
}

impl Bridge {
    fn new(data: &str, cache: &str, link: Link) -> Self {
        let data_path = PathBuf::from(data);
        let cache_path = PathBuf::from(cache);
        let _ = std::fs::create_dir_all(&data_path);
        let _ = std::fs::create_dir_all(&cache_path);

        let session = NetworkSession::new(Some(data), Some(cache));
        if let Some(manager) = session.cookie_manager() {
            manager.set_persistent_storage(
                &data_path.join("cookies.sqlite").display().to_string(),
                CookiePersistentStorage::Sqlite,
            );
        }

        let window = Window::builder()
            .title("Roblox")
            .default_width(1100)
            .default_height(800)
            .hide_on_close(true)
            .build();
        let stack = Stack::new();
        // Without expand the box hands the stack its natural height —
        // a WebView's is zero, so pages painted into nothing (blank
        // window, working scripts, failed snapshots).
        stack.set_hexpand(true);
        stack.set_vexpand(true);
        // Just the pages: the game drives everything (back, forward,
        // reload all arrive as requests); the window's own titlebar
        // carries the page title. No toolbar, no chrome.
        window.set_child(Some(&stack));

        Bridge {
            window,
            stack,
            session,
            pages: HashMap::new(),
            decisions: HashMap::new(),
            decision_id: 0,
            current: None,
            link,
            snapshot_path: std::env::var_os("MACNCHEESE_WEB_SNAPSHOT").map(PathBuf::from),
        }
    }

    /// Window-level signals, connected once after construction. Closing
    /// the window only hides it (the game still owns the pages); the
    /// close request tells the game it went away.
    fn attach(bridge: &Rc<RefCell<Bridge>>) {
        let b = bridge.clone();
        bridge.borrow().window.connect_close_request(move |_| {
            if let Ok(mut bridge) = b.try_borrow_mut() {
                bridge.return_to_game();
            }
            glib::Propagation::Stop // hidden, not destroyed
        });
    }

    // ------------------------------------------------------------- messages

    fn send(&self, message: Value) {
        self.link.send(message);
    }

    fn event(&self, page_id: i64, kind: &str, fields: Value) {
        let mut message = serde_json::Map::new();
        message.insert("view".into(), json!(page_id));
        message.insert("event".into(), json!(kind));
        if let Value::Object(extra) = fields {
            message.extend(extra);
        }
        self.send(Value::Object(message));
    }

    /// An error reply, but only for a numeric request (the game's callbacks
    /// are keyed by number; anything else has nothing to catch).
    fn reply_error(&self, request: &Value, reason: &str, page_id: i64) {
        if let Some(number) = request.as_i64() {
            self.send(json!({
                "view": page_id, "event": "reply", "request": number, "error": reason
            }));
        }
    }

    fn peer_up(&self) {
        // Lines queued for a dead connection mean nothing to the next one.
        lock(&self.link.outgoing).clear();
        self.link.peer.store(true, Ordering::SeqCst);
    }

    fn peer_down(&mut self) {
        self.link.peer.store(false, Ordering::SeqCst);
        for (_, decision) in self.decisions.drain() {
            decision.ignore();
        }
    }

    // ------------------------------------------------------------- window

    fn return_to_game(&mut self) {
        if let Some(page_id) = self.current {
            self.event(page_id, "closed", json!({}));
        }
        self.current = None;
        self.window.set_visible(false);
    }

    /// The window's own titlebar carries the page title — the only
    /// chrome left.
    fn controls(&self) {
        let page = self.current.and_then(|id| self.pages.get(&id));
        let mut title = String::from("Roblox");
        if let Some(page) = page {
            if !page.panel_title.is_empty() {
                title = page.panel_title.clone();
            } else if let Some(text) = page.view.title() {
                let text = text.to_string();
                if !text.is_empty() {
                    title = text;
                }
            }
        }
        self.window.set_title(Some(&title));
    }

    fn state(&self, page_id: i64, view: &WebView) {
        self.event(
            page_id,
            "state",
            json!({
                "url": view.uri().map(|text| text.to_string()).unwrap_or_default(),
                "title": view.title().map(|text| text.to_string()).unwrap_or_default(),
                "back": view.can_go_back(),
                "forward": view.can_go_forward(),
                "loading": view.is_loading(),
            }),
        );
        if self.current == Some(page_id) {
            self.controls();
        }
    }

    /// The pixel truth behind a finished load, 3 seconds later (late
    /// scripts still paint). Only when MACNCHEESE_WEB_SNAPSHOT is set.
    fn maybe_snapshot(&self, view: &WebView) {
        let Some(path) = self.snapshot_path.clone() else {
            return;
        };
        let view = view.clone();
        glib::timeout_add_seconds_local(3, move || {
            let path = path.clone();
            view.snapshot(
                SnapshotRegion::Visible,
                SnapshotOptions::empty(),
                None::<&gtk4::gio::Cancellable>,
                move |result| match result {
                    Ok(texture) => {
                        if let Err(error) = texture.save_to_png(&path) {
                            eprintln!("web snapshot failed: {error}");
                        }
                    }
                    Err(error) => eprintln!("web snapshot failed: {error}"),
                },
            );
            glib::ControlFlow::Break
        });
    }

    // ------------------------------------------------------------- requests

    fn handle(&mut self, bridge: &Rc<RefCell<Bridge>>, message: &Map<String, Value>) {
        let op = message.get("op").and_then(|v| v.as_str()).unwrap_or("");
        let view = message.get("view").cloned().unwrap_or_else(|| json!(0));
        let request = message.get("request").cloned().unwrap_or(Value::Null);
        match op {
            "return-to-game" => {
                self.return_to_game();
                return;
            }
            "attach" => return, // the game's window: ours stays a window of its own
            "policy" => {
                if let Some(number) = message.get("decision").and_then(|v| v.as_i64()) {
                    if let Some(decision) = self.decisions.remove(&number) {
                        if truthy(message.get("allow")) {
                            decision.use_();
                        } else {
                            decision.ignore();
                        }
                    }
                }
                return;
            }
            "close" => {
                if let Some(page_id) = view.as_i64() {
                    if self.current == Some(page_id) {
                        self.current = None;
                        self.return_to_game();
                    }
                    if let Some(page) = self.pages.remove(&page_id) {
                        page.view.stop_loading();
                        self.stack.remove(&page.view);
                    }
                }
                return;
            }
            _ => {}
        }
        let page_id = match view.as_i64() {
            Some(id) if (0..=1_000_000).contains(&id) => id,
            _ => {
                self.reply_error(&request, "Invalid embedded page", 0);
                return;
            }
        };
        match op {
            "cookies-get" => {
                self.cookies_get(&request);
                return;
            }
            "cookie-set" => {
                let cookie = message.get("cookie").cloned().unwrap_or(Value::Null);
                self.cookie_set(&request, &cookie);
                return;
            }
            _ => {}
        }
        if !matches!(
            op,
            "load" | "user-agent" | "eval" | "back" | "forward" | "reload" | "stop" | "handler"
                | "script"
        ) {
            self.reply_error(&request, "Unknown embedded browser operation", 0);
            return;
        }
        if matches!(op, "eval" | "back" | "forward" | "reload" | "stop")
            && !self.pages.contains_key(&page_id)
        {
            self.reply_error(&request, "The embedded page was closed", page_id);
            return;
        }
        self.page(bridge, page_id);
        match op {
            "load" => self.load(page_id, message),
            "user-agent" => {
                self.set_user_agent(page_id, message.get("agent").and_then(|v| v.as_str()))
            }
            "eval" => self.eval(
                page_id,
                &request,
                message.get("script").and_then(|v| v.as_str()),
            ),
            "back" => self.pages[&page_id].view.go_back(),
            "forward" => self.pages[&page_id].view.go_forward(),
            "reload" => self.pages[&page_id].view.reload(),
            "stop" => self.pages[&page_id].view.stop_loading(),
            "handler" => self.handler(
                page_id,
                message.get("name").and_then(|v| v.as_str()),
            ),
            "script" => self.script(page_id, message),
            _ => unreachable!("op checked above"),
        }
    }

    fn set_user_agent(&self, page_id: i64, agent: Option<&str>) {
        let valid = agent.is_some_and(|agent| {
            !agent.is_empty() && agent.chars().all(|c| (32..=126).contains(&(c as u32)))
        });
        let agent = valid.then(|| compatible_user_agent(agent.unwrap_or_default()));
        // WidgetExt also has a settings(): say which one is meant.
        let settings = self
            .pages
            .get(&page_id)
            .and_then(|page| WebViewExt::settings(&page.view));
        if let Some(settings) = settings {
            settings.set_user_agent(agent.as_deref());
        }
    }

    fn load(&mut self, page_id: i64, message: &Map<String, Value>) {
        let url = match message.get("url").and_then(|v| v.as_str()) {
            Some(url) if web_url(url) => url.to_string(),
            _ => {
                self.event(
                    page_id,
                    "error",
                    json!({"message": "The embedded page URL is invalid."}),
                );
                return;
            }
        };
        {
            let page = self
                .pages
                .get_mut(&page_id)
                .expect("page created before the request was dispatched");
            page.delegate = truthy(message.get("delegate"));
            page.panel_title = message
                .get("panelTitle")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
        }
        self.set_user_agent(page_id, message.get("agent").and_then(|v| v.as_str()));
        self.current = Some(page_id);
        let view = self.pages[&page_id].view.clone();
        self.stack.set_visible_child(&view);
        self.controls();
        let request = URIRequest::new(&url);
        if let Some(headers) = message.get("headers").and_then(|v| v.as_object()) {
            if let Some(fields) = request.http_headers() {
                for (name, value) in headers.iter().take(128) {
                    if let Some(value) = value.as_str() {
                        if header_ok(name, value) {
                            fields.replace(name, value);
                        }
                    }
                }
            }
        }
        view.load_request(&request);
        self.window.present();
        view.grab_focus();
    }

    fn eval(&self, page_id: i64, request: &Value, script: Option<&str>) {
        let Some(script) = script.map(str::to_string) else {
            self.reply_error(request, "Invalid JavaScript request", page_id);
            return;
        };
        let view = self.pages[&page_id].view.clone();
        let request = request.clone();
        let link = self.link.clone();
        view.evaluate_javascript(
            &script,
            None,
            None,
            None::<&gtk4::gio::Cancellable>,
            move |result| {
                let mut reply = json!({"view": page_id, "event": "reply", "request": request});
                match result {
                    Ok(value) => {
                        if let Some(text) = value.to_json(0) {
                            if !text.is_empty() {
                                match serde_json::from_str::<Value>(&text) {
                                    Ok(parsed) => reply["value"] = parsed,
                                    Err(_) => {
                                        reply["error"] = json!("JavaScript evaluation failed");
                                    }
                                }
                            }
                        }
                    }
                    Err(_) => reply["error"] = json!("JavaScript evaluation failed"),
                }
                link.send(reply);
            },
        );
    }

    fn handler(&self, page_id: i64, name: Option<&str>) {
        let Some(name) = name
            .filter(|name| !name.is_empty() && name.len() <= 128)
            .map(str::to_string)
        else {
            return;
        };
        let Some(manager) = self
            .pages
            .get(&page_id)
            .and_then(|page| page.view.user_content_manager())
        else {
            return;
        };
        if manager.register_script_message_handler(&name, None) {
            let link = self.link.clone();
            let detail = name.clone();
            manager.connect_script_message_received(Some(&detail), move |_manager, value| {
                let body = value
                    .to_json(0)
                    .and_then(|text| serde_json::from_str::<Value>(&text).ok())
                    .unwrap_or(Value::Null);
                link.send(json!({
                    "view": page_id, "event": "message", "name": name, "body": body
                }));
            });
        }
    }

    fn script(&self, page_id: i64, message: &Map<String, Value>) {
        let Some(source) = message.get("script").and_then(|v| v.as_str()) else {
            return;
        };
        let frames = if truthy(message.get("mainOnly")) {
            UserContentInjectedFrames::TopFrame
        } else {
            UserContentInjectedFrames::AllFrames
        };
        let time = if truthy(message.get("atEnd")) {
            UserScriptInjectionTime::End
        } else {
            UserScriptInjectionTime::Start
        };
        let script = UserScript::new(source, frames, time, &[], &[]);
        if let Some(manager) = self
            .pages
            .get(&page_id)
            .and_then(|page| page.view.user_content_manager())
        {
            manager.add_script(&script);
        }
    }

    fn cookies_get(&self, request: &Value) {
        let Some(manager) = self.session.cookie_manager() else {
            return;
        };
        let request = request.clone();
        let link = self.link.clone();
        manager.all_cookies(None::<&gtk4::gio::Cancellable>, move |result| {
            let mut reply = json!({"view": 0, "event": "reply", "request": request});
            match result {
                Ok(cookies) => {
                    let mut values = Vec::new();
                    for mut cookie in cookies {
                        let mut value = json!({
                            "name": cookie.name().map(|text| text.to_string()),
                            "value": cookie.value().map(|text| text.to_string()),
                            "domain": cookie.domain().map(|text| text.to_string()),
                            "path": cookie.path().map(|text| text.to_string()),
                            "secure": cookie.is_secure(),
                            "httpOnly": cookie.is_http_only(),
                        });
                        if let Some(expires) = cookie.expires() {
                            value["expires"] = json!(expires.to_unix());
                        }
                        values.push(value);
                    }
                    reply["value"] = Value::Array(values);
                }
                Err(_) => reply["error"] = json!("Could not read browser cookies"),
            }
            link.send(reply);
        });
    }

    fn cookie_set(&self, request: &Value, cookie: &Value) {
        let Some(fields) = cookie.as_object() else {
            self.reply_error(request, "Invalid browser cookie", 0);
            return;
        };
        let name = fields.get("name").and_then(|v| v.as_str()).unwrap_or("");
        let value = fields.get("value").and_then(|v| v.as_str());
        let domain = fields.get("domain").and_then(|v| v.as_str()).unwrap_or("");
        let path = if truthy(fields.get("path")) {
            fields.get("path").and_then(|v| v.as_str())
        } else {
            Some("/") // absent, empty or null means the root path
        };
        let (Some(value), Some(path)) = (value, path) else {
            self.reply_error(request, "Invalid browser cookie", 0);
            return;
        };
        if name.is_empty() || domain.is_empty() {
            self.reply_error(request, "Invalid browser cookie", 0);
            return;
        }
        let mut cookie = soup::Cookie::new(name, value, domain, path, -1);
        cookie.set_secure(truthy(fields.get("secure")));
        cookie.set_http_only(truthy(fields.get("httpOnly")));
        if let Some(expires) = fields.get("expires").and_then(|v| v.as_f64()) {
            if let Ok(date) = glib::DateTime::from_unix_utc(expires as i64) {
                cookie.set_expires(&date);
            }
        }
        let Some(manager) = self.session.cookie_manager() else {
            return;
        };
        let request = request.clone();
        let link = self.link.clone();
        manager.add_cookie(&cookie, None::<&gtk4::gio::Cancellable>, move |result| {
            let mut reply = json!({"view": 0, "event": "reply", "request": request});
            if result.is_err() {
                reply["error"] = json!("Could not write browser cookie");
            }
            link.send(reply);
        });
    }

    // ------------------------------------------------------------- pages

    fn page(&mut self, bridge: &Rc<RefCell<Bridge>>, page_id: i64) {
        if self.pages.contains_key(&page_id) {
            return;
        }
        let manager = UserContentManager::new();
        let view = WebView::builder()
            .network_session(&self.session)
            .user_content_manager(&manager)
            .build();
        // An empty or loading page would otherwise sit on WebKit's light
        // gray: dark, like the rest of the window.
        view.set_background_color(&gdk::RGBA::new(0.0, 0.0, 0.0, 1.0));
        self.stack.add_named(&view, Some(&page_id.to_string()));
        let b = bridge.clone();
        view.connect_load_changed(move |view, event| {
            if let Ok(bridge) = b.try_borrow() {
                bridge.event(page_id, "load", json!({"stage": event.into_glib() as i64}));
                bridge.state(page_id, view);
                if event.into_glib() == LoadEvent::Finished.into_glib() {
                    bridge.maybe_snapshot(view);
                }
            }
        });
        let b = bridge.clone();
        view.connect_load_failed(move |_view, _event, _uri, _error| {
            if let Ok(bridge) = b.try_borrow() {
                // Never the URL: sign-in flows may put transient secrets in it.
                bridge.event(
                    page_id,
                    "error",
                    json!({"message": "The embedded page could not be loaded."}),
                );
            }
            false
        });
        let b = bridge.clone();
        view.connect_web_process_terminated(move |_view, _reason| {
            if let Ok(bridge) = b.try_borrow() {
                bridge.event(
                    page_id,
                    "error",
                    json!({"message": "The embedded browser process stopped unexpectedly."}),
                );
            }
        });
        let b = bridge.clone();
        view.connect_title_notify(move |view| {
            if let Ok(bridge) = b.try_borrow() {
                bridge.state(page_id, view);
            }
        });
        let b = bridge.clone();
        view.connect_uri_notify(move |view| {
            if let Ok(bridge) = b.try_borrow() {
                bridge.state(page_id, view);
            }
        });
        let b = bridge.clone();
        view.connect_decide_policy(move |view, decision, kind| match b.try_borrow_mut() {
            Ok(mut bridge) => bridge.policy(&b, page_id, view, decision, kind),
            Err(_) => false,
        });
        self.pages.insert(
            page_id,
            Page {
                view,
                delegate: false,
                panel_title: String::new(),
            },
        );
    }

    fn policy(
        &mut self,
        bridge: &Rc<RefCell<Bridge>>,
        page_id: i64,
        view: &WebView,
        decision: &PolicyDecision,
        kind: PolicyDecisionType,
    ) -> bool {
        if kind == PolicyDecisionType::Response {
            return false;
        }
        let action = decision
            .downcast_ref::<NavigationPolicyDecision>()
            .and_then(|decision| decision.navigation_action());
        let Some(action) = action else {
            return false;
        };
        let Some(url) = action.request().and_then(|request| request.uri()) else {
            return false;
        };
        let url = url.to_string();
        if client_url(&url) {
            // Server IDs, follow-user IDs and authentication tickets belong
            // to the running client's URL handler, never to a browser.
            self.event(page_id, "launch-url", json!({"url": url}));
            decision.ignore();
            return true;
        }
        if !web_url(&url) && url != "about:blank" {
            decision.ignore();
            return true;
        }
        if kind == PolicyDecisionType::NewWindowAction {
            decision.ignore();
            view.load_uri(&url);
            return true;
        }
        if !self.pages.get(&page_id).is_some_and(|page| page.delegate) {
            return false;
        }
        self.decision_id += 1;
        let number = self.decision_id;
        self.decisions.insert(number, decision.clone());
        let b = bridge.clone();
        glib::timeout_add_seconds_local(15, move || {
            if let Ok(mut bridge) = b.try_borrow_mut() {
                if let Some(decision) = bridge.decisions.remove(&number) {
                    decision.ignore();
                }
            }
            glib::ControlFlow::Break
        });
        self.event(
            page_id,
            "navigation",
            json!({
                "decision": number,
                "url": url,
                "type": action.navigation_type().into_glib() as i64,
            }),
        );
        true
    }
}

// ---------------------------------------------------------------- I/O

/// Owns the listener and the game's stream: accept, read lines in, drain
/// what the main thread queued out. This side never touches GTK; the main
/// loop polls the channel every few milliseconds.
fn io_thread(socket: PathBuf, incoming: Sender<Incoming>, link: Link) {
    let _ = std::fs::remove_file(&socket);
    let listener = match UnixListener::bind(&socket) {
        Ok(listener) => listener,
        Err(error) => {
            eprintln!("macncheese-web: cannot bind {}: {error}", socket.display());
            return;
        }
    };
    let _ = std::fs::set_permissions(&socket, std::fs::Permissions::from_mode(0o600));
    let _ = listener.set_nonblocking(true);
    let mut peer: Option<UnixStream> = None;
    let mut received: Vec<u8> = Vec::new();
    loop {
        if peer.is_none() {
            match listener.accept() {
                Ok((stream, _)) => {
                    let _ = stream.set_nonblocking(true);
                    lock(&link.outgoing).clear();
                    received.clear();
                    peer = Some(stream);
                    let _ = incoming.send(Incoming::PeerUp);
                }
                Err(error) if error.kind() == ErrorKind::WouldBlock => {
                    thread::sleep(Duration::from_millis(50));
                    continue;
                }
                Err(_) => {
                    thread::sleep(Duration::from_millis(100));
                    continue;
                }
            }
        }
        if link.dropping.swap(false, Ordering::SeqCst) {
            peer = None;
            received.clear();
            lock(&link.outgoing).clear();
            let _ = incoming.send(Incoming::PeerDown);
            continue;
        }
        let mut gone = false;
        if let Some(stream) = peer.as_mut() {
            let mut queue = lock(&link.outgoing);
            while let Some(front) = queue.front_mut() {
                match stream.write(front) {
                    Ok(0) => {
                        gone = true;
                        break;
                    }
                    Ok(written) => {
                        front.drain(..written);
                        if front.is_empty() {
                            queue.pop_front();
                        } else {
                            break;
                        }
                    }
                    Err(error) if error.kind() == ErrorKind::WouldBlock => break,
                    Err(error) if error.kind() == ErrorKind::Interrupted => continue,
                    Err(_) => {
                        gone = true;
                        break;
                    }
                }
            }
        }
        if let Some(stream) = peer.as_mut() {
            let mut chunk = [0u8; 8192];
            while !gone {
                match stream.read(&mut chunk) {
                    Ok(0) => gone = true,
                    Ok(read) => {
                        received.extend_from_slice(&chunk[..read]);
                        if received.len() > 1024 * 1024 {
                            gone = true;
                            break;
                        }
                        while let Some(end) = received.iter().position(|&byte| byte == b'\n') {
                            let mut line: Vec<u8> = received.drain(..=end).collect();
                            line.pop(); // the newline
                            if let Ok(value) = serde_json::from_slice::<Value>(&line) {
                                if value.is_object() {
                                    let _ = incoming.send(Incoming::Line(value));
                                }
                            }
                        }
                    }
                    Err(error) if error.kind() == ErrorKind::WouldBlock => break,
                    Err(error) if error.kind() == ErrorKind::Interrupted => continue,
                    Err(_) => gone = true,
                }
            }
        }
        if gone {
            peer = None;
            received.clear();
            lock(&link.outgoing).clear();
            let _ = incoming.send(Incoming::PeerDown);
            continue;
        }
        thread::sleep(Duration::from_millis(5));
    }
}

/// One request in: handled on the main thread. A bad request answers with
/// an error and never ends the bridge (the Python bridge's try/except).
fn handle_line(bridge: &Rc<RefCell<Bridge>>, value: &Value) {
    let request = value.get("request").cloned().unwrap_or(Value::Null);
    let handled = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        if let Some(message) = value.as_object() {
            bridge.borrow_mut().handle(bridge, message);
        }
    }));
    if let Err(payload) = handled {
        let detail = payload
            .downcast_ref::<String>()
            .map(String::as_str)
            .or_else(|| payload.downcast_ref::<&str>().copied())
            .unwrap_or("unknown failure");
        eprintln!("Embedded web page request failed: {detail}");
        if let Ok(bridge) = bridge.try_borrow() {
            bridge.reply_error(&request, "The embedded browser request failed", 0);
        }
    }
}

// ---------------------------------------------------------------- main

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let (socket, data, cache) = match (args.get(1), args.get(2), args.get(3)) {
        (Some(socket), Some(data), Some(cache)) => (socket.clone(), data.clone(), cache.clone()),
        _ => {
            eprintln!("usage: macncheese-web SOCKET DATA_DIR CACHE_DIR");
            std::process::exit(2);
        }
    };
    glib::set_prgname(Some("com.nenquen.Macncheese"));
    if let Err(error) = gtk4::init() {
        eprintln!("macncheese-web: cannot open a display: {error}");
        std::process::exit(1);
    }
    if let Some(settings) = gtk4::Settings::default() {
        settings.set_gtk_application_prefer_dark_theme(true);
    }
    // WebKit's DMA-BUF renderer shows black views on X11 with NVIDIA's
    // driver, and its GL compositor paints nothing at all there (a blank
    // gray page that still runs its scripts) — the software path instead.
    let wayland = gdk::Display::default()
        .map(|display| display.type_().name() == "GdkWaylandDisplay")
        .unwrap_or(false);
    if !wayland {
        if std::env::var_os("WEBKIT_DISABLE_DMABUF_RENDERER").is_none() {
            std::env::set_var("WEBKIT_DISABLE_DMABUF_RENDERER", "1");
        }
        if std::env::var_os("WEBKIT_DISABLE_COMPOSITING_MODE").is_none() {
            std::env::set_var("WEBKIT_DISABLE_COMPOSITING_MODE", "1");
        }
    }
    // The game builds Roblox's agent on top of WebKit's own default one;
    // the launcher reads this file before it starts the game. It is
    // written before the socket appears, so a bound socket implies the
    // file is there.
    let agent = webkit6::Settings::new()
        .user_agent()
        .map(|agent| agent.to_string())
        .unwrap_or_default();
    let _ = std::fs::write(format!("{socket}.ua"), format!("{agent}\n"));

    let (tx, rx) = channel::<Incoming>();
    let link = Link {
        peer: Arc::new(AtomicBool::new(false)),
        outgoing: Arc::new(Mutex::new(VecDeque::new())),
        dropping: Arc::new(AtomicBool::new(false)),
    };
    let spawned = thread::Builder::new().name("web-socket".into()).spawn({
        let (socket, link) = (PathBuf::from(&socket), link.clone());
        move || io_thread(socket, tx, link)
    });
    if spawned.is_err() {
        eprintln!("macncheese-web: cannot start the socket thread");
        std::process::exit(1);
    }

    let bridge = Rc::new(RefCell::new(Bridge::new(&data, &cache, link)));
    Bridge::attach(&bridge);

    let polling = bridge.clone();
    glib::timeout_add_local(Duration::from_millis(20), move || {
        while let Ok(incoming) = rx.try_recv() {
            match incoming {
                Incoming::PeerUp => polling.borrow().peer_up(),
                Incoming::PeerDown => polling.borrow_mut().peer_down(),
                Incoming::Line(value) => handle_line(&polling, &value),
            }
        }
        glib::ControlFlow::Continue
    });

    glib::MainLoop::new(None, false).run();
}

// ---------------------------------------------------------------- tests

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_plain_web_pages_pass() {
        assert!(web_url("https://www.roblox.com/login"));
        assert!(web_url("http://example.co.uk:8080/a?b=c#d"));
        assert!(web_url("https://[::1]/"));
        assert!(!web_url("about:blank"));
        assert!(!web_url("javascript:alert(1)"));
        assert!(!web_url("https://user@host/"));
        assert!(!web_url("https:///path"));
        assert!(!web_url("https://:8080/"));
        assert!(!web_url(&format!("https://example.com/{}", "a".repeat(20_000))));
        assert!(!web_url("https://example.com/\u{1}"));
        assert!(!web_url("file:///etc/passwd"));
    }

    #[test]
    fn client_links_stay_in_the_client() {
        assert!(client_url("roblox://experiences/start?placeId=1"));
        assert!(client_url("roblox-player://1+"));
        assert!(client_url("ROBLOX://games/1"));
        assert!(!client_url("roblox:"));
        assert!(!client_url("https://roblox.com/"));
        assert!(!client_url("notroblox://x"));
    }

    #[test]
    fn agent_ends_up_a_mac() {
        let base = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/605.1.15 \
                     (KHTML, like Gecko) WebKitGTK/2.52.6";
        let agent = format!("{base} RobloxApp/2.0 Roblox/DarwinRobloxApp/");
        let fixed = compatible_user_agent(&agent);
        assert!(fixed.contains("(Macintosh; Intel Mac OS X 10_15_7)"));
        assert!(!fixed.contains("(X11; Linux x86_64)"));
        assert!(!fixed.contains("Roblox/DarwinRobloxApp/"));
        assert!(fixed.contains("Roblox/Darwin RobloxApp/"));
    }

    #[test]
    fn header_rules_hold() {
        assert!(header_ok("X-Roblox-Checkpoint", "abc 123\ttab"));
        assert!(!header_ok("Host", "example.com"));
        assert!(!header_ok("Content-Length", "5"));
        assert!(!header_ok("Bad Header", "x"));
        assert!(!header_ok("", "x"));
        assert!(!header_ok("X", "line\nbreak"));
        assert!(!header_ok("X", &"v".repeat(20_000)));
    }

    #[test]
    fn json_truthiness_matches_python() {
        assert!(truthy(Some(&json!("x"))));
        assert!(truthy(Some(&json!(1))));
        assert!(truthy(Some(&json!(true))));
        assert!(truthy(Some(&json!([0]))));
        assert!(!truthy(Some(&json!(""))));
        assert!(!truthy(Some(&json!(0))));
        assert!(!truthy(Some(&json!(false))));
        assert!(!truthy(Some(&Value::Null)));
        assert!(!truthy(None));
    }
}
