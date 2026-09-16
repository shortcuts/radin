/* One binary standing in for every command install.sh reaches for, so the
 * suite runs offline and never touches the real ~/.claude.
 *
 * Compiled, not a shell script per command: macOS spends ~20ms starting
 * /bin/sh, and one install run calls these ~25 times -- 0.5s of the 0.8s a
 * stubbed install used to cost, times a dozen live runs.
 *
 * Behaviour is chosen by the name it is called as (hardlinked under each
 * command name) and by the environment:
 *   MOCK_BIN        directory the links live in; where "installed" tools appear
 *   MOCK_LOG_DIR    append "<args>" to <dir>/<name>.log on every call
 *   MOCK_FAIL       space-separated names that exit 1
 *   MOCK_NPX        "fail" exits 1, "eat-stdin" reads fd 0 to EOF
 *   MOCK_CBM        "fail-install" prints an editor inventory and exits 1 for `install`
 *   MOCK_PLUGINS    what `claude plugin list` prints
 *
 * cc -O1 -o mock mock.c
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <sys/types.h>

static const char *me;

static int named(const char *n) { return !strcmp(me, n); }

static int in_env_list(const char *var, const char *word) {
	const char *v = getenv(var);
	if (!v) return 0;
	size_t n = strlen(word);
	for (const char *p = v; *p;) {
		while (*p == ' ') p++;
		if (!strncmp(p, word, n) && (p[n] == ' ' || p[n] == 0)) return 1;
		while (*p && *p != ' ') p++;
	}
	return 0;
}

static void log_call(int argc, char **argv) {
	const char *dir = getenv("MOCK_LOG_DIR");
	if (!dir) return;
	char path[4096];
	snprintf(path, sizeof path, "%s/%s.log", dir, me);
	FILE *f = fopen(path, "a");
	if (!f) return;
	for (int i = 1; i < argc; i++) fprintf(f, "%s%s", argv[i], i + 1 < argc ? " " : "\n");
	if (argc == 1) fprintf(f, "\n");
	fclose(f);
}

/* Mirrors what a real install leaves behind: a binary on PATH, so install.sh's
 * own `command -v` reachability checks see the install take effect. */
static void install_tool(const char *name) {
	const char *bin = getenv("MOCK_BIN");
	if (!bin) return;
	char self[4096], dst[4096];
	snprintf(self, sizeof self, "%s/mock", bin);
	snprintf(dst, sizeof dst, "%s/%s", bin, name);
	if (link(self, dst) != 0) symlink(self, dst);
}

static int has_arg(int argc, char **argv, const char *want) {
	for (int i = 1; i < argc; i++)
		if (!strcmp(argv[i], want)) return 1;
	return 0;
}

static int has_substr(int argc, char **argv, const char *want) {
	for (int i = 1; i < argc; i++)
		if (strstr(argv[i], want)) return 1;
	return 0;
}

int main(int argc, char **argv) {
	me = strrchr(argv[0], '/');
	me = me ? me + 1 : argv[0];
	log_call(argc, argv);
	if (in_env_list("MOCK_FAIL", me)) return 1;

	if (named("brew")) {
		if (argc > 2 && !strcmp(argv[1], "install") && !strcmp(argv[2], "rtk"))
			install_tool("rtk");
		return 0;
	}
	if (named("pipx") || named("pip3")) {
		if (has_substr(argc, argv, "headroom-ai")) install_tool("headroom");
		return 0;
	}
	if (named("curl")) {
		/* -o file: write a byte so downstream existence checks pass. No -o:
		 * print nothing, matching an empty GitHub API response. */
		for (int i = 1; i + 1 < argc; i++) {
			if (strcmp(argv[i], "-o")) continue;
			FILE *f = fopen(argv[i + 1], "w");
			if (f) {
				fprintf(f, "mock\n");
				fclose(f);
			}
		}
		return 0;
	}
	if (named("cc") || named("gcc") || named("clang")) {
		/* Writes an executable at -o so install.sh's TUI build "succeeds": the
		 * one run that compiles it for real is the recorded end-to-end install,
		 * which gets no cc link. */
		for (int i = 1; i + 1 < argc; i++) {
			if (strcmp(argv[i], "-o")) continue;
			FILE *f = fopen(argv[i + 1], "w");
			if (f) {
				fprintf(f, "#!/bin/sh\nexit 0\n");
				fclose(f);
				chmod(argv[i + 1], 0755);
			}
		}
		return 0;
	}
	if (named("claude")) {
		if (argc > 2 && !strcmp(argv[1], "plugin") && !strcmp(argv[2], "list")) {
			const char *p = getenv("MOCK_PLUGINS");
			if (p && *p) printf("%s\n", p);
		}
		return 0;
	}
	if (named("npx")) {
		const char *mode = getenv("MOCK_NPX");
		if (mode && !strcmp(mode, "fail")) return 1;
		if (mode && !strcmp(mode, "eat-stdin")) {
			char buf[4096];
			while (read(0, buf, sizeof buf) > 0) continue;
		}
		/* A successful `skills add`: drops the source folder install.sh then
		 * renames. Without it the real npx would reach the network. */
		const char *home = getenv("HOME");
		if (home && has_arg(argc, argv, "add")) {
			char dir[4096], file[4096];
			snprintf(dir, sizeof dir, "%s/.claude/skills", home);
			mkdir(dir, 0755);
			snprintf(dir, sizeof dir, "%s/.claude/skills/thermo-nuclear-code-quality-review",
				home);
			mkdir(dir, 0755);
			snprintf(file, sizeof file, "%s/SKILL.md", dir);
			FILE *f = fopen(file, "w");
			if (f) {
				fprintf(f, "stub thermo-nuclear\n");
				fclose(f);
			}
		}
		return 0;
	}
	if (named("codebase-memory-mcp")) {
		const char *mode = getenv("MOCK_CBM");
		if (mode && !strcmp(mode, "fail-install") && has_arg(argc, argv, "install")) {
			/* Upstream's own per-client inventory: the block install.sh used to
			 * relay to the terminal on a PARTIAL run. */
			printf("Claude Code:\n  hooks: SessionStart (MCP usage reminder on startup)\n");
			printf("OpenCode:\n  mcp: /dev/null/opencode.json\n");
			return 1;
		}
		return 0;
	}
	return 0;
}
