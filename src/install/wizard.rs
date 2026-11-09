use super::assets::{host, host_ids, HOSTS_TABLE};
use super::pick::{check, pick, Abort, Answer};
use super::Session;

const MODELS: [&str; 4] = ["fable", "opus", "sonnet", "haiku"];
const SONNET_INDEX: usize = 3;
const HAIKU_INDEX: usize = 4;

enum Models {
    Back,
    Default,
    Pick(String, String),
}

fn label(step: &str) -> &'static str {
    match step {
        "hosts" => "Hosts",
        "models" => "Models",
        _ => "Package manager",
    }
}

fn rep(n: usize) -> String {
    "─".repeat(n)
}

fn row(label: &str, value: &str) -> String {
    format!("{label:<16} {value}")
}

impl Session<'_> {
    pub(super) fn host_detected(&self, id: &str) -> bool {
        if id == "claude" && self.claude.is_dir() {
            return true;
        }
        host(id).is_some_and(|h| self.which(h.3).is_some())
    }

    fn detected(&self) -> Vec<&'static str> {
        host_ids()
            .into_iter()
            .filter(|id| self.host_detected(id))
            .collect()
    }

    fn have_tty(&self) -> bool {
        !self.o.yes && self.input.tty
    }

    fn wiz_steps(&self) -> Vec<&'static str> {
        let mut steps = vec![];
        if !self.o.update {
            if self.o.only.is_none() && self.have_tty() {
                let d = self.detected();
                if !(d.is_empty() || d == ["claude"]) {
                    steps.push("hosts");
                }
            }
            if self.is_selected("claude") {
                steps.push("models");
            }
            if self.brew.is_some() || self.mise.is_some() {
                steps.push("pkg");
            }
        }
        steps
    }

    fn header(&self, pos: usize, total: usize, names: &[&str]) {
        let ui = &self.ui;
        let parts: Vec<String> = names
            .iter()
            .enumerate()
            .map(|(i, n)| match (i + 1).cmp(&pos) {
                std::cmp::Ordering::Less => ui.green(label(n)),
                std::cmp::Ordering::Equal => ui.paint("1;36", label(n)),
                std::cmp::Ordering::Greater => ui.dim(label(n)),
            })
            .collect();
        println!(
            "\n{}  {}\n",
            ui.bold(&format!("Step {pos}/{total}")),
            parts.join(" > ")
        );
    }

    fn pick_one(
        &mut self,
        msg: &str,
        default: usize,
        opts: &[String],
        can_back: bool,
    ) -> Result<Answer<usize>, Abort> {
        pick(
            &self.ui,
            &mut self.input,
            self.o.yes,
            msg,
            default,
            opts,
            can_back,
        )
    }

    fn wiz_models(&mut self, outer_back: bool) -> Result<Models, Abort> {
        let names: Vec<String> = MODELS.iter().map(|m| m.to_string()).collect();
        let (mut st, mut major) = (1, String::new());
        loop {
            match st {
                1 => {
                    let msg = "Choose radin-batch's sub-agent models? (defaults: sonnet, haiku for fact-finding)";
                    let opts = ["yes".to_string(), "no".to_string()];
                    match self.pick_one(msg, 2, &opts, outer_back)? {
                        Answer::Back => return Ok(Models::Back),
                        Answer::Value(1) => st = 2,
                        Answer::Value(_) => return Ok(Models::Default),
                    }
                }
                2 => {
                    let msg = "planning, execution, review and debug sub-agents";
                    match self.pick_one(msg, SONNET_INDEX, &names, true)? {
                        Answer::Back => st = 1,
                        Answer::Value(i) => {
                            major = MODELS[i - 1].to_string();
                            st = 3;
                        }
                    }
                }
                _ => {
                    let msg = "fact-finding sub-agents";
                    match self.pick_one(msg, HAIKU_INDEX, &names, true)? {
                        Answer::Back => st = 2,
                        Answer::Value(i) => {
                            return Ok(Models::Pick(major, MODELS[i - 1].to_string()))
                        }
                    }
                }
            }
        }
    }

    fn wiz_pkg(&mut self, can_back: bool) -> Result<Answer<String>, Abort> {
        let mut opts = vec![];
        if self.brew.is_some() {
            opts.push("brew".to_string());
        }
        if self.mise.is_some() {
            opts.push("mise".to_string());
        }
        opts.push("curl".to_string());
        Ok(
            match self.pick_one("install rtk through", 1, &opts, can_back)? {
                Answer::Back => Answer::Back,
                Answer::Value(i) => Answer::Value(opts[i - 1].clone()),
            },
        )
    }

    pub(super) fn review_box(&self, title: &str) {
        let ui = &self.ui;
        let hosts: Vec<&str> = self
            .selected
            .iter()
            .filter_map(|id| host(id).map(|h| h.1))
            .collect();
        let mut rows = vec![row("Hosts", &hosts.join(", "))];
        if self.is_selected("claude") {
            rows.push(row(
                "Models",
                &format!("{}: planning, execution, review, debug", self.major),
            ));
            rows.push(row("", &format!("{}: fact-finding", self.minor)));
        } else {
            rows.push(row("Models", "n/a, Claude Code not selected"));
        }
        rows.push(row(
            "Concurrency",
            &format!("{} tasks at once", self.wave_cap),
        ));
        rows.push(row("Package manager", &self.pkg));
        let into = self.rh.strip_prefix(&self.home).unwrap_or(&self.rh);
        rows.push(row("Install into", &format!("~/{}", into.display())));
        let w = rows
            .iter()
            .map(|r| r.chars().count())
            .chain([title.chars().count()])
            .max()
            .unwrap();
        let tl = title.chars().count();
        println!(
            "{} {} {}",
            ui.cyan("┌─"),
            ui.bold(title),
            ui.cyan(&format!("{}┐", rep(w - tl - 1)))
        );
        for r in &rows {
            let pad = " ".repeat(w - r.chars().count());
            println!("{} {r}{pad} {}", ui.cyan("│"), ui.cyan("│"));
        }
        println!("{}", ui.cyan(&format!("└{}┘", rep(w + 2))));
    }

    /// Asks every question before the first write and prints the Review or Recap box.
    pub(super) fn wizard(&mut self) -> Result<(), Abort> {
        let interactive = self.have_tty();
        let mut checked: Vec<String> = if self.detected().contains(&"claude") {
            vec!["claude".into()]
        } else {
            vec![]
        };
        let mut pos = 1usize;
        loop {
            let steps = self.wiz_steps();
            if pos > steps.len() {
                self.review_box(if self.o.update { "Recap" } else { "Review" });
                return Ok(());
            }
            let name = steps[pos - 1];
            let can_back = pos > 1;
            let drawn = interactive && !self.o.update;
            if drawn {
                self.header(pos, steps.len(), &steps);
            }
            let back = match name {
                "hosts" => self.step_hosts(&mut checked, can_back)?,
                "models" => self.step_models(can_back)?,
                _ => match self.wiz_pkg(can_back)? {
                    Answer::Back => true,
                    Answer::Value(p) => {
                        self.pkg = p;
                        false
                    }
                },
            };
            pos = if back {
                pos.saturating_sub(1).max(1)
            } else {
                pos + 1
            };
            if drawn {
                print!("\x1b[3A\r\x1b[J");
            }
        }
    }

    fn step_hosts(&mut self, checked: &mut Vec<String>, can_back: bool) -> Result<bool, Abort> {
        let items: Vec<(String, String)> = self
            .detected()
            .into_iter()
            .map(|id| (id.to_string(), host(id).unwrap().1.to_string()))
            .collect();
        match check(&self.ui, "Install radin for", &items, checked, can_back)? {
            Answer::Back => Ok(true),
            Answer::Value(ids) => {
                *checked = ids.clone();
                self.selected = HOSTS_TABLE
                    .iter()
                    .map(|h| h.0)
                    .filter(|id| ids.iter().any(|i| i == id))
                    .collect();
                Ok(false)
            }
        }
    }

    fn step_models(&mut self, can_back: bool) -> Result<bool, Abort> {
        match self.wiz_models(can_back)? {
            Models::Back => return Ok(true),
            Models::Default => {
                self.models_picked = false;
                self.major = "sonnet".into();
                self.minor = "haiku".into();
            }
            Models::Pick(a, b) => {
                self.models_picked = true;
                self.major = a;
                self.minor = b;
            }
        }
        Ok(false)
    }
}
