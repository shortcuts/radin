/* Full-screen backlog browser for humans: list, view, create, edit,
 * recategorize and delete tasks without an agent in the loop. Compiled by
 * install.sh to ~/.claude/.radin/bin/radin-tui, reached as `radin tui`.
 *
 * Every mutation and every read goes through radin-backlog.sh /
 * radin-state.sh, so the index/task-file contract stays in one place -- this
 * file only draws and dispatches keys.
 *
 * C, not bash: a bash frame costs a fork per row and the whole TUI cost ~150ms
 * of interpreter and CLI startup per keypress-to-frame. Raw ANSI, no
 * ncurses/tput: the zero-dependency rule covers the TUI too, and cc is the one
 * compiler both macOS (Command Line Tools) and Linux already have.
 *
 * cc -O2 -o radin-tui radin-tui.c
 */
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>

#define MAXT 4096
#define MAXROW (MAXT * 2)
#define US '\037'
#define SLOT 512
#define BIG 4096

static const char *CATEGORIES[] = {"feat", "fix", "chore", "refactor"};
#define NCAT 4
static const char *BODY_HINT =
	"# describe the task: what changes, why, which files, how to verify";

struct task {
	char id[SLOT], cat[32], title[SLOT], file[SLOT], prio[32], deps[SLOT], epic[SLOT];
	char flag[8];
	const char *colour;
};

static struct task T[MAXT];
static int TASK_N;
static int row_task[MAXROW];
static char row_epic[MAXROW][SLOT];
static int N, SEL, TOP;
static char SEARCH[SLOT], MSG[BIG];
static int ROWS = 24, COLS = 80;
static int MODE_DONE;
static char COLLAPSED[BIG];
static int PMIN, PMAX, PANY;
static int COLOR = 1;

static char *done_rows[MAXT];
static int DONE_N, DONE_SEL, DONE_TOP;

static char LIB_DIR[PATH_MAX], BACKLOG[PATH_MAX], STATE[PATH_MAX];
static char REPO_ROOT[PATH_MAX], NAMESPACE_DIR[PATH_MAX], BACKLOG_DIR[PATH_MAX],
	BACKLOG_TASKS_DIR[PATH_MAX];
static char DETAIL_FILE[PATH_MAX];
static struct termios TIO_SAVE;
static int TIO_SAVED;
static int PENDING = -1;

static void die(const char *m) {
	fprintf(stderr, "radin tui: %s\n", m);
	exit(1);
}

static void *xmalloc(size_t n) {
	void *p = malloc(n);
	if (!p) die("out of memory");
	return p;
}

static void setmsg(const char *fmt, ...) {
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(MSG, sizeof MSG, fmt, ap);
	va_end(ap);
}

/* Trailing newlines only: a CLI message is one line and the footer draws it. */
static void chomp(char *s) {
	size_t n = strlen(s);
	while (n && (s[n - 1] == '\n' || s[n - 1] == '\r')) s[--n] = 0;
}

/* Runs argv, returns its stdout (always a valid string, caller frees). *ok is
 * the exit status test. stdin_path feeds fd0, merge folds stderr in. */
static char *run(char **argv, int *ok, int merge, const char *stdin_path) {
	int p[2];
	if (pipe(p) < 0) die("pipe");
	pid_t pid = fork();
	if (pid < 0) die("fork");
	if (pid == 0) {
		close(p[0]);
		dup2(p[1], 1);
		if (merge) dup2(p[1], 2);
		else {
			int n = open("/dev/null", O_WRONLY);
			if (n >= 0) dup2(n, 2);
		}
		close(p[1]);
		int in = open(stdin_path ? stdin_path : "/dev/null", O_RDONLY);
		if (in >= 0) dup2(in, 0);
		execv(argv[0], argv);
		_exit(127);
	}
	close(p[1]);
	size_t cap = 8192, len = 0;
	char *buf = xmalloc(cap);
	ssize_t n;
	while ((n = read(p[0], buf + len, cap - len - 1)) > 0) {
		len += n;
		if (len + 1 >= cap) {
			cap *= 2;
			buf = realloc(buf, cap);
			if (!buf) die("out of memory");
		}
	}
	buf[len] = 0;
	close(p[0]);
	int st = 0;
	waitpid(pid, &st, 0);
	if (ok) *ok = (WIFEXITED(st) && WEXITSTATUS(st) == 0);
	return buf;
}

/* `bash <script> <args...>`: one owner for the storage format stays in the
 * shell CLI, so every read and write here is a call into it. */
static char *cli(const char *script, int *ok, int merge, const char *stdin_path, ...) {
	char *argv[24];
	int n = 0;
	argv[n++] = (char *)"/bin/bash";
	argv[n++] = (char *)script;
	va_list ap;
	va_start(ap, stdin_path);
	for (;;) {
		char *a = va_arg(ap, char *);
		if (!a) break;
		argv[n++] = a;
	}
	va_end(ap);
	argv[n] = NULL;
	return run(argv, ok, merge, stdin_path);
}

static void spawn_tty(char **argv) {
	pid_t pid = fork();
	if (pid < 0) die("fork");
	if (pid == 0) {
		execvp(argv[0], argv);
		_exit(127);
	}
	int st;
	while (waitpid(pid, &st, 0) < 0 && errno == EINTR) continue;
}

/* ---------- terminal ---------- */

static void term_size(void) {
	struct winsize ws;
	if (ioctl(1, TIOCGWINSZ, &ws) == 0 && ws.ws_row && ws.ws_col) {
		ROWS = ws.ws_row;
		COLS = ws.ws_col;
	}
	if (ROWS < 10) ROWS = 10;
	if (COLS < 40) COLS = 40;
	if (COLS > 1024) COLS = 1024;
}

static void raw_on(void) {
	struct termios t;
	if (tcgetattr(0, &t) == 0) {
		if (!TIO_SAVED) {
			TIO_SAVE = t;
			TIO_SAVED = 1;
		}
		t.c_lflag &= ~(ECHO | ICANON);
		t.c_cc[VMIN] = 1;
		t.c_cc[VTIME] = 0;
		tcsetattr(0, TCSANOW, &t);
	}
	printf("\033[?1049h\033[?25l");
	fflush(stdout);
}

static void raw_off(void) {
	printf("\033[?25h\033[?1049l");
	fflush(stdout);
	if (TIO_SAVED) tcsetattr(0, TCSANOW, &TIO_SAVE);
}

static void cleanup(void) {
	raw_off();
	if (*DETAIL_FILE) unlink(DETAIL_FILE);
}

static void on_signal(int s) {
	(void)s;
	cleanup();
	_exit(130);
}

/* Every row is padded to the full width so the selected row's reverse-video
 * block spans it, and truncated so a long title can never wrap and desync the
 * frame's line count. */
static void row(const char *text, int selected, const char *colour) {
	char buf[1200];
	snprintf(buf, sizeof buf, "%.*s", COLS, text);
	if (colour && *colour) printf("%s", colour);
	if (selected) printf("\033[7m");
	printf("%-*s", COLS, buf);
	if (selected || (colour && *colour)) printf("\033[0m");
	printf("\n");
}

static void bar(const char *text, int at_row) {
	char buf[1200];
	if (at_row) printf("\033[%d;1H", at_row);
	snprintf(buf, sizeof buf, "%.*s", COLS, text);
	printf("\033[1m%-*s\033[0m", COLS, buf);
	if (!at_row) printf("\n");
}

/* ---------- model ---------- */

static int is_num(const char *s) {
	if (!*s) return 0;
	for (; *s; s++)
		if (!isdigit((unsigned char)*s)) return 0;
	return 1;
}

static int in_set(const char *set, const char *word) {
	const char *p = set;
	size_t n = strlen(word);
	while (*p) {
		while (*p == ' ') p++;
		if (!strncmp(p, word, n) && (p[n] == ' ' || p[n] == 0)) return 1;
		while (*p && *p != ' ') p++;
	}
	return 0;
}

static void set_remove(char *set, const char *word) {
	char out[BIG] = "";
	char tmp[BIG];
	snprintf(tmp, sizeof tmp, "%s", set);
	char *save = NULL, *tok = strtok_r(tmp, " ", &save);
	while (tok) {
		if (strcmp(tok, word)) {
			if (*out) strncat(out, " ", sizeof out - strlen(out) - 1);
			strncat(out, tok, sizeof out - strlen(out) - 1);
		}
		tok = strtok_r(NULL, " ", &save);
	}
	snprintf(set, BIG, "%s", out);
}

static void set_add(char *set, const char *word) {
	if (*set) strncat(set, " ", BIG - strlen(set) - 1);
	strncat(set, word, BIG - strlen(set) - 1);
}

static void copy_field(char *dst, size_t cap, const char *src, size_t len) {
	if (len >= cap) len = cap - 1;
	memcpy(dst, src, len);
	dst[len] = 0;
}

/* Bands are relative to the priorities now visible, so this row's colour moves
 * when an unrelated task's number does -- chosen over a fixed palette because
 * priority is an unbounded integer. */
static void fill_colours(void) {
	int span = PANY ? PMAX - PMIN : -1;
	if (!COLOR) span = -1;
	for (int i = 0; i < TASK_N; i++) {
		T[i].colour = "";
		if (!is_num(T[i].prio)) continue;
		int p = atoi(T[i].prio);
		if (span == 0) T[i].colour = "\033[33m";
		else if (span > 0) {
			int off = (p - PMIN) * 3;
			if (off >= span * 2) T[i].colour = "\033[31m";
			else if (off >= span) T[i].colour = "\033[33m";
			else T[i].colour = "\033[32m";
		}
	}
}

/* Case-insensitive substring on "id title". No active search means no match,
 * so nothing is marked and n/N have nowhere to go. */
static int search_hit(int i) {
	if (!*SEARCH) return 0;
	char hay[SLOT * 2], needle[SLOT];
	snprintf(hay, sizeof hay, "%s %s", T[i].id, T[i].title);
	snprintf(needle, sizeof needle, "%s", SEARCH);
	for (char *p = hay; *p; p++) *p = tolower((unsigned char)*p);
	for (char *p = needle; *p; p++) *p = tolower((unsigned char)*p);
	return strstr(hay, needle) != NULL;
}

/* The rows: ungrouped tasks first, then one collapsible header per
 * epic followed by its children. A collapsed epic's children are absent from
 * the row arrays, which is why j/k/g/G need no collapse logic of their own. */
static void build_rows(void) {
	PANY = 0;
	for (int i = 0; i < TASK_N; i++) {
		if (!is_num(T[i].prio)) continue;
		int p = atoi(T[i].prio);
		if (!PANY) {
			PMIN = PMAX = p;
			PANY = 1;
		} else {
			if (p < PMIN) PMIN = p;
			if (p > PMAX) PMAX = p;
		}
	}
	fill_colours();

	N = 0;
	for (int i = 0; i < TASK_N; i++) {
		if (!*T[i].epic) {
			row_task[N] = i;
			row_epic[N][0] = 0;
			N++;
		}
	}
	/* Epic headers in name order, each followed by its children. */
	char seen[BIG] = "";
	for (;;) {
		const char *next = NULL;
		for (int i = 0; i < TASK_N; i++) {
			if (!*T[i].epic) continue;
			if (in_set(seen, T[i].epic)) continue;
			if (!next || strcmp(T[i].epic, next) < 0) next = T[i].epic;
		}
		if (!next) break;
		set_add(seen, next);
		row_task[N] = -1;
		snprintf(row_epic[N], SLOT, "%s", next);
		N++;
		if (in_set(COLLAPSED, next)) continue;
		for (int i = 0; i < TASK_N; i++) {
			if (!strcmp(T[i].epic, next)) {
				row_task[N] = i;
				row_epic[N][0] = 0;
				N++;
			}
		}
	}
	if (SEL >= N) SEL = N > 0 ? N - 1 : 0;
}

static void load(void) {
	int ok;
	char *out = cli(BACKLOG, &ok, 0, NULL, "list", "--planned", NULL);
	TASK_N = 0;
	/* Category order, not index order: the list groups by category. */
	for (int c = 0; c < NCAT; c++) {
		char *line = out, *nl;
		while (*line) {
			nl = strchr(line, '\n');
			size_t llen = nl ? (size_t)(nl - line) : strlen(line);
			if (llen) {
				const char *f[7] = {0};
				size_t fl[7] = {0};
				int nf = 0;
				const char *s = line, *end = line + llen;
				while (nf < 7) {
					const char *sep = memchr(s, US, end - s);
					f[nf] = s;
					fl[nf] = sep ? (size_t)(sep - s) : (size_t)(end - s);
					nf++;
					if (!sep) break;
					s = sep + 1;
				}
				if (fl[0] && fl[1] == strlen(CATEGORIES[c]) &&
					!strncmp(f[1], CATEGORIES[c], fl[1]) && TASK_N < MAXT) {
					struct task *t = &T[TASK_N++];
					memset(t, 0, sizeof *t);
					copy_field(t->id, sizeof t->id, f[0], fl[0]);
					copy_field(t->cat, sizeof t->cat, f[1], fl[1]);
					copy_field(t->title, sizeof t->title, f[2], fl[2]);
					copy_field(t->file, sizeof t->file, f[3], fl[3]);
					copy_field(t->prio, sizeof t->prio, f[4], fl[4]);
					copy_field(t->deps, sizeof t->deps, f[5], fl[5]);
					char planned[8] = "";
					copy_field(planned, sizeof planned, f[6] ? f[6] : "", fl[6]);
					snprintf(t->flag, sizeof t->flag, "%s", *planned ? planned : " ");
					/* tasks/<epic>/<id>.md is the only nesting the index has. */
					if (!strncmp(t->file, "tasks/", 6)) {
						const char *rest = t->file + 6;
						const char *slash = strchr(rest, '/');
						if (slash) copy_field(t->epic, sizeof t->epic, rest, slash - rest);
					}
				}
			}
			if (!nl) break;
			line = nl + 1;
		}
	}
	free(out);
	build_rows();
}

static int cur_task(void) {
	if (N <= 0) return -1;
	return row_task[SEL];
}

static void task_path(int ti, char *dst, size_t cap) {
	snprintf(dst, cap, "%s/%s", BACKLOG_DIR, T[ti].file);
}

/* ---------- drawing ---------- */

static int clamp_top(int sel, int top, int h) {
	if (sel < top) top = sel;
	if (sel >= top + h) top = sel - h + 1;
	return top < 0 ? 0 : top;
}

/* The detail pane: the title, the ids, then the task body. The full composed
 * document -- epic description, every plan file, dependency titles -- lives
 * behind `v`. */
static void draw_preview(int h) {
	char line[1200];
	int ti = cur_task();
	int n = 0;
	if (ti >= 0) {
		snprintf(line, sizeof line, "-- %s ", T[ti].id);
		row(line, 0, "");
		snprintf(line, sizeof line, "  %s", T[ti].title);
		row(line, 0, "");
		snprintf(line, sizeof line, "  id: %s  category: %s  priority: %s", T[ti].id,
			T[ti].cat, *T[ti].prio ? T[ti].prio : "(unset)");
		row(line, 0, "");
		row("  ", 0, "");
		n = 3;
		char path[PATH_MAX];
		task_path(ti, path, sizeof path);
		FILE *f = fopen(path, "r");
		if (f) {
			char buf[1200];
			while (n < h && fgets(buf, sizeof buf, f)) {
				chomp(buf);
				snprintf(line, sizeof line, "  %s", buf);
				row(line, 0, "");
				n++;
			}
			fclose(f);
		}
	} else {
		snprintf(line, sizeof line, "-- epic: %s ", row_epic[SEL]);
		row(line, 0, "");
		snprintf(line, sizeof line, "  epic: %s", row_epic[SEL]);
		row(line, 0, "");
		row("  ", 0, "");
		n = 2;
		for (int i = 0; i < TASK_N && n < h; i++) {
			if (strcmp(T[i].epic, row_epic[SEL])) continue;
			snprintf(line, sizeof line, "  - %s", T[i].title);
			row(line, 0, "");
			n++;
		}
	}
}

static void draw(void) {
	term_size();
	int preview_h = (ROWS - 4) / 3;
	if (preview_h < 4) preview_h = 4;
	int list_h = ROWS - preview_h - 4;
	if (list_h < 1) list_h = 1;
	TOP = clamp_top(SEL, TOP, list_h);

	char header[1200], text[1200];
	snprintf(header, sizeof header, "radin backlog  %d task(s)", TASK_N);
	if (*SEARCH)
		snprintf(header + strlen(header), sizeof header - strlen(header),
			"  search:\"%s\"", SEARCH);
	if (N)
		snprintf(header + strlen(header), sizeof header - strlen(header), "  [%d/%d]",
			SEL + 1, N);

	printf("\033[H\033[2J");
	bar(header, 0);
	int end = TOP + list_h;
	if (end > N) end = N;
	int i;
	if (N == 0) {
		row("  (no tasks) press a to create one", 0, "");
		i = 1;
	} else {
		for (i = TOP; i < end; i++) {
			const char *colour = "";
			int ti = row_task[i];
			if (ti < 0) {
				snprintf(text, sizeof text, " %s epic: %s",
					in_set(COLLAPSED, row_epic[i]) ? "+" : "-", row_epic[i]);
			} else {
				colour = T[ti].colour;
				/* The margin's last column is the search mark; the columns
				 * before it are the epic indent, so a marked row never shifts
				 * the ones around it. */
				snprintf(text, sizeof text, "%s%s%s %-9s %s",
					*T[ti].epic ? "  " : "", search_hit(ti) ? "*" : " ",
					T[ti].flag, T[ti].cat, T[ti].title);
			}
			row(text, i == SEL, colour);
		}
		i = end - TOP;
	}
	for (; i < list_h; i++) row("", 0, "");

	if (N > 0) draw_preview(preview_h);
	else row("--", 0, "");

	const char *footer =
		"j/k/g/G move  enter edit/collapse  v detail  / search  n/N match  "
		"a new  d delete  c category  r retitle  Tab done  ? keys  q quit";
	bar(*MSG ? MSG : footer, ROWS);
	fflush(stdout);
}

static void load_done(void) {
	for (int i = 0; i < DONE_N; i++) free(done_rows[i]);
	DONE_N = 0;
	char path[PATH_MAX];
	snprintf(path, sizeof path, "%s/state/completed.json", NAMESPACE_DIR);
	int ok;
	char *out = cli(STATE, &ok, 0, NULL, "completed-list", path, NULL);
	char *line = out;
	while (*line && DONE_N < MAXT) {
		char *nl = strchr(line, '\n');
		if (nl) *nl = 0;
		if (*line) {
			char *tab = strchr(line, '\t');
			char buf[1200];
			if (tab) {
				*tab = 0;
				snprintf(buf, sizeof buf, " %-52s %s", line, tab + 1);
			} else {
				snprintf(buf, sizeof buf, " %s", line);
			}
			done_rows[DONE_N++] = strdup(buf);
		}
		if (!nl) break;
		line = nl + 1;
	}
	free(out);
	if (DONE_SEL >= DONE_N) DONE_SEL = DONE_N > 0 ? DONE_N - 1 : 0;
}

static void draw_done(void) {
	term_size();
	int list_h = ROWS - 2;
	if (list_h < 1) list_h = 1;
	DONE_TOP = clamp_top(DONE_SEL, DONE_TOP, list_h);
	char header[1200];
	snprintf(header, sizeof header, "radin done  %d completed", DONE_N);
	printf("\033[H\033[2J");
	bar(header, 0);
	int end = DONE_TOP + list_h, i;
	if (end > DONE_N) end = DONE_N;
	if (DONE_N == 0) {
		row("  (nothing completed yet)", 0, "");
		i = 1;
	} else {
		for (i = DONE_TOP; i < end; i++) row(done_rows[i], i == DONE_SEL, "");
		i = end - DONE_TOP;
	}
	for (; i < list_h; i++) row("", 0, "");
	bar(*MSG ? MSG : "j/k move  Tab back  R reload  q quit  (read-only)", ROWS);
	fflush(stdout);
}

/* ---------- input ---------- */

/* Arrow-key escape sequences map onto j/k so the dispatcher only ever sees
 * single characters. Returns -1 on EOF. */
static int readkey(void) {
	if (PENDING >= 0) {
		int k = PENDING;
		PENDING = -1;
		return k;
	}
	unsigned char c;
	if (read(0, &c, 1) != 1) return -1;
	if (c != 033) return c;
	struct pollfd p = {0, POLLIN, 0};
	if (poll(&p, 1, 50) <= 0) return 'Q' + 1000; /* bare ESC: no key of ours */
	unsigned char rest[2] = {0, 0};
	if (read(0, &rest[0], 1) != 1) return -1;
	if (rest[0] == '[' && read(0, &rest[1], 1) == 1) {
		switch (rest[1]) {
		case 'A': return 'k';
		case 'B': return 'j';
		case 'C': return 'l';
		case 'D': return 'h';
		}
	}
	return 'Q' + 1000;
}

/* Next (dir 1) / previous (dir -1) row whose task matches the active search,
 * wrapping past the ends. Starting at step 1 means n always leaves the current
 * row; the step <= N bound lets it come back to it when it is the only match.
 * A match inside a collapsed epic has no row, so n does not visit it -- the
 * same blind spot j/k/g/G already have. */
static void search_jump(int dir) {
	if (!*SEARCH || N <= 0) return;
	for (int step = 1; step <= N; step++) {
		int i = ((SEL + dir * step) % N + N) % N;
		if (row_task[i] >= 0 && search_hit(row_task[i])) {
			SEL = i;
			return;
		}
	}
}

static int move_key(int k) {
	int *sel = MODE_DONE ? &DONE_SEL : &SEL;
	int n = MODE_DONE ? DONE_N : N;
	switch (k) {
	case 'j': if (*sel < n - 1) (*sel)++; return 1;
	case 'k': if (*sel > 0) (*sel)--; return 1;
	case 'g': *sel = 0; return 1;
	case 'G': if (n) *sel = n - 1; return 1;
	case 'n':
	case 'N':
		if (MODE_DONE) return 0;
		search_jump(k == 'n' ? 1 : -1);
		return 1;
	}
	return 0;
}

/* One full repaint per keypress is what makes a held j/k lag behind the
 * keyboard: a second of autorepeat queues ~30 keys and only the last frame is
 * ever seen. So after a motion key, apply every motion already sitting in the
 * tty buffer and repaint once. The first non-motion key waits in PENDING. */
static void coalesce(void) {
	for (;;) {
		struct pollfd p = {0, POLLIN, 0};
		if (poll(&p, 1, 0) <= 0) return;
		int k = readkey();
		if (k < 0) return;
		if (!move_key(k)) {
			PENDING = k;
			return;
		}
	}
}

/* Line input needs the terminal back in cooked mode, on the last row. */
static void prompt(const char *label, char *out, size_t cap) {
	printf("\033[%d;1H\033[2K\033[?25h%s", ROWS, label);
	fflush(stdout);
	struct termios t;
	int changed = tcgetattr(0, &t) == 0;
	if (changed) {
		struct termios c = t;
		c.c_lflag |= ECHO | ICANON;
		tcsetattr(0, TCSANOW, &c);
	}
	out[0] = 0;
	size_t n = 0;
	char ch;
	while (read(0, &ch, 1) == 1 && ch != '\n' && ch != '\r')
		if (n + 1 < cap) out[n++] = ch;
	out[n] = 0;
	if (changed) tcsetattr(0, TCSANOW, &t);
	printf("\033[?25l");
	fflush(stdout);
}

static int confirm(const char *question) {
	char label[1200], ans[64];
	snprintf(label, sizeof label, "%s [y/N] ", question);
	prompt(label, ans, sizeof ans);
	return !strcmp(ans, "y") || !strcmp(ans, "Y") || !strcmp(ans, "yes");
}

/* $EDITOR owns the whole terminal while it runs, so hand it a normal screen
 * and take the alternate one back afterwards. */
static void run_external(const char *cmd, const char *arg) {
	char *argv[3] = {(char *)cmd, (char *)arg, NULL};
	raw_off();
	spawn_tty(argv);
	raw_on();
}

/* Every mutation shares one contract: MSG carries the CLI's own output on both
 * paths, and load() runs on success only, so a rejected change keeps
 * SEL/TOP/COLLAPSED and reads as a rejection instead of a no-op. */
static void mutate(const char *verb, const char *a, const char *b, const char *stdin_path) {
	int ok;
	char *out = cli(BACKLOG, &ok, 1, stdin_path, (char *)verb, (char *)a, (char *)b, NULL);
	chomp(out);
	if (ok) {
		setmsg("%s", out);
		load();
	} else {
		setmsg("%s failed: %s", verb, out);
	}
	free(out);
}

/* ---------- pickers ---------- */

struct pick {
	char val[SLOT], label[SLOT];
};
static struct pick PV[MAXT];
static int PN;
static char PICK_MARKED[BIG];
static char PICK_RESULT[BIG];

static void pick_draw(int multi, const char *title, int sel, int *ptop) {
	term_size();
	int list_h = ROWS - 2;
	if (list_h < 1) list_h = 1;
	*ptop = clamp_top(sel, *ptop, list_h);
	printf("\033[H\033[2J");
	bar(title, 0);
	int end = *ptop + list_h, i;
	if (end > PN) end = PN;
	char line[1200];
	for (i = *ptop; i < end; i++) {
		if (multi)
			snprintf(line, sizeof line, " [%s] %s",
				in_set(PICK_MARKED, PV[i].val) ? "x" : " ", PV[i].label);
		else snprintf(line, sizeof line, "  %s", PV[i].label);
		row(line, i == sel, "");
	}
	for (i = end - *ptop; i < list_h; i++) row("", 0, "");
	bar(multi ? "space mark  enter confirm  q cancel" : "enter select  q cancel", ROWS);
	fflush(stdout);
}

/* One chooser for every key that needs one. Returns 0 when the user cancels or
 * there is nothing to pick; PICK_RESULT is the space-delimited answer, and ""
 * is a legal multi answer -- it means clear. */
static int pick(int multi, const char *title, const char *marked) {
	if (PN <= 0) return 0;
	snprintf(PICK_MARKED, sizeof PICK_MARKED, "%s", marked ? marked : "");
	PICK_RESULT[0] = 0;
	int sel = 0, ptop = 0;
	for (;;) {
		pick_draw(multi, title, sel, &ptop);
		int k = readkey();
		if (k < 0) return 0;
		switch (k) {
		case 'j': if (sel < PN - 1) sel++; break;
		case 'k': if (sel > 0) sel--; break;
		case 'g': sel = 0; break;
		case 'G': sel = PN - 1; break;
		case ' ':
			if (!multi) break;
			if (in_set(PICK_MARKED, PV[sel].val)) set_remove(PICK_MARKED, PV[sel].val);
			else set_add(PICK_MARKED, PV[sel].val);
			break;
		case '\r':
		case '\n':
			if (multi) snprintf(PICK_RESULT, sizeof PICK_RESULT, "%s", PICK_MARKED);
			else snprintf(PICK_RESULT, sizeof PICK_RESULT, "%s", PV[sel].val);
			return 1;
		case 'q': return 0;
		default:
			if (k > 1000) return 0; /* ESC */
		}
	}
}

/* ---------- key handlers ---------- */

static int sel_task(void) {
	int ti = cur_task();
	if (ti < 0) setmsg("epic header selected -- no task here");
	return ti;
}

static void edit_body(int ti) {
	char path[PATH_MAX];
	task_path(ti, path, sizeof path);
	const char *ed = getenv("EDITOR");
	run_external(ed && *ed ? ed : "vi", path);
	setmsg("edited %s", T[ti].id);
}

static void toggle_collapse(void) {
	if (N <= 0 || !*row_epic[SEL]) return;
	if (in_set(COLLAPSED, row_epic[SEL])) set_remove(COLLAPSED, row_epic[SEL]);
	else set_add(COLLAPSED, row_epic[SEL]);
	build_rows();
}

/* One keypress beats typing a category name that then has to be validated. */
static const char *pick_category(void) {
	printf("\033[%d;1H\033[2K\033[1mcategory: [f]eat  [x] fix  [c]hore  [r]efactor  "
		   "(any other key cancels)\033[0m",
		ROWS);
	fflush(stdout);
	switch (readkey()) {
	case 'f': return "feat";
	case 'x': return "fix";
	case 'c': return "chore";
	case 'r': return "refactor";
	}
	return NULL;
}

static void new_task(void) {
	const char *cat = pick_category();
	if (!cat) {
		setmsg("new: cancelled");
		return;
	}
	char title[SLOT];
	prompt("title: ", title, sizeof title);
	if (!*title) {
		setmsg("new: empty title, cancelled");
		return;
	}
	char body[PATH_MAX], stripped[PATH_MAX];
	snprintf(body, sizeof body, "%s/tui-body.XXXXXX", NAMESPACE_DIR);
	int fd = mkstemp(body);
	if (fd < 0) {
		setmsg("new: cannot create a body file");
		return;
	}
	FILE *f = fdopen(fd, "w");
	fprintf(f, "%s\n", BODY_HINT);
	fclose(f);
	const char *ed = getenv("EDITOR");
	run_external(ed && *ed ? ed : "vi", body);
	/* The hint line is a prompt for the human, never part of the task body a
	 * sub-agent later reads. */
	snprintf(stripped, sizeof stripped, "%s.body", body);
	FILE *in = fopen(body, "r"), *out = fopen(stripped, "w");
	long kept = 0;
	if (in && out) {
		char line[BIG];
		while (fgets(line, sizeof line, in)) {
			char t[BIG];
			snprintf(t, sizeof t, "%s", line);
			chomp(t);
			if (!strcmp(t, BODY_HINT)) continue;
			fputs(line, out);
			kept += strlen(line);
		}
	}
	if (in) fclose(in);
	if (out) fclose(out);
	if (kept == 0) {
		unlink(body);
		unlink(stripped);
		setmsg("new: empty body, cancelled");
		return;
	}
	mutate("add", cat, title, stripped);
	unlink(body);
	unlink(stripped);
}

static void delete_task(int ti) {
	char q[1200];
	snprintf(q, sizeof q, "delete \"%s\"?", T[ti].title);
	if (confirm(q)) mutate("remove", T[ti].id, NULL, NULL);
	else setmsg("delete cancelled");
}

/* `c` cycles rather than prompts: four categories, one keypress each way. */
static void cycle_category(int ti) {
	int at = 0;
	for (int i = 0; i < NCAT; i++)
		if (!strcmp(CATEGORIES[i], T[ti].cat)) at = i;
	mutate("set-category", T[ti].id, (char *)CATEGORIES[(at + 1) % NCAT], NULL);
}

static void retitle_task(int ti) {
	char label[1200], answer[SLOT];
	snprintf(label, sizeof label, "new title (was \"%s\"): ", T[ti].title);
	prompt(label, answer, sizeof answer);
	if (!*answer) {
		setmsg("retitle cancelled");
		return;
	}
	mutate("retitle", T[ti].id, answer, NULL);
}

/* The Fibonacci scale `radin backlog set-priority` enforces, ascending with
 * "higher wins" -- picked, not typed, so no keystroke can miss the scale. */
static const char *PRIORITIES[] = {"1", "2", "3", "5", "8", "13", "21"};
#define NPRIO ((int)(sizeof PRIORITIES / sizeof *PRIORITIES))

static void set_priority_task(int ti) {
	PN = 0;
	for (int i = NPRIO - 1; i >= 0; i--) {
		snprintf(PV[PN].val, SLOT, "%s", PRIORITIES[i]);
		snprintf(PV[PN].label, SLOT, "%s", PRIORITIES[i]);
		PN++;
	}
	snprintf(PV[PN].val, SLOT, "--none");
	snprintf(PV[PN].label, SLOT, "(none) -- clear the priority");
	PN++;
	char title[1200];
	snprintf(title, sizeof title, "priority for %s (higher wins)", T[ti].id);
	if (!pick(0, title, NULL)) {
		setmsg("priority cancelled");
		return;
	}
	mutate("set-priority", T[ti].id, PICK_RESULT, NULL);
}

static void commas_to_spaces(char *s) {
	for (; *s; s++)
		if (*s == ',') *s = ' ';
}

static void edit_deps_task(int ti) {
	PN = 0;
	/* The loaded tasks are every task, so the active search cannot hide a legal
	 * dependency and this needs no second `backlog list`. */
	for (int i = 0; i < TASK_N; i++) {
		if (i == ti) continue;
		snprintf(PV[PN].val, SLOT, "%s", T[i].id);
		snprintf(PV[PN].label, SLOT, "%s -- %s", T[i].id, T[i].title);
		PN++;
	}
	if (!PN) {
		setmsg("no other task to depend on");
		return;
	}
	char marked[BIG], title[1200];
	snprintf(marked, sizeof marked, "%s", T[ti].deps);
	commas_to_spaces(marked);
	snprintf(title, sizeof title, "depends_on for %s  (space toggles)", T[ti].id);
	if (!pick(1, title, marked)) {
		setmsg("deps cancelled");
		return;
	}
	char csv[BIG];
	snprintf(csv, sizeof csv, "%s", PICK_RESULT);
	for (char *p = csv; *p; p++)
		if (*p == ' ') *p = ',';
	mutate("set-deps", T[ti].id, *csv ? csv : "--none", NULL);
}

static void move_epic_task(int ti) {
	int ok;
	char *out = cli(BACKLOG, &ok, 0, NULL, "epics", NULL);
	if (!*out && !*T[ti].epic) {
		free(out);
		setmsg("no epics yet -- press E to create one");
		return;
	}
	PN = 0;
	snprintf(PV[PN].val, SLOT, "--none");
	snprintf(PV[PN].label, SLOT, "(none) -- move out of any epic");
	PN++;
	char *line = out;
	while (*line && PN < MAXT) {
		char *nl = strchr(line, '\n');
		if (nl) *nl = 0;
		if (*line) {
			snprintf(PV[PN].val, SLOT, "%s", line);
			snprintf(PV[PN].label, SLOT, "epic: %s", line);
			PN++;
		}
		if (!nl) break;
		line = nl + 1;
	}
	free(out);
	char title[1200];
	snprintf(title, sizeof title, "epic for %s", T[ti].id);
	if (!pick(0, title, NULL)) {
		setmsg("epic move cancelled");
		return;
	}
	mutate("epic-move", T[ti].id, PICK_RESULT, NULL);
}

/* The epic exists before the editor runs, so an editor that writes nothing
 * leaves a real epic with an empty description -- epic-remove is the undo. */
static void new_epic(void) {
	char epic[SLOT];
	prompt("new epic id (slug, empty cancels): ", epic, sizeof epic);
	if (!*epic) {
		setmsg("new epic: cancelled");
		return;
	}
	int ok;
	char *out = cli(BACKLOG, &ok, 1, NULL, "epic-add", epic, NULL);
	chomp(out);
	if (!ok) {
		setmsg("epic-add failed: %s", out);
		free(out);
		return;
	}
	free(out);
	char desc[PATH_MAX];
	snprintf(desc, sizeof desc, "%s/%s/DESCRIPTION.md", BACKLOG_TASKS_DIR, epic);
	const char *ed = getenv("EDITOR");
	run_external(ed && *ed ? ed : "vi", desc);
	struct stat st;
	if (stat(desc, &st) == 0 && st.st_size > 0) setmsg("created epic %s", epic);
	else setmsg("created epic %s -- description left empty", epic);
}

/* The whole human-side composition: everything the agent-facing stack keeps
 * behind pointers, gathered for the selected row. */
static void compose_detail(FILE *f) {
	int ti = cur_task();
	int ok;
	if (ti < 0) {
		fprintf(f, "# epic: %s\n\n", row_epic[SEL]);
		char *d = cli(BACKLOG, &ok, 0, NULL, "epic-show", row_epic[SEL], NULL);
		fputs(ok && *d ? d : "(no description)\n", f);
		free(d);
		fprintf(f, "\n## Tasks\n\n");
		for (int i = 0; i < TASK_N; i++)
			if (!strcmp(T[i].epic, row_epic[SEL])) fprintf(f, "- %s\n", T[i].title);
		return;
	}
	fprintf(f, "# %s\n\n", T[ti].title);
	fprintf(f, "id: %s\ncategory: %s\npriority: %s\n", T[ti].id, T[ti].cat,
		*T[ti].prio ? T[ti].prio : "(unset)");
	fprintf(f, "\n## Task\n\n");
	char path[PATH_MAX];
	task_path(ti, path, sizeof path);
	FILE *body = fopen(path, "r");
	if (body) {
		char buf[BIG];
		size_t n;
		while ((n = fread(buf, 1, sizeof buf, body)) > 0) fwrite(buf, 1, n, f);
		fclose(body);
	}
	fprintf(f, "\n## Epic\n\n");
	if (*T[ti].epic) {
		fprintf(f, "%s\n\n", T[ti].epic);
		char *d = cli(BACKLOG, &ok, 0, NULL, "epic-show", T[ti].epic, NULL);
		fputs(ok && *d ? d : "(no description)\n", f);
		free(d);
	} else {
		fprintf(f, "(ungrouped)\n");
	}
	fprintf(f, "\n## Plans\n\n");
	char *meta = cli(BACKLOG, &ok, 0, NULL, "meta", T[ti].id, NULL);
	int any_plan = 0;
	char *line = meta;
	while (*line) {
		char *nl = strchr(line, '\n');
		if (nl) *nl = 0;
		if (!strncmp(line, "plan\t", 5)) {
			const char *p = line + 5;
			char abs[PATH_MAX];
			if (*p == '/') snprintf(abs, sizeof abs, "%s", p);
			else snprintf(abs, sizeof abs, "%s/%s", NAMESPACE_DIR, p);
			fprintf(f, "### %s\n\n", p);
			FILE *pf = fopen(abs, "r");
			if (pf) {
				char buf[BIG];
				size_t n;
				while ((n = fread(buf, 1, sizeof buf, pf)) > 0) fwrite(buf, 1, n, f);
				fclose(pf);
			} else {
				fprintf(f, "(plan file missing)\n");
			}
			fprintf(f, "\n");
			any_plan = 1;
		}
		if (!nl) break;
		line = nl + 1;
	}
	free(meta);
	if (!any_plan) fprintf(f, "(no plan)\n");
	fprintf(f, "\n## Depends on\n\n");
	if (!*T[ti].deps) {
		fprintf(f, "(none)\n");
		return;
	}
	char list[SLOT];
	snprintf(list, sizeof list, "%s", T[ti].deps);
	commas_to_spaces(list);
	char *save = NULL, *tok = strtok_r(list, " ", &save);
	while (tok) {
		const char *title = NULL;
		for (int i = 0; i < TASK_N; i++)
			if (!strcmp(T[i].id, tok)) title = T[i].title;
		char *found = NULL;
		if (!title) {
			/* An id the index no longer carries: `find` is the fallback. */
			found = cli(BACKLOG, &ok, 0, NULL, "find", tok, NULL);
			char *nl = strchr(found, '\n');
			if (nl) *nl = 0;
			char *t1 = strchr(found, '\t');
			char *t2 = t1 ? strchr(t1 + 1, '\t') : NULL;
			if (t2) {
				char *t3 = strchr(t2 + 1, '\t');
				if (t3) *t3 = 0;
				title = t2 + 1;
			}
		}
		fprintf(f, "- %s -- %s\n", tok, title && *title ? title : "(unknown id)");
		free(found);
		tok = strtok_r(NULL, " ", &save);
	}
}

/* `v` composes unconditionally: its CLI calls are a keypress the user chose,
 * not a redraw. */
static void view_task(void) {
	if (N <= 0) return;
	FILE *f = fopen(DETAIL_FILE, "w");
	if (!f) return;
	compose_detail(f);
	fclose(f);
	const char *pager = getenv("PAGER");
	run_external(pager && *pager ? pager : "less", DETAIL_FILE);
}

static void help_screen(void) {
	printf("\033[H\033[2J");
	printf(
		"radin tui keys\n\n"
		"  j / down      next task\n"
		"  k / up        previous task\n"
		"  g / G         first / last task\n"
		"  enter, e      edit the task body in $EDITOR (an epic row: collapse/expand)\n"
		"  v             view the composed detail in $PAGER: the body, the epic's\n"
		"                own description, every plan file and the dependency titles --\n"
		"                everything the pane leaves out\n"
		"  Tab           the Done view: completed tasks and their commits (read-only)\n"
		"  a             new task (category, title, then body in $EDITOR)\n"
		"  d             delete the selected task (asks first)\n"
		"  c             move the task to the next category\n"
		"  r             retitle the task (its id never changes)\n"
		"  p             set priority: pick from 21 13 8 5 3 2 1 or clear it\n"
		"  D             edit depends_on: pick from the other tasks, space toggles\n"
		"  m             move the task into an epic, or out of one\n"
		"  E             create an epic, then write its DESCRIPTION.md in $EDITOR\n"
		"  /             search id and title; matching rows are marked * (empty clears)\n"
		"  n / N         next / previous matching row (wraps)\n"
		"  R             reload from disk\n"
		"  q             quit\n\n"
		"Row colour is the priority band, relative to the priorities now shown:\n"
		"red highest third, yellow middle, green lowest, no colour when unset.\n"
		"Set NO_COLOR to a non-empty value to turn it off.\n"
		"A P in the first column marks a task radin-plan has already planned.\n"
		"A * in the left margin marks a row matching the active / search.\n"
		"Epic rows are headers; collapse is per-session.\n"
		"Tasks live in .claude/.radin/backlog/ in this repo.\n\n"
		"press any key\n");
	fflush(stdout);
	readkey();
}

/* ---------- namespace ---------- */

static void mkdirs(const char *path) {
	char buf[PATH_MAX];
	snprintf(buf, sizeof buf, "%s", path);
	for (char *p = buf + 1; *p; p++) {
		if (*p != '/') continue;
		*p = 0;
		mkdir(buf, 0755);
		*p = '/';
	}
	mkdir(buf, 0755);
}

/* Same resolution as radin-namespace.sh: the git top level, else $PWD. */
static void resolve_namespace(void) {
	char *av[5] = {(char *)"/usr/bin/env", (char *)"git", (char *)"rev-parse",
		(char *)"--show-toplevel", NULL};
	int ok;
	char *top = run(av, &ok, 0, NULL);
	chomp(top);
	if (ok && *top) snprintf(REPO_ROOT, sizeof REPO_ROOT, "%s", top);
	else if (!getcwd(REPO_ROOT, sizeof REPO_ROOT)) die("cannot resolve the repo root");
	free(top);
	snprintf(NAMESPACE_DIR, sizeof NAMESPACE_DIR, "%s/.claude/.radin", REPO_ROOT);
	snprintf(BACKLOG_DIR, sizeof BACKLOG_DIR, "%s/backlog", NAMESPACE_DIR);
	snprintf(BACKLOG_TASKS_DIR, sizeof BACKLOG_TASKS_DIR, "%s/tasks", BACKLOG_DIR);
	char p[PATH_MAX];
	snprintf(p, sizeof p, "%s/state/facts", NAMESPACE_DIR);
	mkdirs(p);
	snprintf(p, sizeof p, "%s/plans", NAMESPACE_DIR);
	mkdirs(p);
	snprintf(p, sizeof p, "%s/reviews", NAMESPACE_DIR);
	mkdirs(p);
	mkdirs(BACKLOG_TASKS_DIR);
}

/* The shell CLIs live next to this binary's lib dir: $RADIN_LIB when the
 * dispatcher set it, else the directory this binary was started from. */
static void resolve_lib(const char *argv0) {
	const char *env = getenv("RADIN_LIB");
	if (env && *env) {
		snprintf(LIB_DIR, sizeof LIB_DIR, "%s", env);
	} else {
		snprintf(LIB_DIR, sizeof LIB_DIR, "%s", argv0);
		char *slash = strrchr(LIB_DIR, '/');
		if (slash) *slash = 0;
		else snprintf(LIB_DIR, sizeof LIB_DIR, ".");
	}
	snprintf(BACKLOG, sizeof BACKLOG, "%s/radin-backlog.sh", LIB_DIR);
	snprintf(STATE, sizeof STATE, "%s/radin-state.sh", LIB_DIR);
	if (access(BACKLOG, R_OK) != 0)
		die("cannot find radin-backlog.sh -- set RADIN_LIB to radin's lib directory");
}

int main(int argc, char **argv) {
	(void)argc;
	if (!isatty(0) || !isatty(1)) {
		fprintf(stderr,
			"radin tui: needs an interactive terminal; use \"radin backlog show\" "
			"when piping\n");
		return 1;
	}
	const char *nc = getenv("NO_COLOR");
	if (nc && *nc) COLOR = 0;
	resolve_lib(argv[0]);
	resolve_namespace();
	snprintf(DETAIL_FILE, sizeof DETAIL_FILE, "%s/tui-detail.XXXXXX", NAMESPACE_DIR);
	int fd = mkstemp(DETAIL_FILE);
	if (fd >= 0) close(fd);
	signal(SIGINT, on_signal);
	signal(SIGTERM, on_signal);
	signal(SIGHUP, on_signal);
	raw_on();
	load();

	for (;;) {
		if (MODE_DONE) draw_done();
		else draw();
		MSG[0] = 0;
		int k = readkey();
		if (k < 0) break;
		if (move_key(k)) {
			coalesce();
			continue;
		}
		if (MODE_DONE) {
			if (k == '\t') MODE_DONE = 0;
			else if (k == 'R') {
				load_done();
				setmsg("reloaded");
			} else if (k == '?') help_screen();
			else if (k == 'q') break;
			continue;
		}
		int ti;
		switch (k) {
		case 'e':
		case '\r':
		case '\n':
			ti = cur_task();
			if (ti >= 0) edit_body(ti);
			else toggle_collapse();
			break;
		case 'v': view_task(); break;
		case '\t':
			MODE_DONE = 1;
			load_done();
			break;
		case 'a': new_task(); break;
		case 'd': if ((ti = sel_task()) >= 0) delete_task(ti); break;
		case 'c': if ((ti = sel_task()) >= 0) cycle_category(ti); break;
		case 'r': if ((ti = sel_task()) >= 0) retitle_task(ti); break;
		case 'p': if ((ti = sel_task()) >= 0) set_priority_task(ti); break;
		case 'D': if ((ti = sel_task()) >= 0) edit_deps_task(ti); break;
		case 'm': if ((ti = sel_task()) >= 0) move_epic_task(ti); break;
		case 'E': new_epic(); break;
		case '/':
			prompt("search: ", SEARCH, sizeof SEARCH);
			SEL = 0;
			TOP = 0;
			break;
		case 'R':
			load();
			setmsg("reloaded");
			break;
		case '?': help_screen(); break;
		case 'q': cleanup(); return 0;
		default: break;
		}
	}
	cleanup();
	return 0;
}
