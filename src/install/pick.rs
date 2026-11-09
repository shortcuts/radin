use super::ui::{Ui, RAT};
use crossterm::event::{self, Event, KeyCode, KeyEventKind, KeyModifiers};
use crossterm::terminal;
use std::collections::VecDeque;
use std::io::{self, BufRead, Write};

pub enum Answer<T> {
    Value(T),
    Back,
}

pub struct Abort;

/// Where answers come from: the terminal, or the lines piped to stdin.
pub struct Input {
    pub tty: bool,
    queued: VecDeque<String>,
}

impl Input {
    pub fn new(tty: bool, stdin: &str) -> Input {
        Input {
            tty,
            queued: stdin.lines().map(str::to_string).collect(),
        }
    }

    fn line(&mut self) -> Option<String> {
        if !self.tty {
            return self.queued.pop_front();
        }
        let mut s = String::new();
        (io::stdin().lock().read_line(&mut s).ok()? > 0).then_some(s)
    }
}

struct Raw;

impl Raw {
    fn on() -> io::Result<Raw> {
        terminal::enable_raw_mode()?;
        eprint!("\x1b[?25l");
        Ok(Raw)
    }
}

impl Drop for Raw {
    fn drop(&mut self) {
        eprint!("\x1b[?25h");
        let _ = terminal::disable_raw_mode();
    }
}

enum Key {
    Up,
    Down,
    Right,
    Back,
    Enter,
    Space,
    All,
    Digit(usize),
    Abort,
    Other,
}

fn read_key() -> io::Result<Key> {
    loop {
        let Event::Key(k) = event::read()? else {
            continue;
        };
        if k.kind != KeyEventKind::Press {
            continue;
        }
        let ctrl = k.modifiers.contains(KeyModifiers::CONTROL);
        return Ok(match k.code {
            KeyCode::Char('c' | 'd') if ctrl => Key::Abort,
            KeyCode::Up | KeyCode::Char('k') => Key::Up,
            KeyCode::Down | KeyCode::Char('j') => Key::Down,
            KeyCode::Right => Key::Right,
            KeyCode::Left | KeyCode::Backspace | KeyCode::Delete | KeyCode::Char('b') => Key::Back,
            KeyCode::Enter => Key::Enter,
            KeyCode::Char(' ') => Key::Space,
            KeyCode::Char('a') => Key::All,
            KeyCode::Char(c @ '1'..='9') => Key::Digit(c as usize - '0' as usize),
            _ => Key::Other,
        });
    }
}

fn hint(ui: &Ui, msg: &str, keys: &str, can_back: bool) -> String {
    let back = if can_back { ", left to go back" } else { "" };
    format!(
        "{} {}",
        ui.yellow(&format!("{RAT} {msg}")),
        ui.dim(&format!("({keys}{back})"))
    )
}

fn pick_raw(
    ui: &Ui,
    msg: &str,
    default: usize,
    opts: &[String],
    can_back: bool,
) -> io::Result<Result<Answer<usize>, Abort>> {
    let n = opts.len();
    let mut sel = default;
    let guard = Raw::on()?;
    let mut e = io::stderr();
    write!(
        e,
        "{}\r\n",
        hint(ui, msg, "arrows, enter to confirm", can_back)
    )?;
    let out = loop {
        for (i, o) in opts.iter().enumerate() {
            if i + 1 == sel {
                write!(e, "\r\x1b[K {} {}\r\n", ui.cyan(">"), ui.bold(o))?;
            } else {
                write!(e, "\r\x1b[K   {o}\r\n")?;
            }
        }
        e.flush()?;
        match read_key()? {
            Key::Up => sel = if sel > 1 { sel - 1 } else { n },
            Key::Down | Key::Right => sel = if sel < n { sel + 1 } else { 1 },
            Key::Back if can_back => break Ok(Answer::Back),
            Key::Digit(d) if d <= n => sel = d,
            Key::Enter => break Ok(Answer::Value(sel)),
            Key::Abort => break Err(Abort),
            _ => {}
        }
        write!(e, "\x1b[{n}A")?;
    };
    write!(e, "\x1b[{}A\r\x1b[J", n + 1)?;
    drop(guard);
    Ok(out)
}

fn numbered(ui: &Ui, inp: &mut Input, msg: &str, default: usize, opts: &[String]) -> usize {
    eprintln!("{}", ui.yellow(&format!("{RAT} {msg}")));
    for (i, o) in opts.iter().enumerate() {
        if i + 1 == default {
            eprintln!(
                "  {}) {o} {}",
                ui.bold(&(i + 1).to_string()),
                ui.dim("(default)")
            );
        } else {
            eprintln!("  {}) {o}", ui.bold(&(i + 1).to_string()));
        }
    }
    eprint!(
        "{} ",
        ui.yellow(&format!("{RAT} Pick 1-{} [{default}]", opts.len()))
    );
    let _ = io::stderr().flush();
    let n = inp
        .line()
        .and_then(|l| l.trim().parse::<usize>().ok())
        .unwrap_or(default);
    if n < 1 || n > opts.len() {
        default
    } else {
        n
    }
}

/// Picks one option and returns its 1-based position. `yes` takes the default without asking.
pub fn pick(
    ui: &Ui,
    inp: &mut Input,
    yes: bool,
    msg: &str,
    default: usize,
    opts: &[String],
    can_back: bool,
) -> Result<Answer<usize>, Abort> {
    if yes {
        return Ok(Answer::Value(default));
    }
    if inp.tty {
        if let Ok(r) = pick_raw(ui, msg, default, opts, can_back) {
            return r;
        }
    }
    Ok(Answer::Value(numbered(ui, inp, msg, default, opts)))
}

/// Checkbox list of `(id, label)`. Returns the ticked ids in item order.
pub fn check(
    ui: &Ui,
    msg: &str,
    items: &[(String, String)],
    checked: &[String],
    can_back: bool,
) -> Result<Answer<Vec<String>>, Abort> {
    let n = items.len();
    let mut on: Vec<String> = checked.to_vec();
    let Ok(guard) = Raw::on() else {
        return Ok(Answer::Value(checked.to_vec()));
    };
    let mut e = io::stderr();
    let mut sel = 1;
    let mut note = "";
    let io_err = |_| Abort;
    write!(
        e,
        "{}\r\n",
        hint(
            ui,
            msg,
            "space to tick, a for all, enter to confirm",
            can_back
        )
    )
    .map_err(io_err)?;
    let out = loop {
        for (i, (id, label)) in items.iter().enumerate() {
            let box_ = if on.contains(id) {
                ui.green("[x]")
            } else {
                "[ ]".to_string()
            };
            if i + 1 == sel {
                write!(e, "\r\x1b[K {} {box_} {}\r\n", ui.cyan(">"), ui.bold(label))
            } else {
                write!(e, "\r\x1b[K   {box_} {label}\r\n")
            }
            .map_err(io_err)?;
        }
        write!(e, "\r\x1b[K{}\r\n", ui.red(note)).map_err(io_err)?;
        note = "";
        e.flush().map_err(io_err)?;
        match read_key().map_err(io_err)? {
            Key::Up => sel = if sel > 1 { sel - 1 } else { n },
            Key::Down => sel = if sel < n { sel + 1 } else { 1 },
            Key::Space => {
                let id = &items[sel - 1].0;
                match on.iter().position(|x| x == id) {
                    Some(p) => {
                        on.remove(p);
                    }
                    None => on.push(id.clone()),
                }
            }
            Key::All => {
                if items.iter().all(|i| on.contains(&i.0)) {
                    on.clear();
                } else {
                    on = items.iter().map(|i| i.0.clone()).collect();
                }
            }
            Key::Back if can_back => break Ok(Answer::Back),
            Key::Enter if !on.is_empty() => {
                break Ok(Answer::Value(
                    items
                        .iter()
                        .filter(|i| on.contains(&i.0))
                        .map(|i| i.0.clone())
                        .collect(),
                ))
            }
            Key::Enter => note = "   pick at least one host",
            Key::Abort => break Err(Abort),
            _ => {}
        }
        write!(e, "\x1b[{}A", n + 1).map_err(io_err)?;
    };
    write!(e, "\x1b[{}A\r\x1b[J", n + 2).map_err(io_err)?;
    drop(guard);
    out
}
