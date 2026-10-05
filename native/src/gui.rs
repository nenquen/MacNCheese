//! Native window frontend: the same ratatui UI rendered by the GPU.
//!
//! No terminal emulator involved: winit window + ratatui-wgpu backend.
//! Opens like a program, feels like the TUI.

use ratatui::backend::Backend;
use ratatui_wgpu::{Builder, Dimensions, Font, WgpuBackend};
use std::num::NonZeroU32;
use std::sync::Arc;
use std::time::{Duration, Instant};
use winit::{
    application::ApplicationHandler,
    event::{ElementState, KeyEvent, MouseButton, WindowEvent},
    event_loop::{ActiveEventLoop, ControlFlow, EventLoop},
    keyboard::{Key as WKey, NamedKey},
    window::{Icon, Window, WindowAttributes},
};

use crate::{ui, App, Input, Key, KeyAction};

const WIN_W: u32 = 1000;
const WIN_H: u32 = 680;

fn nz(v: u32) -> NonZeroU32 {
    NonZeroU32::new(v.max(1)).unwrap()
}

/// Wayland app_id matching our .desktop file, so the compositor shows the
/// cheese icon instead of the generic Wayland one.
#[cfg(target_os = "linux")]
fn with_app_id(attrs: WindowAttributes) -> WindowAttributes {
    use winit::platform::wayland::WindowAttributesExtWayland;
    attrs.with_name("org.macncheese.MacNCheese", "macncheese")
}

#[cfg(not(target_os = "linux"))]
fn with_app_id(attrs: WindowAttributes) -> WindowAttributes {
    attrs
}

fn find_mono_font(_preferred: &str) -> Option<Vec<u8>> {
    let mut candidates = vec![];
    let pattern = "monospace".to_string();
    if let Ok(out) = std::process::Command::new("fc-match")
        .args([&pattern, "--format=%{file}"])
        .output()
    {
        candidates.push(String::from_utf8_lossy(&out.stdout).trim().to_string());
    }
    candidates.extend(
        [
            "/usr/share/fonts/TTF/JetBrainsMono-Regular.ttf",
            "/usr/share/fonts/TTF/DejaVuSansMono.ttf",
            "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
            "/usr/share/fonts/TTF/NotoSansMono-Regular.ttf",
        ]
        .iter()
        .map(|s| s.to_string()),
    );
    candidates.into_iter().find_map(|p| std::fs::read(p).ok())
}

fn window_icon() -> Option<Icon> {
    let bytes = include_bytes!("../../branding/icons/macncheese-64.png");
    let decoder = png::Decoder::new(&bytes[..]);
    let mut reader = decoder.read_info().ok()?;
    let mut buf = vec![0u8; reader.output_buffer_size()];
    let info = reader.next_frame(&mut buf).ok()?;
    if info.color_type != png::ColorType::Rgba {
        return None;
    }
    Icon::from_rgba(buf, info.width, info.height).ok()
}

fn to_key(event: &KeyEvent) -> Option<Key> {
    match &event.logical_key {
        WKey::Named(NamedKey::ArrowUp) => Some(Key::Up),
        WKey::Named(NamedKey::ArrowDown) => Some(Key::Down),
        WKey::Named(NamedKey::ArrowLeft) => Some(Key::Left),
        WKey::Named(NamedKey::ArrowRight) => Some(Key::Right),
        WKey::Named(NamedKey::Enter) => Some(Key::Enter),
        WKey::Named(NamedKey::Escape) => Some(Key::Esc),
        WKey::Named(NamedKey::Tab) => Some(Key::Tab),
        WKey::Named(NamedKey::PageUp) => Some(Key::PageUp),
        WKey::Named(NamedKey::PageDown) => Some(Key::PageDown),
        WKey::Named(NamedKey::Backspace) => Some(Key::Backspace),
        WKey::Character(s) => s.chars().next().map(Key::Char),
        _ => None,
    }
}

struct Gui {
    window: Option<Arc<Window>>,
    backend: Option<ratatui::Terminal<WgpuBackend<'static, 'static>>>,
    app: App,
    cursor: (f32, f32),
    win_px: (u32, u32),
}

impl Gui {
    fn grid(&mut self) -> (u16, u16, f32, f32) {
        // Columns/rows and pixel size straight from the backend.
        let (cols, rows, px_w, px_h) = self
            .backend
            .as_mut()
            .and_then(|t| t.backend_mut().window_size().ok())
            .map(|s| {
                (
                    s.columns_rows.width.max(1),
                    s.columns_rows.height.max(1),
                    s.pixels.width.max(1) as f32,
                    s.pixels.height.max(1) as f32,
                )
            })
            .unwrap_or((100, 30, self.win_px.0 as f32, self.win_px.1 as f32));
        (cols, rows, px_w / cols as f32, px_h / rows as f32)
    }

    fn click_cell(&mut self) -> (u16, u16) {
        let (cols, rows, cw, ch) = self.grid();
        let (x, y) = self.cursor;
        (
            ((x / cw.max(1.0)) as u16).min(cols.saturating_sub(1)),
            ((y / ch.max(1.0)) as u16).min(rows.saturating_sub(1)),
        )
    }

    fn redraw(&mut self) {
        if let Some(term) = self.backend.as_mut() {
            self.app.tick();
            self.app.clicks.clear();
            let app = &mut self.app;
            let _ = term.draw(|f| ui(f, app));
        }
        if let Some(w) = self.window.as_ref() {
            w.request_redraw();
        }
    }

    fn handle(&mut self, action: KeyAction, el: &ActiveEventLoop) {
        match action {
            KeyAction::Quit => {
                if let Some(mut s) = self.app.session.take() {
                    s.finish();
                }
                el.exit();
            }
            KeyAction::None => {}
        }
    }
}

impl ApplicationHandler for Gui {
    fn resumed(&mut self, el: &ActiveEventLoop) {
        if self.window.is_some() {
            return;
        }
        let mut attrs = WindowAttributes::default()
            .with_title("Mac'n Cheese")
            .with_inner_size(winit::dpi::LogicalSize::new(WIN_W, WIN_H));
        attrs = with_app_id(attrs);
        if let Some(icon) = window_icon() {
            attrs = attrs.with_window_icon(Some(icon));
        }
        let window = Arc::new(el.create_window(attrs).unwrap());
        let stored = crate::settings::load();
        // Family is always the system monospace; only the scale is adjustable.
        let font_bytes = find_mono_font("").unwrap_or_else(|| vec![]);
        let font = Font::new(if font_bytes.is_empty() {
            // Last resort: any bytes; backend falls back internally.
            Box::leak(vec![0u8; 4].into_boxed_slice())
        } else {
            Box::leak(font_bytes.into_boxed_slice())
        });
        let Some(font) = font else {
            eprintln!("macncheese: no usable monospace font found");
            el.exit();
            return;
        };
        let font_scale = stored
            .get("tui_font_scale")
            .and_then(|v| v.as_f64())
            .unwrap_or(1.0)
            .clamp(0.8, 2.0);
        let mode = stored.get("theme").and_then(|v| v.as_str()).unwrap_or("system");
        let pal = crate::theme::resolve(mode);
        let backend = futures_lite::future::block_on(
            Builder::from_font(font)
                .with_bg_color(pal.bg)
                .with_fg_color(pal.fg)
                .with_font_size_px((17.0 * font_scale) as u32)
                .with_width_and_height(Dimensions { width: nz(WIN_W), height: nz(WIN_H) })
                .build_with_target(window.clone()),
        )
        .unwrap();
        self.backend = Some(ratatui::Terminal::new(backend).unwrap());
        self.window = Some(window);
        self.app.refresh_logs();
        self.redraw();
    }

    fn window_event(
        &mut self,
        el: &ActiveEventLoop,
        _id: winit::window::WindowId,
        event: WindowEvent,
    ) {
        match event {
            WindowEvent::CloseRequested => {
                if let Some(mut s) = self.app.session.take() {
                    s.finish();
                }
                el.exit();
            }
            WindowEvent::Resized(size) => {
                self.win_px = (size.width, size.height);
                if let Some(term) = self.backend.as_mut() {
                    term.backend_mut().resize(size.width.max(1), size.height.max(1));
                }
                self.redraw();
            }
            WindowEvent::KeyboardInput { event, .. } if event.state == ElementState::Pressed => {
                if !event.repeat {
                    if let Some(key) = to_key(&event) {
                        let action = self.app.on_input(Input::Key(key));
                        self.handle(action, el);
                        self.redraw();
                    }
                }
            }
            WindowEvent::CursorMoved { position, .. } => {
                self.cursor = (position.x as f32, position.y as f32);
            }
            WindowEvent::MouseInput { state: ElementState::Pressed, button: MouseButton::Left, .. } => {
                let (col, row) = self.click_cell();
                if std::env::var("MACNCHEESE_CLICK_DEBUG").is_ok() {
                    let (cols, rows, cw, ch) = self.grid();
                    eprintln!(
                        "[click] px=({:.0},{:.0}) grid={cols}x{rows} cell={cw:.1}x{ch:.1} -> ({col},{row}) targets={}",
                        self.cursor.0, self.cursor.1, self.app.clicks.len()
                    );
                }
                let action = self.app.on_click(col, row);
                self.handle(action, el);
                self.redraw();
            }
            WindowEvent::RedrawRequested => {
                self.redraw();
                el.set_control_flow(ControlFlow::WaitUntil(
                    Instant::now() + Duration::from_millis(250),
                ));
            }
            _ => {}
        }
    }

    fn about_to_wait(&mut self, el: &ActiveEventLoop) {
        el.set_control_flow(ControlFlow::WaitUntil(Instant::now() + Duration::from_millis(250)));
        if self.window.is_some() {
            self.redraw();
        }
    }
}

pub fn run() -> anyhow::Result<()> {
    let event_loop = EventLoop::new()?;
    let mut gui = Gui {
        window: None,
        backend: None,
        app: App::new(),
        cursor: (0.0, 0.0),
        win_px: (WIN_W, WIN_H),
    };
    // First-run setup still applies; the Setup tab shows progress.
    event_loop.run_app(&mut gui)?;
    Ok(())
}
