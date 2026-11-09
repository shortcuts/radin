use super::Session;
use std::fs;
use std::io;
use std::path::Path;

const BEGIN: &str = "<!-- radin:begin -->";
const END: &str = "<!-- radin:end -->";

/// Replaces the radin block of `file` with `body`, keeping every other line, so a re-run adds no blank line.
pub fn write_guidance(file: &Path, body: &str) -> io::Result<()> {
    let text = fs::read_to_string(file).unwrap_or_default();
    let mut kept: Vec<&str> = vec![];
    let mut skip = false;
    for l in text.lines() {
        skip |= l == BEGIN;
        if !skip {
            kept.push(l);
        }
        skip &= l != END;
    }
    while kept.last().is_some_and(|l| l.trim().is_empty()) {
        kept.pop();
    }
    let mut out = String::new();
    if !kept.is_empty() {
        out = kept.join("\n") + "\n\n";
    }
    out += body;
    out.push('\n');
    if let Some(d) = file.parent() {
        fs::create_dir_all(d)?;
    }
    fs::write(file, out)
}

impl Session<'_> {
    pub(super) fn claude_body(&self) -> String {
        let cli = &self.cli_value;
        format!(
            "{BEGIN}
## radin

radin keeps a per-repo backlog in `<repo-root>/.radin/` so tasks
survive past one conversation. Reach for it instead of ad-hoc task tracking:

- A bug, idea, or follow-up comes up mid-session: record it with `/radin-record`.
- The user asks what is pending: run `{cli} backlog show` and print its output. One entry needs a plan first: `/radin-plan`.
- The user wants the backlog worked through: `/radin-batch` (it plans the entries `/radin-record` flagged, then executes), or `/radin-do <prompt>` for one ad-hoc task. A code review whose findings should become tasks: `/radin-review`.
- The user asks to mark a task done by hand: run `{cli} state task-done <id> <commit-hash>` (hash from `git rev-parse --short=12 HEAD`). `backlog --help` and `state --help` list every verb.
- Never hand-edit files under `.radin/` -- every backlog operation goes through the `{cli} backlog` CLI.
- Never guess on a broad or ambiguous ask: invoke `/mattpocock-skills:grilling` and let the user settle it before radin writes anything.
{END}"
        )
    }

    pub(super) fn agents_body(&self) -> String {
        let cli = &self.cli_value;
        format!(
            "{BEGIN}
## radin

radin keeps a per-repo backlog in `<repo-root>/.radin/` so tasks
survive past one conversation. Reach for it instead of ad-hoc task tracking:

- A bug, idea, or follow-up comes up mid-session: record it with the `radin-record` skill.
- The user asks what is pending: run `{cli} --host agents backlog show` and print its output. One entry needs a plan first: `radin-plan` skill.
- The user wants the backlog worked through: `radin-batch` skill (it plans the entries `radin-record` flagged, then executes), or `radin-do` skill for one ad-hoc task. A code review whose findings should become tasks: `radin-review` skill.
- The user asks to mark a task done by hand: run `{cli} --host agents state task-done <id> <commit-hash>` (hash from `git rev-parse --short=12 HEAD`). `backlog --help` and `state --help` list every verb.
- Never hand-edit files under `.radin/`. Every backlog operation goes through the `{cli} --host agents backlog` CLI.
- Never guess on a broad or ambiguous ask: use the `grilling` skill and let the user settle it before radin writes anything.
{END}"
        )
    }

    pub(super) fn write_block(&self, file: &Path, body: &str) -> Result<(), super::Stop> {
        write_guidance(file, body)?;
        self.ui.ok(&format!(
            "radin section written to {} (between radin:begin/end markers)",
            self.ui.bold(&file.display().to_string())
        ));
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keeps_foreign_lines_and_never_grows() {
        let d = tempfile::tempdir().unwrap();
        let f = d.path().join("CLAUDE.md");
        fs::write(&f, "mine\n\n<!-- rtk:begin -->\nx\n<!-- rtk:end -->\n\n").unwrap();
        write_guidance(&f, &format!("{BEGIN}\nbody\n{END}")).unwrap();
        let once = fs::read_to_string(&f).unwrap();
        assert_eq!(
            once,
            "mine\n\n<!-- rtk:begin -->\nx\n<!-- rtk:end -->\n\n<!-- radin:begin -->\nbody\n<!-- radin:end -->\n"
        );
        write_guidance(&f, &format!("{BEGIN}\nbody\n{END}")).unwrap();
        assert_eq!(fs::read_to_string(&f).unwrap(), once);
    }
}
