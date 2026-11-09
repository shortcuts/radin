use crate::render;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Host {
    Claude,
    Agents,
}

impl Host {
    pub fn parse(s: &str) -> Option<Host> {
        match s {
            "claude" => Some(Host::Claude),
            "agents" => Some(Host::Agents),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Host::Claude => "claude",
            Host::Agents => "agents",
        }
    }

    pub fn select(
        flag: Option<&str>,
        env: &dyn Fn(&str) -> Option<String>,
    ) -> Result<Host, String> {
        let name = flag
            .filter(|h| !h.is_empty())
            .map(str::to_string)
            .or_else(|| env("RADIN_HOST").filter(|h| !h.is_empty()))
            .unwrap_or_else(|| {
                if env("OPENCODE").as_deref() == Some("1") {
                    "agents"
                } else {
                    "claude"
                }
                .into()
            });
        Host::parse(&name)
            .ok_or_else(|| format!("radin: unknown host '{name}' (expected claude|agents)\n"))
    }

    pub fn skill_name(self, name: &str) -> Result<String, String> {
        render::parse_names(render::embedded_names(self.as_str()).unwrap_or(""))
            .into_iter()
            .find(|(k, v)| k == name && !v.is_empty())
            .map(|(_, v)| v)
            .ok_or_else(|| {
                format!(
                    "radin: unknown skill name '{name}' for host '{}'",
                    self.as_str()
                )
            })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn env<'a>(pairs: &'a [(&'a str, &'a str)]) -> impl Fn(&str) -> Option<String> + 'a {
        move |k| {
            pairs
                .iter()
                .find(|(n, _)| *n == k)
                .map(|(_, v)| v.to_string())
        }
    }

    fn unknown(h: &str) -> String {
        format!("radin: unknown host '{h}' (expected claude|agents)\n")
    }

    #[test]
    fn flag_beats_env_and_opencode() {
        let e = env(&[("RADIN_HOST", "bogus"), ("OPENCODE", "1")]);
        assert_eq!(Host::select(Some("claude"), &e), Ok(Host::Claude));
        assert_eq!(Host::select(Some("agents"), &env(&[])), Ok(Host::Agents));
    }

    #[test]
    fn env_beats_opencode() {
        let e = env(&[("RADIN_HOST", "bogus"), ("OPENCODE", "1")]);
        assert_eq!(Host::select(None, &e), Err(unknown("bogus")));
        let e = env(&[("RADIN_HOST", "claude"), ("OPENCODE", "1")]);
        assert_eq!(Host::select(None, &e), Ok(Host::Claude));
    }

    #[test]
    fn opencode_picks_agents_else_claude() {
        assert_eq!(
            Host::select(None, &env(&[("OPENCODE", "1")])),
            Ok(Host::Agents)
        );
        assert_eq!(
            Host::select(None, &env(&[("OPENCODE", "0")])),
            Ok(Host::Claude)
        );
        assert_eq!(Host::select(None, &env(&[])), Ok(Host::Claude));
    }

    #[test]
    fn empty_values_count_as_unset() {
        let e = env(&[("RADIN_HOST", "")]);
        assert_eq!(Host::select(Some(""), &e), Ok(Host::Claude));
        let e = env(&[("RADIN_HOST", "bogus")]);
        assert_eq!(Host::select(Some(""), &e), Err(unknown("bogus")));
    }

    #[test]
    fn unknown_names_fail_with_the_expected_text() {
        assert_eq!(Host::select(Some("all"), &env(&[])), Err(unknown("all")));
        assert_eq!(
            Host::select(Some("codex"), &env(&[])),
            Err(unknown("codex"))
        );
    }

    #[test]
    fn skill_names_follow_the_host_table() {
        assert_eq!(
            Host::Claude.skill_name("grilling").unwrap(),
            "/mattpocock-skills:grilling"
        );
        assert_eq!(Host::Agents.skill_name("grilling").unwrap(), "grilling");
        assert_eq!(
            Host::Claude.skill_name("nope"),
            Err("radin: unknown skill name 'nope' for host 'claude'".into())
        );
    }
}
