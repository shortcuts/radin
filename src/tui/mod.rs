mod actions;
mod app;
mod detail;
mod frame_writer;
mod model;
mod palette;
mod task;
mod text;
mod view;

pub use app::{App, Effect, Then};
pub use model::{DetView, Mode, Model, Overlay, Row, Sort};
pub use palette::Palette;

use crate::state::Ctx;
use crate::Out;
use anyhow::Result;
use crossterm::event::{self, Event};
use crossterm::terminal::{
    disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen,
};
use crossterm::{cursor, execute};
use frame_writer::FrameWriter;
use ratatui::backend::CrosstermBackend;
use ratatui::Terminal;
use std::io::{stdin, stdout, IsTerminal, Stdout, Write};
use std::panic::{self, AssertUnwindSafe};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

type Term = Terminal<CrosstermBackend<FrameWriter<Stdout>>>;

static SHUTDOWN: AtomicBool = AtomicBool::new(false);

#[cfg(unix)]
extern "C" fn on_signal(_: libc::c_int) {
    SHUTDOWN.store(true, Ordering::SeqCst);
    // crossterm's poll retries on EINTR but wakes on its SIGWINCH handler.
    unsafe { libc::kill(libc::getpid(), libc::SIGWINCH) };
}

#[cfg(unix)]
fn install_signal_handlers() {
    unsafe {
        let mut act: libc::sigaction = std::mem::zeroed();
        act.sa_sigaction = on_signal as extern "C" fn(libc::c_int) as usize;
        libc::sigemptyset(&mut act.sa_mask);
        for sig in [libc::SIGHUP, libc::SIGTERM] {
            libc::sigaction(sig, &act, std::ptr::null_mut());
        }
    }
}

fn restore() {
    let _ = disable_raw_mode();
    let _ = execute!(stdout(), LeaveAlternateScreen, cursor::Show);
}

fn enter() -> Result<()> {
    enable_raw_mode()?;
    execute!(stdout(), EnterAlternateScreen)?;
    Ok(())
}

fn draw_frame(app: &mut App, out: &FrameWriter<Stdout>, terminal: &mut Term) -> Result<()> {
    // Terminals without synchronized output ignore the unknown private mode.
    write!(terminal.backend_mut(), "\x1b[?2026h")?;
    terminal.draw(|f| app.draw(f))?;
    write!(terminal.backend_mut(), "\x1b[?2026l")?;
    out.send()?;
    Ok(())
}

fn run_external(
    app: &mut App,
    program: &str,
    path: &std::path::Path,
    then: Then,
    terminal: &mut Term,
    out: &FrameWriter<Stdout>,
) -> Result<()> {
    restore();
    let _ = std::process::Command::new(program).arg(path).status();
    enter()?;
    // `Terminal::clear` queries the cursor position, which a pty without a terminal emulator never answers.
    *terminal = Terminal::new(CrosstermBackend::new(out.handle()))?;
    app.finished(then);
    Ok(())
}

fn handle(
    app: &mut App,
    effect: Effect,
    terminal: &mut Term,
    out: &FrameWriter<Stdout>,
) -> Result<()> {
    if let Effect::Run {
        program,
        path,
        then,
    } = effect
    {
        run_external(app, &program, &path, then, terminal, out)?;
    }
    Ok(())
}

fn event_loop(
    app: &mut App,
    out: &FrameWriter<Stdout>,
    terminal: &mut Term,
    poll: Duration,
) -> Result<()> {
    while !app.quit() && !SHUTDOWN.load(Ordering::SeqCst) {
        if app.dirty {
            draw_frame(app, out, terminal)?;
        }
        if !event::poll(poll)? {
            app.tick();
            continue;
        }
        let mut next = Some(event::read()?);
        while let Some(ev) = next.take() {
            match ev {
                Event::Resize(w, h) => app.resize(w, h),
                Event::Key(k) => {
                    let motion = app.is_motion(k);
                    let effect = app.key(k);
                    handle(app, effect, terminal, out)?;
                    // A held key queues ~30 events and only the last frame is seen: apply every queued motion, repaint once.
                    while motion && !app.quit() && event::poll(Duration::ZERO)? {
                        match event::read()? {
                            Event::Key(n) if app.is_motion(n) => {
                                app.key(n);
                            }
                            other => {
                                next = Some(other);
                                break;
                            }
                        }
                    }
                }
                _ => {}
            }
        }
    }
    Ok(())
}

fn session(ctx: &Ctx) -> Result<i32> {
    let pal = Palette::from_env(ctx.env);
    let poll = (ctx.env)("RADIN_TUI_POLL_MS")
        .and_then(|v| v.parse::<u64>().ok())
        .filter(|&n| n > 0)
        .unwrap_or(5000);
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs() as i64);
    let mut app = App::new(ctx, pal, now);
    let (w, h) = crossterm::terminal::size()?;
    app.resize(w, h);
    enter()?;
    #[cfg(unix)]
    install_signal_handlers();
    let default_hook = panic::take_hook();
    panic::set_hook(Box::new(move |info| {
        restore();
        default_hook(info);
    }));
    let out = FrameWriter::new(stdout());
    let mut terminal = Terminal::new(CrosstermBackend::new(out.handle()))?;
    let result = panic::catch_unwind(AssertUnwindSafe(|| {
        event_loop(&mut app, &out, &mut terminal, Duration::from_millis(poll))
    }));
    restore();
    match result {
        Ok(r) => r?,
        Err(payload) => panic::resume_unwind(payload),
    }
    Ok(if app.interrupted || SHUTDOWN.load(Ordering::SeqCst) {
        130
    } else {
        0
    })
}

pub fn run(ctx: &Ctx) -> Out {
    if !stdin().is_terminal() || !stdout().is_terminal() {
        let msg =
            "radin tui: needs an interactive terminal; use \"radin backlog show\" when piping\n";
        return (1, String::new(), msg.into());
    }
    match session(ctx) {
        Ok(code) => (code, String::new(), String::new()),
        Err(e) => (1, String::new(), format!("radin tui: {e}\n")),
    }
}
