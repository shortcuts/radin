use std::io::{IsTerminal, Write};
use std::time::Instant;

pub const RAT: &str = "🐀";

pub struct Ui {
    color: bool,
    tty_out: bool,
    pub loud: bool,
    pub verbose: bool,
    step_n: usize,
    step_total: usize,
    step_name: Option<String>,
    step_t0: Instant,
    t0: Instant,
}

impl Ui {
    pub fn new(loud: bool, verbose: bool, step_total: usize) -> Ui {
        let tty_out = std::io::stdout().is_terminal();
        Ui {
            color: tty_out,
            tty_out,
            loud: loud || verbose,
            verbose,
            step_n: 0,
            step_total,
            step_name: None,
            step_t0: Instant::now(),
            t0: Instant::now(),
        }
    }

    pub fn paint(&self, code: &str, text: &str) -> String {
        if self.color {
            format!("\x1b[{code}m{text}\x1b[0m")
        } else {
            text.to_string()
        }
    }
    pub fn bold(&self, t: &str) -> String {
        self.paint("1", t)
    }
    pub fn dim(&self, t: &str) -> String {
        self.paint("2", t)
    }
    pub fn red(&self, t: &str) -> String {
        self.paint("31", t)
    }
    pub fn green(&self, t: &str) -> String {
        self.paint("32", t)
    }
    pub fn yellow(&self, t: &str) -> String {
        self.paint("33", t)
    }
    pub fn cyan(&self, t: &str) -> String {
        self.paint("36", t)
    }

    fn clear_line(&self) {
        if self.tty_out {
            print!("\r\x1b[K");
        }
    }

    pub fn say(&self, msg: &str) {
        self.clear_line();
        println!("{} {msg}", self.cyan(RAT));
    }
    pub fn info(&self, msg: &str) {
        if self.loud {
            self.say(msg);
        }
    }
    pub fn ok(&self, msg: &str) {
        if self.loud {
            println!("{} {msg}", self.green(RAT));
        }
    }
    pub fn warn(&self, msg: &str) {
        self.clear_line();
        println!("{} {msg}", self.yellow(RAT));
    }
    pub fn err(&self, msg: &str) {
        eprintln!("{}", self.red(&format!("{RAT} {msg}")));
    }

    pub fn finish_step(&mut self) {
        let Some(name) = self.step_name.take() else {
            return;
        };
        if !self.loud {
            self.clear_line();
            let secs = self.step_t0.elapsed().as_secs();
            println!(
                "{} {name} {}",
                self.green("✓"),
                self.dim(&format!("({secs}s)"))
            );
        }
    }

    pub fn step(&mut self, name: &str) {
        self.finish_step();
        self.step_n += 1;
        self.step_name = Some(name.to_string());
        self.step_t0 = Instant::now();
        if self.loud {
            let line = format!("{RAT} [{}/{}] {name}", self.step_n, self.step_total);
            println!("\n{}", self.paint("1;35", &line));
        } else if self.tty_out {
            print!("{}", self.dim(&format!("▸ {name}…")));
            let _ = std::io::stdout().flush();
        }
    }

    pub fn elapsed(&self) -> u64 {
        self.t0.elapsed().as_secs()
    }

    pub fn banner(&self) {
        println!(
            "\n{}",
            self.paint(
                "1;35",
                "  🐀 radin — stingy on tokens, generous on backlog throughput"
            )
        );
        println!(
            "{}\n",
            self.dim("  Installs backlog-workflow skills into ~/.claude, plus the whole curated\n  token-saving stack. Only execution behaviour and your package manager are asked about.")
        );
    }
}
