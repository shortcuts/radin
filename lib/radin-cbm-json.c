/* The JSON surgery behind `radin cbm-config`, so radin-cbm-config.sh can
 * rewrite ~/.claude/settings.json and ~/.claude.json without python3 --
 * radin ships bash and C only. Not a general-purpose JSON tool: only
 * lib/radin-cbm-config.sh calls it, and every rule it encodes is about
 * upstream codebase-memory-mcp's destructive write (#1200).
 *
 *   radin-cbm-json restore   <settings> <snap_settings> <claude_json> <snap_claude_json> <cbm>
 *   radin-cbm-json adopt-mcp <staged_claude_json> <claude_json>
 *   radin-cbm-json wired     <settings> <claude_json> <cbm>
 *
 * An empty path argument means "absent" (what python passed as None).
 *
 * Design: a parsed string, number or literal keeps its *source text*, and
 * writing it back emits those bytes unchanged. There is therefore no
 * \uXXXX decoder, no float round-trip and no big-integer round-trip to get
 * wrong: a key this file does not understand cannot be mangled. The only
 * value ever re-encoded is a hook `command` this file itself rewrites.
 *
 * Two documented divergences from the python it replaces, both harmless:
 * re-encoding passes bytes >= 0x80 through instead of emitting \uXXXX
 * (python used ensure_ascii=True; both are valid JSON), and a `command`
 * whose source text carries an escape this file does not decode is left
 * unjudged rather than decoded -- never pruned, never rewritten.
 *
 * All allocation is malloc with no free: the process does one job and exits.
 * Must compile clean under `cc -O2` with no dependency beyond libc, the same
 * bar as lib/radin-tui.c. Built by install.sh into
 * ~/.claude/.radin/bin/radin-cbm-json.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* ---------- allocation ---------- */

static void oom(void)
{
	fprintf(stderr, "radin-cbm-config: out of memory\n");
	exit(1);
}

static void *xmalloc(size_t n)
{
	void *p = malloc(n ? n : 1);
	if (!p)
		oom();
	return p;
}

static char *xstrndup(const char *s, size_t n)
{
	char *r = xmalloc(n + 1);
	memcpy(r, s, n);
	r[n] = 0;
	return r;
}

static char *xstrdup(const char *s) { return xstrndup(s, strlen(s)); }

/* ---------- data model ---------- */

typedef enum { J_OBJ, J_ARR, J_STR, J_LIT } JKind; /* J_LIT: number|true|false|null */
typedef struct JVal JVal;
typedef struct JMem {
	char *key; /* raw slice, as it appeared between the quotes */
	JVal *val;
	struct JMem *next;
} JMem;
struct JVal {
	JKind kind;
	char *raw;         /* J_STR: source text between the quotes, still escaped.
	                    * J_LIT: the token verbatim. */
	JMem *head, *tail; /* J_OBJ, insertion-ordered */
	JVal **items;      /* J_ARR */
	int n, cap;
};

static JVal *jnew(JKind k)
{
	JVal *v = xmalloc(sizeof *v);
	memset(v, 0, sizeof *v);
	v->kind = k;
	return v;
}

static JVal *jstr(char *raw)
{
	JVal *v = jnew(J_STR);
	v->raw = raw;
	return v;
}

static JVal *obj_get(JVal *o, const char *key)
{
	JMem *m;
	if (!o || o->kind != J_OBJ)
		return NULL;
	for (m = o->head; m; m = m->next)
		if (!strcmp(m->key, key))
			return m->val;
	return NULL;
}

/* Replaces in place when the key exists, appends otherwise: key order has to
 * survive, because the idempotency test compares the file byte-for-byte
 * across two runs and restore_settings re-adds dropped top-level keys after
 * the surviving ones. */
static void obj_set(JVal *o, const char *key, JVal *v)
{
	JMem *m;
	for (m = o->head; m; m = m->next)
		if (!strcmp(m->key, key)) {
			m->val = v;
			return;
		}
	m = xmalloc(sizeof *m);
	m->key = xstrdup(key);
	m->val = v;
	m->next = NULL;
	if (o->tail)
		o->tail->next = m;
	else
		o->head = m;
	o->tail = m;
}

static void arr_push(JVal *a, JVal *v)
{
	if (a->n == a->cap) {
		JVal **ni;
		a->cap = a->cap ? a->cap * 2 : 4;
		ni = xmalloc((size_t)a->cap * sizeof *ni);
		if (a->n)
			memcpy(ni, a->items, (size_t)a->n * sizeof *ni);
		a->items = ni;
	}
	a->items[a->n++] = v;
}

/* ---------- parser ---------- */

typedef struct {
	const char *p;
	int bad;
} P;

static void skipws(P *s)
{
	while (*s->p == ' ' || *s->p == '\t' || *s->p == '\n' || *s->p == '\r')
		s->p++;
}

static char *pstr_raw(P *s)
{
	const char *start;
	if (*s->p != '"') {
		s->bad = 1;
		return NULL;
	}
	s->p++;
	start = s->p;
	while (*s->p && *s->p != '"') {
		if (*s->p == '\\' && s->p[1])
			s->p++;
		s->p++;
	}
	if (*s->p != '"') {
		s->bad = 1;
		return NULL;
	}
	{
		char *raw = xstrndup(start, (size_t)(s->p - start));
		s->p++;
		return raw;
	}
}

static JVal *pval(P *s);

static JVal *pobj(P *s)
{
	JVal *o = jnew(J_OBJ);
	s->p++; /* '{' */
	skipws(s);
	if (*s->p == '}') {
		s->p++;
		return o;
	}
	for (;;) {
		char *key;
		JVal *v;
		skipws(s);
		key = pstr_raw(s);
		if (s->bad)
			return NULL;
		skipws(s);
		if (*s->p != ':') {
			s->bad = 1;
			return NULL;
		}
		s->p++;
		skipws(s);
		v = pval(s);
		if (s->bad)
			return NULL;
		{
			JMem *m = xmalloc(sizeof *m);
			m->key = key;
			m->val = v;
			m->next = NULL;
			if (o->tail)
				o->tail->next = m;
			else
				o->head = m;
			o->tail = m;
		}
		skipws(s);
		if (*s->p == ',') {
			s->p++;
			continue;
		}
		if (*s->p == '}') {
			s->p++;
			return o;
		}
		s->bad = 1;
		return NULL;
	}
}

static JVal *parr(P *s)
{
	JVal *a = jnew(J_ARR);
	s->p++; /* '[' */
	skipws(s);
	if (*s->p == ']') {
		s->p++;
		return a;
	}
	for (;;) {
		JVal *v;
		skipws(s);
		v = pval(s);
		if (s->bad)
			return NULL;
		arr_push(a, v);
		skipws(s);
		if (*s->p == ',') {
			s->p++;
			continue;
		}
		if (*s->p == ']') {
			s->p++;
			return a;
		}
		s->bad = 1;
		return NULL;
	}
}

static int lit_byte(char c)
{
	return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') ||
	       (c >= 'A' && c <= 'Z') || c == '-' || c == '+' || c == '.';
}

static JVal *pval(P *s)
{
	if (*s->p == '{')
		return pobj(s);
	if (*s->p == '[')
		return parr(s);
	if (*s->p == '"') {
		char *raw = pstr_raw(s);
		return s->bad ? NULL : jstr(raw);
	}
	{
		const char *start = s->p;
		JVal *v;
		while (lit_byte(*s->p))
			s->p++;
		if (s->p == start) {
			s->bad = 1;
			return NULL;
		}
		v = jnew(J_LIT);
		v->raw = xstrndup(start, (size_t)(s->p - start));
		return v;
	}
}

/* err: 0 ok, 1 absent (an empty path counts as absent), 2 invalid JSON.
 * Every caller must tell 1 from 2 -- absent is a normal state, invalid JSON
 * is the refuse-and-exit case in `restore` and a silent {} elsewhere. */
static JVal *parse_file(const char *path, int *err)
{
	FILE *f;
	char *buf;
	size_t cap = 4096, len = 0, got;
	P s;
	JVal *v;

	*err = 1;
	if (!path || !*path)
		return NULL;
	f = fopen(path, "r");
	if (!f)
		return NULL;
	buf = xmalloc(cap);
	while ((got = fread(buf + len, 1, cap - len - 1, f)) > 0) {
		len += got;
		if (len + 1 >= cap) {
			char *nb;
			cap *= 2;
			nb = xmalloc(cap);
			memcpy(nb, buf, len);
			buf = nb;
		}
	}
	fclose(f);
	buf[len] = 0;

	s.p = buf;
	s.bad = 0;
	skipws(&s);
	v = pval(&s);
	skipws(&s);
	if (!v || s.bad || *s.p) {
		*err = 2;
		return NULL;
	}
	*err = 0;
	return v;
}

/* ---------- strings ---------- */

/* The eight two-character escapes only. Anything else (\uXXXX above all)
 * returns NULL, and every caller then leaves the value alone rather than
 * guessing: that way no path is invented from an escape this file did not
 * decode, so no such entry is pruned or rewritten. */
static char *str_decode(const char *raw)
{
	size_t n = strlen(raw), i, k = 0;
	char *r = xmalloc(n + 1);
	for (i = 0; i < n; i++) {
		if (raw[i] != '\\') {
			r[k++] = raw[i];
			continue;
		}
		if (++i >= n)
			break;
		switch (raw[i]) {
		case '"': r[k++] = '"'; break;
		case '\\': r[k++] = '\\'; break;
		case '/': r[k++] = '/'; break;
		case 'b': r[k++] = '\b'; break;
		case 'f': r[k++] = '\f'; break;
		case 'n': r[k++] = '\n'; break;
		case 'r': r[k++] = '\r'; break;
		case 't': r[k++] = '\t'; break;
		default: return NULL;
		}
	}
	r[k] = 0;
	return r;
}

static char *str_encode(const char *b)
{
	size_t n = strlen(b), i, k = 0;
	char *r = xmalloc(n * 6 + 1);
	for (i = 0; i < n; i++) {
		unsigned char c = (unsigned char)b[i];
		switch (c) {
		case '"': r[k++] = '\\'; r[k++] = '"'; break;
		case '\\': r[k++] = '\\'; r[k++] = '\\'; break;
		case '\b': r[k++] = '\\'; r[k++] = 'b'; break;
		case '\f': r[k++] = '\\'; r[k++] = 'f'; break;
		case '\n': r[k++] = '\\'; r[k++] = 'n'; break;
		case '\r': r[k++] = '\\'; r[k++] = 'r'; break;
		case '\t': r[k++] = '\\'; r[k++] = 't'; break;
		default:
			if (c < 0x20)
				k += (size_t)snprintf(r + k, 7, "\\u%04x", c);
			else
				r[k++] = (char)c;
		}
	}
	r[k] = 0;
	return r;
}

/* ---------- serializer: one printer, two modes ---------- */

static void emit_pad(FILE *f, int n)
{
	int i;
	for (i = 0; i < n; i++)
		fputs("  ", f);
}

static void emit_raw_str(FILE *f, const char *raw)
{
	fputc('"', f);
	fputs(raw, f);
	fputc('"', f);
}

/* indent >= 0 pretty-prints at that depth (two spaces per level, ": " between
 * key and value, {} and [] on one line when empty -- json.dump(indent=2));
 * indent < 0 writes compact. sort orders object members by raw key bytes.
 * The only code that turns a JVal back into JSON, deliberately: the escaping
 * and the empty-container rules must not be able to drift between the file
 * the user gets and the string equality is judged on. */
static void emit(FILE *f, JVal *v, int ind, int sort)
{
	int pretty = ind >= 0, i;
	switch (v->kind) {
	case J_LIT:
		fputs(v->raw, f);
		return;
	case J_STR:
		emit_raw_str(f, v->raw);
		return;
	case J_ARR:
		if (!v->n) {
			fputs("[]", f);
			return;
		}
		fputc('[', f);
		for (i = 0; i < v->n; i++) {
			if (i)
				fputc(',', f);
			if (pretty) {
				fputc('\n', f);
				emit_pad(f, ind + 1);
			}
			emit(f, v->items[i], pretty ? ind + 1 : -1, sort);
		}
		if (pretty) {
			fputc('\n', f);
			emit_pad(f, ind);
		}
		fputc(']', f);
		return;
	case J_OBJ: {
		JMem **a, *m;
		int n = 0;
		for (m = v->head; m; m = m->next)
			n++;
		if (!n) {
			fputs("{}", f);
			return;
		}
		/* A copy, never the live list: canon() must not reorder a node the
		 * caller is about to write back. */
		a = xmalloc((size_t)n * sizeof *a);
		n = 0;
		for (m = v->head; m; m = m->next)
			a[n++] = m;
		if (sort)
			for (i = 1; i < n; i++) {
				JMem *k = a[i];
				int j = i - 1;
				while (j >= 0 && strcmp(a[j]->key, k->key) > 0) {
					a[j + 1] = a[j];
					j--;
				}
				a[j + 1] = k;
			}
		fputc('{', f);
		for (i = 0; i < n; i++) {
			if (i)
				fputc(',', f);
			if (pretty) {
				fputc('\n', f);
				emit_pad(f, ind + 1);
			}
			emit_raw_str(f, a[i]->key);
			fputs(": ", f);
			emit(f, a[i]->val, pretty ? ind + 1 : -1, sort);
		}
		if (pretty) {
			fputc('\n', f);
			emit_pad(f, ind);
		}
		fputc('}', f);
		return;
	}
	}
}

/* python's json.dumps(x, sort_keys=True): serves both the deep-equality
 * compare and the cbm/cbm- substring test. */
static char *canon(JVal *v)
{
	char *buf = NULL;
	size_t len = 0;
	FILE *f = open_memstream(&buf, &len);
	if (!f)
		oom();
	if (v)
		emit(f, v, -1, 1);
	else
		fputs("{}", f);
	fclose(f);
	return buf;
}

/* Through a temp file in the same directory, so a crash mid-write cannot
 * truncate the user's settings.json. */
static void write_file(const char *path, JVal *v)
{
	char *tmp;
	FILE *f;
	size_t n = strlen(path) + 12;
	tmp = xmalloc(n);
	snprintf(tmp, n, "%s.radin.tmp", path);
	f = fopen(tmp, "w");
	if (!f) {
		fprintf(stderr, "radin-cbm-config: cannot write %s\n", tmp);
		exit(1);
	}
	emit(f, v, 0, 0);
	fputc('\n', f);
	if (fclose(f) != 0 || rename(tmp, path) != 0) {
		fprintf(stderr, "radin-cbm-config: cannot write %s\n", path);
		exit(1);
	}
}

/* ---------- shell words and paths ---------- */

/* POSIX-ish: split on blanks, honour '...' (literal) and "..." (backslash
 * escapes), and backslash outside quotes. Non-zero on an unterminated quote. */
static int shlex_split(const char *s, char ***words, int *count)
{
	size_t len = strlen(s), k;
	int cap = 8, n = 0;
	char **w = xmalloc((size_t)cap * sizeof *w);
	char *buf = xmalloc(len + 1);
	const char *p = s;
	while (*p) {
		while (*p == ' ' || *p == '\t' || *p == '\n')
			p++;
		if (!*p)
			break;
		k = 0;
		while (*p && *p != ' ' && *p != '\t' && *p != '\n') {
			if (*p == '\'') {
				p++;
				while (*p && *p != '\'')
					buf[k++] = *p++;
				if (!*p)
					return 1;
				p++;
			} else if (*p == '"') {
				p++;
				while (*p && *p != '"') {
					if (*p == '\\' && p[1])
						p++;
					buf[k++] = *p++;
				}
				if (!*p)
					return 1;
				p++;
			} else if (*p == '\\') {
				p++;
				if (!*p)
					return 1;
				buf[k++] = *p++;
			} else
				buf[k++] = *p++;
		}
		buf[k] = 0;
		if (n == cap) {
			char **nw;
			cap *= 2;
			nw = xmalloc((size_t)cap * sizeof *nw);
			memcpy(nw, w, (size_t)n * sizeof *nw);
			w = nw;
		}
		w[n++] = xstrdup(buf);
	}
	*words = w;
	*count = n;
	return 0;
}

/* python's shlex.quote. */
static char *shlex_quote(const char *w)
{
	static const char *safe = "abcdefghijklmnopqrstuvwxyz"
	                          "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-";
	const char *p;
	size_t k = 0;
	char *r;
	if (!*w)
		return xstrdup("''");
	for (p = w; *p; p++)
		if (!strchr(safe, (unsigned char)*p))
			break;
	if (!*p)
		return xstrdup(w);
	r = xmalloc(strlen(w) * 5 + 3);
	r[k++] = '\'';
	for (p = w; *p; p++) {
		if (*p == '\'') {
			memcpy(r + k, "'\"'\"'", 5);
			k += 5;
		} else
			r[k++] = *p;
	}
	r[k++] = '\'';
	r[k] = 0;
	return r;
}

static char *expanduser(const char *p)
{
	const char *home;
	if (p[0] != '~' || (p[1] && p[1] != '/'))
		return xstrdup(p);
	home = getenv("HOME");
	if (!home)
		return xstrdup(p);
	{
		size_t n = strlen(home) + strlen(p);
		char *r = xmalloc(n + 1);
		snprintf(r, n + 1, "%s%s", home, p + 1);
		return r;
	}
}

static int path_exists(const char *p) { return access(p, F_OK) == 0; }

/* ---------- behaviour ---------- */

static const char *settings_path;
static const char *claude_json_path;
static const char *cbm;

static void bail(const char *label)
{
	fprintf(stderr, "radin-cbm-config: %s is not valid JSON -- nothing restored, "
	                "your snapshot is still on disk\n", label);
	exit(1);
}

/* Refuse the whole restore rather than write over a file we cannot read.
 * A root that is not an object is the same problem. */
static JVal *load_strict(const char *path)
{
	int err;
	JVal *v = parse_file(path, &err);
	if (err == 2)
		bail(path);
	if (v && v->kind != J_OBJ)
		bail(path);
	return v;
}

/* Missing or unreadable reads as {} here, unlike the restore path: adopting
 * is additive, so there is nothing to lose. */
static JVal *load_lax(const char *path)
{
	int err;
	JVal *v = parse_file(path, &err);
	return (v && v->kind == J_OBJ) ? v : jnew(J_OBJ);
}

static int blank(const char *s)
{
	for (; *s; s++)
		if (*s != ' ' && *s != '\t' && *s != '\n' && *s != '\r')
			return 0;
	return 1;
}

/* What a message shows for a command value. */
static const char *disp(JVal *v)
{
	char *d;
	if (!v)
		return "";
	if (v->kind != J_STR)
		return canon(v);
	d = str_decode(v->raw);
	return d ? d : v->raw;
}

/* An upstream hook entry whose command spelling changed between versions
 * looks dropped rather than replaced, so restoring it resurrects a dead path
 * forever. Upstream owns its own entries; radin only puts back another
 * tool's. Its hook entries run shims named cbm-* rather than the full binary
 * name, so match either spelling. */
static int is_cbm_entry(JVal *entry)
{
	char *b = canon(entry);
	return strstr(b, cbm) != NULL || strstr(b, "cbm-") != NULL;
}

static int command_exists(JVal *cmd)
{
	char *s, **w;
	int n;
	if (!cmd || cmd->kind != J_STR)
		return 1;
	s = str_decode(cmd->raw);
	if (!s || blank(s))
		return 1;
	/* An unterminated quote keeps the entry: python raised there and aborted
	 * the whole restore, and keeping a hook can never corrupt the file. */
	if (shlex_split(s, &w, &n) || n == 0)
		return 1;
	/* Judge a path only. A bare shim name resolves against Claude Code's
	 * PATH, not this process's, so calling it missing here would prune a live
	 * hook. */
	if (!strchr(w[0], '/'))
		return 1;
	return path_exists(expanduser(w[0]));
}

/* A hook command naming a path that does not exist can only fail. Upstream
 * merges PreToolUse instead of replacing it, and a ~/.claude shared between
 * machines carries the other machine's $HOME, so such an entry survives every
 * rerun and prints `no such file or directory` on each session start. Dropped
 * whoever wrote it: radin cannot re-point another tool's hook, and leaving it
 * in place is the error the user sees. */
static int prune_dead(JVal *hooks)
{
	JMem *m;
	int changed = 0;
	for (m = hooks->head; m; m = m->next) {
		JVal *entries = m->val, *kept;
		int i, j;
		if (!entries || entries->kind != J_ARR)
			continue;
		kept = jnew(J_ARR);
		for (i = 0; i < entries->n; i++) {
			JVal *entry = entries->items[i], *hs, *live;
			hs = (entry && entry->kind == J_OBJ) ? obj_get(entry, "hooks") : NULL;
			if (!hs || hs->kind != J_ARR) {
				arr_push(kept, entry);
				continue;
			}
			live = jnew(J_ARR);
			for (j = 0; j < hs->n; j++) {
				JVal *h = hs->items[j];
				if (h->kind != J_OBJ || command_exists(obj_get(h, "command")))
					arr_push(live, h);
				else
					printf("PRUNED   %s (hooks.%s: '%s' does not exist)\n",
					       settings_path, m->key, disp(obj_get(h, "command")));
			}
			if (live->n == hs->n) {
				arr_push(kept, entry);
				continue;
			}
			changed = 1;
			if (live->n) {
				obj_set(entry, "hooks", live);
				arr_push(kept, entry);
			}
		}
		m->val = kept;
	}
	return changed;
}

/* Upstream writes its hook commands as a quoted absolute path, so a ~/.claude
 * shared between machines carries the other machine's $HOME. The fix is the
 * prune above, not a ~/ rewrite: Claude Code posix_spawns a single-word hook
 * command directly, and a lone `~/.local/bin/codebase-memory-mcp` then dies
 * with `ENOENT ... posix_spawn`. Only a command with further words reaches a
 * shell that would expand the tilde (docs/technical-constraints.md), so every
 * hook command gets an absolute path here, unquoted -- including the ~/ form
 * radin itself wrote before this was understood. Re-quoting also drops
 * upstream's quotes around a lone absolute path: a single-word command is
 * posix_spawned verbatim, so "'/abs/path'" is a file name with quotes in it
 * and dies the same way a bare ~ does. Returns NULL when nothing changed. */
static char *absolute(JVal *cmd)
{
	char *s, **w, *out;
	int n, i;
	size_t len = 1, k = 0;
	if (!cmd || cmd->kind != J_STR)
		return NULL;
	s = str_decode(cmd->raw);
	if (!s || blank(s))
		return NULL;
	if (shlex_split(s, &w, &n))
		return NULL;
	for (i = 0; i < n; i++) {
		w[i] = shlex_quote(expanduser(w[i]));
		len += strlen(w[i]) + 1;
	}
	out = xmalloc(len);
	for (i = 0; i < n; i++) {
		if (i)
			out[k++] = ' ';
		memcpy(out + k, w[i], strlen(w[i]));
		k += strlen(w[i]);
	}
	out[k] = 0;
	return strcmp(out, s) ? out : NULL;
}

/* Only cbm entries: radin does not rewrite another tool's hook. */
static int normalize_cbm(JVal *hooks)
{
	JMem *m;
	int changed = 0;
	for (m = hooks->head; m; m = m->next) {
		JVal *entries = m->val;
		int i, j;
		if (!entries || entries->kind != J_ARR)
			continue;
		for (i = 0; i < entries->n; i++) {
			JVal *entry = entries->items[i], *hs;
			hs = (entry && entry->kind == J_OBJ) ? obj_get(entry, "hooks") : NULL;
			if (!hs || hs->kind != J_ARR || !is_cbm_entry(entry))
				continue;
			for (j = 0; j < hs->n; j++) {
				JVal *h = hs->items[j];
				char *rewritten;
				if (h->kind != J_OBJ)
					continue;
				rewritten = absolute(obj_get(h, "command"));
				if (!rewritten)
					continue;
				obj_set(h, "command", jstr(str_encode(rewritten)));
				changed = 1;
				printf("ABSOLUTE %s (hooks.%s: '%s')\n", settings_path, m->key,
				       rewritten);
			}
		}
	}
	return changed;
}

static void restore_settings(const char *snap)
{
	JVal *old = load_strict(snap), *new = load_strict(settings_path);
	JVal *old_hooks, *new_hooks;
	JMem *m;
	int changed = 0;

	if (!new) {
		if (old) {
			write_file(settings_path, old);
			printf("RESTORED %s (whole file -- upstream's write removed it)\n",
			       settings_path);
		}
		return;
	}

	if (old)
		for (m = old->head; m; m = m->next) {
			if (!strcmp(m->key, "hooks"))
				continue;
			if (obj_get(new, m->key))
				continue;
			obj_set(new, m->key, m->val);
			changed = 1;
			printf("RESTORED %s (%s)\n", settings_path, m->key);
		}

	old_hooks = old ? obj_get(old, "hooks") : NULL;
	if (old_hooks && old_hooks->kind != J_OBJ)
		old_hooks = NULL;
	new_hooks = obj_get(new, "hooks");
	if (old_hooks && old_hooks->head && (!new_hooks || new_hooks->kind != J_OBJ)) {
		new_hooks = jnew(J_OBJ);
		obj_set(new, "hooks", new_hooks);
	}
	if (!new_hooks || new_hooks->kind != J_OBJ)
		new_hooks = jnew(J_OBJ); /* throwaway: nothing to merge into */

	for (m = old_hooks ? old_hooks->head : NULL; m; m = m->next) {
		JVal *old_entries = m->val, *filtered, *current, *missing;
		int i, j;
		if (!old_entries || old_entries->kind != J_ARR)
			continue;
		filtered = jnew(J_ARR);
		for (i = 0; i < old_entries->n; i++)
			if (!is_cbm_entry(old_entries->items[i]))
				arr_push(filtered, old_entries->items[i]);
		current = obj_get(new_hooks, m->key);
		if (!current || current->kind != J_ARR) {
			if (!filtered->n)
				continue;
			obj_set(new_hooks, m->key, filtered);
			changed = 1;
			printf("RESTORED %s (hooks.%s: %d entr%s, array was gone)\n",
			       settings_path, m->key, filtered->n,
			       filtered->n == 1 ? "y" : "ies");
			continue;
		}
		missing = jnew(J_ARR);
		for (i = 0; i < filtered->n; i++) {
			char *key = canon(filtered->items[i]);
			for (j = 0; j < current->n; j++)
				if (!strcmp(key, canon(current->items[j])))
					break;
			if (j == current->n)
				arr_push(missing, filtered->items[i]);
		}
		if (missing->n) {
			/* Pre-existing entries first, upstream's after: their order inside
			 * the event is what the owning tool expects. */
			JVal *merged = jnew(J_ARR);
			for (i = 0; i < missing->n; i++)
				arr_push(merged, missing->items[i]);
			for (i = 0; i < current->n; i++)
				arr_push(merged, current->items[i]);
			obj_set(new_hooks, m->key, merged);
			changed = 1;
			printf("RESTORED %s (hooks.%s: %d entr%s)\n", settings_path, m->key,
			       missing->n, missing->n == 1 ? "y" : "ies");
		} else
			printf("INTACT   %s (hooks.%s)\n", settings_path, m->key);
	}

	if (prune_dead(new_hooks))
		changed = 1;
	if (normalize_cbm(new_hooks))
		changed = 1;
	if (changed)
		write_file(settings_path, new);
}

static void restore_mcp_servers(const char *snap)
{
	JVal *old, *new, *old_servers, *servers;
	JMem *m;
	int restored = 0;

	old = load_strict(snap);
	if (!old)
		return;
	new = load_strict(claude_json_path);
	if (!new) {
		write_file(claude_json_path, old);
		printf("RESTORED %s (whole file -- upstream's write removed it)\n",
		       claude_json_path);
		return;
	}
	old_servers = obj_get(old, "mcpServers");
	if (!old_servers || old_servers->kind != J_OBJ || !old_servers->head)
		return;
	servers = obj_get(new, "mcpServers");
	if (!servers || servers->kind != J_OBJ) {
		servers = jnew(J_OBJ);
		obj_set(new, "mcpServers", servers);
	}
	for (m = old_servers->head; m; m = m->next) {
		if (obj_get(servers, m->key))
			continue;
		obj_set(servers, m->key, m->val);
		restored++;
		printf("RESTORED %s (mcpServers.%s)\n", claude_json_path, m->key);
	}
	if (restored)
		write_file(claude_json_path, new);
	else
		printf("INTACT   %s (mcpServers)\n", claude_json_path);
}

/* A ~/.claude.json shared between machines names the other machine's binary,
 * which is no entry at all here, so replace it rather than keep it. The
 * absolute path stays: Claude Code posix_spawns an mcpServers command instead
 * of running it through a shell, so a leading ~ is a literal directory name
 * and the server fails with ENOENT (verified -- see
 * docs/technical-constraints.md). Detecting a stale path is the only fix
 * available here; don't retry the ~/ rewrite the hook commands get. */
static int stale(JVal *entry)
{
	JVal *cmd;
	char *s;
	if (!entry || entry->kind != J_OBJ)
		return 0;
	cmd = obj_get(entry, "command");
	if (!cmd || cmd->kind != J_STR)
		return 0;
	s = str_decode(cmd->raw);
	if (!s || !strchr(s, '/'))
		return 0;
	return !path_exists(expanduser(s));
}

/* With CLAUDE_CONFIG_DIR set, upstream writes its MCP entry beside that
 * directory instead of at ~/.claude.json, which is the file Claude Code
 * reads. Move that one key over, never overwriting a live entry. */
static void adopt_mcp(const char *staged_path)
{
	JVal *staged = load_lax(staged_path), *staged_servers, *target, *servers;
	JMem *m;
	int adopted = 0;

	staged_servers = obj_get(staged, "mcpServers");
	if (!staged_servers || staged_servers->kind != J_OBJ || !staged_servers->head)
		return;
	target = load_lax(claude_json_path);
	servers = obj_get(target, "mcpServers");
	if (!servers || servers->kind != J_OBJ) {
		servers = jnew(J_OBJ);
		obj_set(target, "mcpServers", servers);
	}
	for (m = staged_servers->head; m; m = m->next) {
		JVal *existing = obj_get(servers, m->key);
		if (existing && !stale(existing))
			continue;
		obj_set(servers, m->key, m->val);
		adopted++;
		printf("ADOPTED  %s (mcpServers.%s from %s)\n", claude_json_path, m->key,
		       staged_path);
	}
	if (adopted)
		write_file(claude_json_path, target);
}

/* Did upstream's configuration actually land? It exits 0 on the #1722 symlink
 * refusal, so the caller needs this as a status and not just a printed line. */
static int wired(void)
{
	char *hooks_blob = canon(obj_get(load_lax(settings_path), "hooks"));
	char *mcp_blob = canon(obj_get(load_lax(claude_json_path), "mcpServers"));
	int in_hooks = strstr(hooks_blob, cbm) != NULL || strstr(hooks_blob, "cbm-") != NULL;
	int in_mcp = strstr(mcp_blob, cbm) != NULL;
	printf("CBM      hooks: %s, user-scope MCP entry: %s\n",
	       in_hooks ? "present" : "absent", in_mcp ? "present" : "absent");
	return (in_hooks && in_mcp) ? 0 : 4;
}

static int usage(void)
{
	fprintf(stderr,
	        "usage: radin-cbm-json restore <settings> <snap_settings> "
	        "<claude_json> <snap_claude_json> <cbm>\n"
	        "       radin-cbm-json adopt-mcp <staged_claude_json> <claude_json>\n"
	        "       radin-cbm-json wired <settings> <claude_json> <cbm>\n");
	return 1;
}

int main(int argc, char **argv)
{
	if (argc < 2)
		return usage();
	if (!strcmp(argv[1], "restore") && argc == 7) {
		settings_path = argv[2];
		claude_json_path = argv[4];
		cbm = argv[6];
		restore_settings(argv[3]);
		restore_mcp_servers(argv[5]);
		return 0;
	}
	if (!strcmp(argv[1], "adopt-mcp") && argc == 4) {
		claude_json_path = argv[3];
		adopt_mcp(argv[2]);
		return 0;
	}
	if (!strcmp(argv[1], "wired") && argc == 5) {
		settings_path = argv[2];
		claude_json_path = argv[3];
		cbm = argv[4];
		return wired();
	}
	return usage();
}
