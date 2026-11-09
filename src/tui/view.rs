use super::app::App;
use super::model::{Mode, Overlay, Row, CATEGORIES};
use super::text::{age_cell, clean, dwidth, fit, wrap_at, MdStyle};
use ratatui::buffer::Buffer;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::Frame;

const HELP: &str = include_str!("help.txt");
const ROW_MAX_LINES: usize = 3;
const KEYS: &str =
    "j/k move  enter open  e edit  v detail  / search  a new  Tab done  ? keys  q quit";

type Span = (usize, usize, Style);

enum Bar {
    Plain,
    Head,
    Keys,
}

fn clip(buf: &Buffer, r: Rect) -> Rect {
    r.intersection(buf.area)
}

/// One row padded to `w` columns in `base`, with column spans restyled on top.
fn line(buf: &mut Buffer, x: usize, y: usize, w: usize, text: &str, base: Style, spans: &[Span]) {
    let area = buf.area;
    if y >= area.height as usize || x >= area.width as usize || w == 0 {
        return;
    }
    let w = w.min(area.width as usize - x);
    buf.set_style(clip(buf, Rect::new(x as u16, y as u16, w as u16, 1)), base);
    buf.set_stringn(x as u16, y as u16, text, w, base);
    for &(at, len, st) in spans {
        if at < w && len > 0 {
            buf.set_style(
                clip(
                    buf,
                    Rect::new((x + at) as u16, y as u16, len.min(w - at) as u16, 1),
                ),
                st,
            );
        }
    }
}

fn bar(buf: &mut Buffer, app: &App, y: usize, text: &str, mode: Bar) {
    let mut spans: Vec<Span> = Vec::new();
    let col = |byte: usize| dwidth(&text[..byte]);
    match mode {
        Bar::Plain => {}
        Bar::Head => {
            let end = text.find("  ").unwrap_or(text.len());
            spans.push((0, dwidth(&text[..end]), app.pal.title));
        }
        Bar::Keys => {
            let mut p = 0;
            while p < text.len() {
                let word = text[p..].find(' ').unwrap_or(text.len() - p);
                spans.push((col(p), dwidth(&text[p..p + word]), app.pal.key));
                let Some(e) = text[p..].find("  ") else { break };
                p += e + text[p + e..].len() - text[p + e..].trim_start_matches(' ').len();
            }
        }
    }
    line(
        buf,
        0,
        y,
        app.size.0 as usize,
        &clean(text),
        app.pal.bar,
        &spans,
    );
}

fn put(buf: &mut Buffer, x: usize, y: usize, text: &str, style: Style) {
    let area = buf.area;
    if y < area.height as usize && x < area.width as usize {
        buf.set_stringn(x as u16, y as u16, text, area.width as usize - x, style);
    }
}

/// A rounded border around the `h` content rows below `top`, `w` columns wide from `x`, its title set into the top edge.
fn boxed(buf: &mut Buffer, app: &App, top: usize, x: usize, h: usize, w: usize, title: &str) {
    if w < 2 {
        return;
    }
    let b = app.pal.border;
    let rule = |n: usize| "\u{2500}".repeat(n);
    put(buf, x, top, &format!("\u{256d}{}\u{256e}", rule(w - 2)), b);
    let tw = dwidth(title) + 2;
    if !title.is_empty() && tw + 3 <= w {
        put(buf, x + 2, top, &format!(" {title} "), app.pal.title);
    }
    for i in 1..=h {
        put(buf, x, top + i, "\u{2502}", b);
        put(buf, x + w - 1, top + i, "\u{2502}", b);
    }
    put(
        buf,
        x,
        top + h + 1,
        &format!("\u{2570}{}\u{256f}", rule(w - 2)),
        b,
    );
}

fn header(app: &App) -> String {
    let m = &app.m;
    let mut h = format!(
        "radin backlog  {} task(s)  sort:{}",
        m.tasks.len(),
        m.sort.name()
    );
    if !m.search.is_empty() {
        h += &format!("  search:\"{}\"", m.search);
    }
    if !m.rows.is_empty() {
        h += &format!("  [{}/{}]", m.sel + 1, m.rows.len());
    }
    let yn = |v: Option<bool>| match v {
        None => "?",
        Some(true) => "yes",
        Some(false) => "no",
    };
    h + &format!("  wt:{} br:{}", yn(m.session.0), yn(m.session.1))
}

struct Prefix {
    text: String,
    at: usize,
}

fn row_prefix(app: &App, i: usize) -> Prefix {
    let m = &app.m;
    let Row::Task(ti) = m.rows[i] else {
        return Prefix {
            text: String::new(),
            at: 0,
        };
    };
    let t = &m.tasks[ti];
    let conn = match (t.epic.is_empty(), m.rows.get(i + 1)) {
        (true, _) => "",
        (false, None | Some(Row::Epic(_))) => "\u{2514}\u{2500}\u{2500} ",
        _ => "\u{251c}\u{2500}\u{2500} ",
    };
    let lead = format!(" {}", if m.search_hit(t) { "* " } else { "  " });
    let cell = |s: &str, w: usize| {
        let s = fit(s, w);
        format!("{s}{}", " ".repeat(w - dwidth(s)))
    };
    let age = age_cell(&t.created, m.now);
    Prefix {
        at: lead.len(),
        text: format!(
            "{lead}{} {} {} {conn}",
            cell(&t.prio, 2),
            cell(&t.cat, 9),
            cell(&age, 4)
        ),
    }
}

/// Screen lines a row needs: an epic header never wraps, a title wraps into the columns right of the prefix, capped at three.
fn row_lines(app: &App, i: usize, iw: usize) -> usize {
    let Row::Task(ti) = app.m.rows[i] else {
        return 1;
    };
    let avail = iw.saturating_sub(dwidth(&row_prefix(app, i).text)).max(8);
    let title = clean(&app.m.tasks[ti].title);
    let mut t = title.as_str();
    let mut n = 0;
    while !t.is_empty() && n < ROW_MAX_LINES {
        t = t[wrap_at(t, avail)..].trim_start_matches(' ');
        n += 1;
    }
    n.max(1)
}

/// Scrolls so every wrapped line of the selected row is on screen.
fn clamp_top(app: &App, h: usize, iw: usize) -> usize {
    let sel = app.m.sel;
    let mut top = app.m.top.min(sel);
    while top < sel {
        let used: usize = (top..=sel).map(|i| row_lines(app, i, iw)).sum();
        if used <= h {
            break;
        }
        top += 1;
    }
    top
}

fn draw_list(buf: &mut Buffer, app: &mut App, lw: usize, list_h: usize) {
    let iw = lw.saturating_sub(2);
    app.m.top = clamp_top(app, list_h, iw);
    let pal = app.pal.clone();
    let mut used = 0;
    if app.m.rows.is_empty() {
        line(
            buf,
            1,
            2,
            iw,
            "  (no tasks) press a to create one",
            Style::new(),
            &[],
        );
        used = 1;
    }
    for i in app.m.top..app.m.rows.len() {
        if used >= list_h {
            break;
        }
        let base = if i == app.m.sel {
            pal.sel
        } else {
            Style::new()
        };
        let ti = match &app.m.rows[i] {
            Row::Epic(e) => {
                let mark = if app.m.collapsed.contains(e) {
                    "+"
                } else {
                    "-"
                };
                let text = clean(&format!(" {mark} epic: {e}  ({})", app.m.kids(e)));
                line(
                    buf,
                    1,
                    2 + used,
                    iw,
                    &text,
                    base,
                    &[(0, dwidth(&text), pal.epic)],
                );
                used += 1;
                continue;
            }
            Row::Task(ti) => *ti,
        };
        let pre = row_prefix(app, i);
        let ind = dwidth(&pre.text);
        let avail = iw.saturating_sub(ind).max(8);
        let dim = if i == app.m.sel {
            Style::new()
        } else {
            pal.dim
        };
        let t = &app.m.tasks[ti];
        let title = clean(&t.title);
        let mut rest = title.as_str();
        for ln in 0..row_lines(app, i, iw) {
            if used >= list_h {
                break;
            }
            let cut = wrap_at(rest, avail);
            let (text, spans) = if ln == 0 {
                let cat_w = dwidth(fit(&t.cat, 9));
                let text = format!("{}{}", pre.text, &rest[..cut]);
                let spans = vec![
                    (pre.at, 2, pal.prio_style(&t.prio)),
                    (
                        pre.at + 3,
                        cat_w,
                        pal.cat[CATEGORIES.iter().position(|c| *c == t.cat).unwrap_or(4)],
                    ),
                    (pre.at + 13, ind - pre.at - 13, dim),
                ];
                (text, spans)
            } else {
                let text = format!("{}{}", " ".repeat(ind), &rest[..cut]);
                let n = dwidth(&text);
                (text, vec![(0, n, dim)])
            };
            line(buf, 1, 2 + used, iw, &text, base, &spans);
            rest = rest[cut..].trim_start_matches(' ');
            used += 1;
        }
    }
}

fn detail_pane(buf: &mut Buffer, app: &mut App, x: usize, width: usize, h: usize) {
    app.m.sync_det_scroll();
    let pal = app.pal.clone();
    let color = pal.color;
    let top = {
        let n = app.m.detail(width).len();
        app.m.det_top = app.m.det_top.min(n.saturating_sub(h));
        app.m.det_top
    };
    let doc = app.m.detail(width).to_vec();
    for i in 0..h {
        let y = 2 + i;
        let Some(l) = doc.get(top + i) else { continue };
        if l.rule {
            put(buf, x, y, &"\u{2500}".repeat(width), pal.border);
            continue;
        }
        let md = match l.style {
            MdStyle::Plain => Style::new(),
            _ if !color => Style::new(),
            MdStyle::Bold => Style::new().add_modifier(Modifier::BOLD),
            MdStyle::Dim => Style::new().add_modifier(Modifier::DIM),
        };
        let span = match (l.mark, l.label) {
            (Some(at), _) => (at, 4, pal.title),
            (None, n) if n > 0 => (0, n, pal.dim),
            _ => (0, dwidth(&l.text), md),
        };
        line(buf, x, y, width, &l.text, Style::new(), &[span]);
    }
}

fn draw_done(buf: &mut Buffer, app: &mut App, list_h: usize) {
    let w = app.size.0 as usize;
    let m = &mut app.m;
    if m.done_sel < m.done_top {
        m.done_top = m.done_sel;
    }
    if m.done_sel >= m.done_top + list_h {
        m.done_top = m.done_sel + 1 - list_h;
    }
    let (top, sel) = (m.done_top, m.done_sel);
    let rows: Vec<String> = m.done.iter().skip(top).take(list_h).cloned().collect();
    let n = m.done.len();
    let pal = app.pal.clone();
    bar(
        buf,
        app,
        0,
        &format!("radin done  {n} completed"),
        Bar::Head,
    );
    if n == 0 {
        line(
            buf,
            1,
            2,
            w.saturating_sub(2),
            "  (nothing completed yet)",
            Style::new(),
            &[],
        );
    }
    for (i, r) in rows.iter().enumerate() {
        let at = r.rfind(' ').map_or(0, |p| dwidth(&r[..p]) + 1);
        let selected = top + i == sel;
        let span = (
            at,
            dwidth(r).saturating_sub(at),
            if selected { Style::new() } else { pal.dim },
        );
        let base = if selected { pal.sel } else { Style::new() };
        line(buf, 1, 2 + i, w.saturating_sub(2), r, base, &[span]);
    }
    boxed(buf, app, 1, 0, list_h, w, "done");
}

fn draw_pick(buf: &mut Buffer, app: &mut App, list_h: usize) {
    let w = app.size.0 as usize;
    let sel_style = app.pal.sel;
    let Overlay::Pick {
        title,
        multi,
        items,
        marked,
        sel,
        top,
        ..
    } = &mut app.m.overlay
    else {
        return;
    };
    if *sel < *top {
        *top = *sel;
    }
    if *sel >= *top + list_h {
        *top = *sel + 1 - list_h;
    }
    let (title, multi, sel, top) = (title.clone(), *multi, *sel, *top);
    let rows: Vec<String> = items
        .iter()
        .skip(top)
        .take(list_h)
        .map(|(v, l)| {
            if multi {
                format!(" [{}] {l}", if marked.contains(v) { "x" } else { " " })
            } else {
                format!("  {l}")
            }
        })
        .collect();
    bar(buf, app, 0, &title, Bar::Head);
    for (i, r) in rows.iter().enumerate() {
        let base = if top + i == sel {
            sel_style
        } else {
            Style::new()
        };
        line(buf, 1, 2 + i, w.saturating_sub(2), &clean(r), base, &[]);
    }
    boxed(buf, app, 1, 0, list_h, w, "");
    let foot = if multi {
        "space mark  enter confirm  q cancel"
    } else {
        "enter select  q cancel"
    };
    bar(buf, app, app.size.1 as usize - 1, foot, Bar::Keys);
}

impl App<'_> {
    /// Draws into `buf` and returns where the terminal cursor goes: the end of the input row, else nowhere.
    pub fn draw_buf(&mut self, buf: &mut Buffer, area: Rect) -> Option<(u16, u16)> {
        self.size = (area.width, area.height);
        let (w, h) = (area.width as usize, area.height as usize);
        let list_h = self.list_h();
        let foot = h.saturating_sub(1);
        if matches!(self.m.overlay, Overlay::Help) {
            for (i, l) in HELP.lines().enumerate() {
                put(buf, 0, i, l, Style::new());
            }
            return None;
        }
        if matches!(self.m.overlay, Overlay::Pick { .. }) {
            draw_pick(buf, self, list_h);
            return None;
        }
        let msg = self.m.msg.take();
        let prompting = matches!(self.m.overlay, Overlay::Category | Overlay::Input { .. });
        let footer = |app: &App, buf: &mut Buffer, text: &str| match &msg {
            _ if prompting => {}
            Some(m) => bar(buf, app, foot, m, Bar::Plain),
            None => bar(buf, app, foot, text, Bar::Keys),
        };
        if matches!(self.m.overlay, Overlay::Detail) {
            bar(buf, self, 0, "detail", Bar::Head);
            detail_pane(buf, self, 1, w.saturating_sub(2), list_h);
            boxed(buf, self, 1, 0, list_h, w, "detail");
            footer(self, buf, "^d/^u scroll  q/esc close");
        } else if self.m.mode == Mode::Done {
            draw_done(buf, self, list_h);
            footer(
                self,
                buf,
                "j/k move  Tab back  R reload  q quit  (read-only)",
            );
        } else {
            let split = self.split_on();
            let lw = if split { w * 2 / 5 } else { w };
            bar(buf, self, 0, &header(self), Bar::Head);
            draw_list(buf, self, lw, list_h);
            if split && !self.m.rows.is_empty() {
                detail_pane(buf, self, lw + 1, w.saturating_sub(lw + 2), list_h);
            }
            boxed(buf, self, 1, 0, list_h, lw, "tasks");
            if split {
                boxed(buf, self, 1, lw, list_h, w - lw, "detail");
            }
            footer(self, buf, KEYS);
        }
        match &self.m.overlay {
            Overlay::Category => {
                let t = "category: [f]eat  [x] fix  [c]hore  [r]efactor  (any other key cancels)";
                line(
                    buf,
                    0,
                    foot,
                    w,
                    t,
                    Style::new().add_modifier(Modifier::BOLD),
                    &[],
                );
            }
            Overlay::Input { label, text, .. } => {
                let s = clean(&format!("{label}{text}"));
                line(buf, 0, foot, w, &s, Style::new(), &[]);
                return Some((dwidth(&s).min(w.saturating_sub(1)) as u16, foot as u16));
            }
            _ => {}
        }
        None
    }

    pub fn draw(&mut self, f: &mut Frame) {
        let area = f.area();
        if let Some(pos) = self.draw_buf(f.buffer_mut(), area) {
            f.set_cursor_position(pos);
        }
        self.dirty = false;
    }
}
