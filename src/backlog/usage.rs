pub const USAGE: &[(&str, &str)] = &[
    (
        "help",
        r##"help [command]              # print every command's usage, or one command's"##,
    ),
    (
        "env",
        r##"env [--export]             # print REPO_ROOT/NAMESPACE_DIR/BACKLOG_INDEX/BACKLOG_TASKS_DIR (--export: source-able with export)"##,
    ),
    (
        "show",
        r##"show [category]             # print backlog as markdown, or one ## section"##,
    ),
    (
        "list",
        r##"list [--order created|priority] [--planned] [--meta] [--created] [--unset-priority]  # print "id<US>category<US>title<US>file<US>priority<US>depends-on-csv" (US = \037), priority-descending by default, unset priorities last (--order created gives index order; --planned appends a P/empty field; --meta appends the `meta` lines joined by RS = \036, so one fork reads every entry's fields; --created appends the entry's ISO creation stamp, empty for an old entry without one; --unset-priority prints only the entries with no priority)"##,
    ),
    (
        "find",
        r##"find <id-or-title>          # print matching "id<TAB>category<TAB>title<TAB>file<TAB>priority<TAB>depends-on-csv" line(s)"##,
    ),
    (
        "count",
        r##"count                       # print the number of entries (0 without an index)"##,
    ),
    (
        "add",
        r##"add <category> <title> [--skill <name>]... [--acceptance <criterion>]... [--planning needed] [--complexity low|high] [--location <path:line>] [--origin <task-id>] [--deps <csv-of-ids-or-titles>]  # create task, body read from stdin, prints its bare id on stdout (the human sentence goes to stderr)"##,
    ),
    (
        "add-plan",
        r##"add-plan <id-or-title> <path>  # plan-lint the file, then add one plan pointer to the task's entry, and record HEAD in plans/<id>.head"##,
    ),
    (
        "append",
        r##"append <id-or-title>        # append text from stdin to the task's file"##,
    ),
    (
        "fact",
        r##"fact <id-or-title> <measured|inferred|guess> <line> [--long <path>]  # append "**Fact:** [<label>] <line>" to the task's file; --long also records <path> as its facts pointer (set-meta facts)"##,
    ),
    (
        "plan-target",
        r##"plan-target <id-or-title> [<sub-task title>]  # resolve one task for planning: "id"/"title"/"task_file"/"plan_file" TAB lines plus a "facts<TAB><path>" line when set and one "plan<TAB><path>" per existing pointer; exit 1 no match, 2 several (candidates on stderr), 3 already planned"##,
    ),
    (
        "open-decisions",
        r##"open-decisions <id-or-title>  # print the question of each `**Open decision:**` line after the task file's last `**Decision:**` line, one per line; exit 1 with nothing when none is open"##,
    ),
    (
        "files",
        r##"files <id-or-title|plan-file>  # print the paths in the `## Changes` section of every plan the task points at (or of the one plan file given), one per line, deduplicated; exit 1 with nothing when there is no plan or no path"##,
    ),
    (
        "plan-lint",
        r##"plan-lint <plan-file>      # print one line per plan-template defect (missing, out-of-order or empty section, a Changes entry with no "You see:" line, no Testing box); exit 1 when any"##,
    ),
    (
        "set-category",
        r##"set-category <id-or-title> <category>  # move a task to another category"##,
    ),
    (
        "retitle",
        r##"retitle <id-or-title> <title>  # change a task's title (its id never changes)"##,
    ),
    (
        "set-priority",
        r##"set-priority <id-or-title> <1|2|3|5|8|13|21|--none>  # set/clear the priority (higher wins)"##,
    ),
    (
        "set-deps",
        r##"set-deps <id-or-title> <csv-of-ids-or-titles|--none>   # set/clear depends_on (each item resolves like `find`; rejects a cycle)"##,
    ),
    (
        "set-meta",
        r##"set-meta <id-or-title> <plan|skills|acceptance|facts|location|planning|complexity|exclusive|origin> <value>...|--none  # set/clear one index-line field (skills takes skill names; facts, location, planning, complexity, exclusive and origin take exactly one value; planning takes only "needed", complexity "low" or "high", exclusive "yes")"##,
    ),
    (
        "meta",
        r##"meta <id-or-title>          # print "plan<TAB><path>" / "skill<TAB><instruction>" / "acceptance<TAB><criterion>" / "facts<TAB><path>" / "location<TAB><path:line>" / "planning<TAB>needed" / "complexity<TAB>low|high" / "exclusive<TAB>yes" / "origin<TAB><task-id>" lines from the task's entry"##,
    ),
    (
        "order",
        r##"order <--rank-needed|--report|--steps> [--rank <csv-of-ids>] [--infer-deps <id>=<csv>]... [--defer <csv-of-ids>|--only <csv-of-ids-orders-or-titles>|--first]  # the execution order: the priority order with the topological dependency fix applied (--rank-needed: print every unset-priority id, exit 1 when there are none; --report: "<order>. <title> (id: <id>)" plus one "dependency override:" line per violated edge, only the --only ids when given, each keeping its global order number; --steps: "id<TAB>order<TAB>depends-on-csv<TAB>pending|excluded", which is `radin state steps-init`'s stdin format; --only defers every id outside the csv, --first every id but the one at order 1)"##,
    ),
    (
        "field",
        r##"field <id-or-title> <TASK_FILE|TASK_BODY|EPIC_CONTEXT|TASK_ID|CATEGORY|PLAN_PATHS|SKILLS|SKILLS_DROPPED|ACCEPTANCE|FACTS|LOCATION|PLANNING|COMPLEXITY>  # one Execution-prompt placeholder, rendered ready to substitute"##,
    ),
    (
        "duplicates",
        r##"duplicates                  # print "id<TAB><value><TAB><ids>" / "title<TAB><value><TAB><ids>" per duplicated value, exit 1 when there are none"##,
    ),
    (
        "stamps",
        r##"stamps [<branch>]           # print "id<TAB>created<TAB>branch" per entry in index order (only the entries recorded on <branch> when given); a field an old entry lacks prints empty"##,
    ),
    (
        "remove",
        r##"remove <id-or-title>        # delete task file + index entry (exact single match required)"##,
    ),
    (
        "reconcile",
        r##"reconcile                  # drop backlog entries whose id is already in completed.json"##,
    ),
    (
        "epics",
        r##"epics                       # print every epic id, one per line"##,
    ),
    (
        "suggest",
        r##"suggest [order flags]       # print "tasks<TAB><count><TAB>all|epic" (epic when the count exceeds RADIN_EPIC_THRESHOLD, default 20, and an epic exists) and "epic<TAB><id><TAB><task count>" for the epic that holds the first task in `order --steps`"##,
    ),
    (
        "scope",
        r##"scope <epic-id|id-or-title>  # print "ids<TAB><csv>" (the epic's tasks or the one task, plus every task they transitively depend on) and, when the closure added any, "dependencies<TAB><csv>"; exit 1 no match, 2 several tasks (candidates on stderr)"##,
    ),
    (
        "epic-add",
        r##"epic-add <epic-id>          # create the epic dir + DESCRIPTION.md (body from stdin when piped)"##,
    ),
    (
        "epic-show",
        r##"epic-show <epic-id>         # print the epic's DESCRIPTION.md"##,
    ),
    (
        "epic-move",
        r##"epic-move <id-or-title> <epic-id|--none>  # move a task into/out of an epic"##,
    ),
    (
        "epic-remove",
        r##"epic-remove <epic-id>       # delete an epic that has no child tasks left"##,
    ),
];

pub fn usage_for(verb: &str) -> String {
    USAGE
        .iter()
        .filter(|(v, _)| *v == verb)
        .map(|(_, l)| format!("  {l}\n"))
        .collect()
}

pub fn all() -> String {
    USAGE.iter().map(|(_, l)| format!("  {l}\n")).collect()
}
