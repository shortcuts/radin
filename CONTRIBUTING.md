# Contributing to radin

## Test `install.sh` changes local

```sh
make lint
make test
```

## Measure a TUI render change

```sh
make bench-tui
```

The bench seeds a 42-task backlog, presses `j` 20 times on a 200x50 pty, and
prints the median and max key-to-frame time. Run it before and after the
change. It stays out of `make test` because timing depends on the machine.

## Measure a prose edit

Run a `SKILL.md` or `lib/radin-prompt-*.md` edit before you keep it when the
edit claims to change agent behaviour. `make test` cannot do this: it makes no
model call.

`/skill-creator` owns the run. Use its "Improving an existing skill" flow:
snapshot the old version as the `old_skill` baseline, run both on the same
prompts, then use its blind comparison (`agents/comparator.md`). Its
comparator is blind to which output is which. These rules also blind the
candidate, which `/skill-creator` leaves open:

1. Write each test prompt as the request a user would type. Keep the words
   eval, test, judge, rubric, score, compare and benchmark out of every
   prompt, directory and file name a candidate sees.
2. Give each candidate its own scratch repo, with project-shaped names and a
   backlog seeded through `radin backlog add`.
3. Never ask a candidate which skills or rules it applied. Grade that from
   what its transcript shows it read and from the shape of its output.
4. Tell no candidate that other candidates exist.
5. Run the judge on a model family the candidates do not use.
6. Read every output yourself. When you disagree with the judge, suspect the
   rubric before the variant.

Keep the edit only when the comparison favours it. A tie means the edit fails
the no-op test in AGENTS.md: delete it.
