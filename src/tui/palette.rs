use ratatui::style::{Color, Modifier, Style};

/// Every style the frame paints, picked once at startup: 256 colours where `TERM` or `COLORTERM` says so, else the 16 every terminal has.
#[derive(Clone)]
pub struct Palette {
    pub color: bool,
    pub sel: Style,
    pub bar: Style,
    pub key: Style,
    pub title: Style,
    pub border: Style,
    pub dim: Style,
    pub epic: Style,
    /// 21/13, 8/5, 3/2/1.
    pub prio: [Style; 3],
    /// feat, fix, chore, refactor, then an unknown category.
    pub cat: [Style; 5],
}

fn fg(i: u8) -> Style {
    Style::new().fg(Color::Indexed(i))
}

impl Palette {
    pub fn from_env(env: &dyn Fn(&str) -> Option<String>) -> Palette {
        let set = |k: &str| env(k).filter(|v| !v.is_empty());
        if set("NO_COLOR").is_some() {
            Palette::none()
        } else if set("TERM").is_some_and(|t| t.contains("256")) || set("COLORTERM").is_some() {
            Palette::p256()
        } else {
            Palette::p16()
        }
    }

    pub fn p256() -> Palette {
        Palette {
            color: true,
            sel: fg(231).bg(Color::Indexed(25)).bold(),
            bar: fg(252).bg(Color::Indexed(236)),
            key: fg(214).bold(),
            title: fg(117).bold(),
            border: fg(240),
            dim: fg(244),
            epic: fg(117).bold(),
            prio: [fg(203), fg(221), fg(114)],
            cat: [fg(75), fg(211), fg(246), fg(141), Style::new()],
        }
    }

    pub fn p16() -> Palette {
        let c = |c: Color| Style::new().fg(c);
        Palette {
            color: true,
            sel: c(Color::White).bg(Color::Blue).bold(),
            bar: c(Color::White).bg(Color::DarkGray),
            key: c(Color::LightYellow).bold(),
            title: c(Color::LightCyan).bold(),
            border: c(Color::DarkGray),
            dim: Style::new().add_modifier(Modifier::DIM),
            epic: c(Color::Cyan).bold(),
            prio: [c(Color::Red), c(Color::Yellow), c(Color::Green)],
            cat: [
                c(Color::Blue),
                c(Color::Magenta),
                c(Color::DarkGray),
                c(Color::LightBlue),
                Style::new(),
            ],
        }
    }

    /// Keeps bold, dim and reverse video so selection, bars and epic headers still read.
    pub fn none() -> Palette {
        let m = |m: Modifier| Style::new().add_modifier(m);
        Palette {
            color: false,
            sel: m(Modifier::BOLD | Modifier::REVERSED),
            bar: m(Modifier::REVERSED),
            key: m(Modifier::BOLD),
            title: m(Modifier::BOLD),
            border: Style::new(),
            dim: m(Modifier::DIM),
            epic: m(Modifier::BOLD),
            prio: [Style::new(); 3],
            cat: [Style::new(); 5],
        }
    }

    /// A fixed map over the Fibonacci scale, so an unrelated task's number cannot move this one's colour.
    pub fn prio_style(&self, prio: &str) -> Style {
        match prio {
            "13" | "21" => self.prio[0],
            "5" | "8" => self.prio[1],
            "1" | "2" | "3" => self.prio[2],
            _ => Style::new(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn env(pairs: &'static [(&'static str, &'static str)]) -> impl Fn(&str) -> Option<String> {
        move |k| {
            pairs
                .iter()
                .find(|(n, _)| *n == k)
                .map(|(_, v)| v.to_string())
        }
    }

    #[test]
    fn no_color_drops_every_priority_colour() {
        let p = Palette::from_env(&env(&[("NO_COLOR", "1"), ("TERM", "xterm-256color")]));
        for n in ["1", "5", "13", "21", "7"] {
            assert_eq!(p.prio_style(n), Style::new(), "{n}");
        }
        assert!(!p.color);
    }

    #[test]
    fn empty_no_color_is_ignored() {
        assert!(Palette::from_env(&env(&[("NO_COLOR", "")])).color);
    }

    #[test]
    fn term_256_or_colorterm_picks_the_256_palette() {
        assert_eq!(
            Palette::from_env(&env(&[("TERM", "xterm-256color")])).border,
            fg(240)
        );
        assert_eq!(
            Palette::from_env(&env(&[("COLORTERM", "truecolor")])).border,
            fg(240)
        );
        assert_eq!(
            Palette::from_env(&env(&[("TERM", "xterm")])).border,
            Palette::p16().border
        );
    }

    #[test]
    fn priority_map_is_absolute() {
        let p = Palette::p256();
        assert_eq!(p.prio_style("21"), p.prio_style("13"));
        assert_eq!(p.prio_style("8"), p.prio[1]);
        assert_eq!(p.prio_style("2"), p.prio[2]);
        assert_eq!(p.prio_style("4"), Style::new());
        assert_eq!(p.prio_style(""), Style::new());
    }
}
