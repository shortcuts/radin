#[derive(Clone, Debug, Default, PartialEq)]
pub struct Task {
    pub id: String,
    pub cat: String,
    pub title: String,
    pub file: String,
    pub prio: String,
    pub deps: String,
    pub planned: bool,
    pub meta: Vec<String>,
    pub created: String,
    pub epic: String,
    /// Index order, so any sort can be undone.
    pub ord: usize,
}

/// Parses `backlog list --planned --meta --created`: fields split on US, meta lines on RS.
pub fn parse_list(text: &str) -> Vec<Task> {
    let mut tasks = Vec::new();
    for line in text.lines().filter(|l| !l.is_empty()) {
        let f: Vec<&str> = line.splitn(9, '\x1f').collect();
        let at = |i: usize| f.get(i).copied().unwrap_or("").to_string();
        if f[0].is_empty() {
            continue;
        }
        let file = at(3);
        let epic = file
            .strip_prefix("tasks/")
            .and_then(|r| r.split_once('/'))
            .map_or(String::new(), |(e, _)| e.to_string());
        tasks.push(Task {
            id: at(0),
            cat: at(1),
            title: at(2),
            file,
            prio: at(4),
            deps: at(5),
            planned: f.get(6) == Some(&"P"),
            meta: f
                .get(7)
                .map(|m| {
                    m.split('\x1e')
                        .filter(|l| !l.is_empty())
                        .map(String::from)
                        .collect()
                })
                .unwrap_or_default(),
            created: at(8),
            epic,
            ord: tasks.len(),
        });
    }
    tasks
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn two_rows_give_epic_planned_and_meta() {
        let text = "a-one\x1ffeat\x1fA one\x1ftasks/ui/a-one.md\x1f8\x1fb-two\x1fP\x1fplan\tp.md\x1estatus\tx\x1f2026-01-02T03:04:05Z\n\
                    b-two\x1ffix\x1fB two\x1ftasks/b-two.md\x1f\x1f\x1f\x1f\n";
        let t = parse_list(text);
        assert_eq!(t.len(), 2);
        assert_eq!(t[0].epic, "ui");
        assert!(t[0].planned);
        assert_eq!(t[0].meta, vec!["plan\tp.md", "status\tx"]);
        assert_eq!(t[0].created, "2026-01-02T03:04:05Z");
        assert_eq!(t[0].deps, "b-two");
        assert_eq!(t[1].epic, "");
        assert!(!t[1].planned);
        assert_eq!(t[1].ord, 1);
        assert_eq!(t[1].prio, "");
    }

    #[test]
    fn a_row_without_an_id_is_skipped() {
        assert!(parse_list("\x1ffeat\x1ft\n").is_empty());
    }
}
