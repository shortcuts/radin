/* Drives a command on a real pty and feeds it keystrokes, so the TUI and
 * install.sh's picker -- both of which refuse to draw on anything that isn't a
 * terminal -- can be tested.
 *
 * argv: <outfile> <keys separated by |> <cmd> [args...]
 *
 * C, not python: python3 costs ~250ms of interpreter startup per call on a
 * mise/pyenv box, which dominated the suite at ~50 pty runs.
 *
 * No _XOPEN_SOURCE: on macOS it selects the UNIX03 termios/ioctl ABI, and the
 * keystrokes we write then reach the child's tty mangled under load.
 *
 * cc -O1 -o pty-run pty-run.c   (util is in libc on macOS and glibc alike)
 */
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

#ifdef __APPLE__
#include <util.h>
#else
#include <pty.h>
#endif

static int fd;
static char *screen;
static size_t screen_len, screen_cap;

static double now(void) {
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

static void collect(const char *buf, ssize_t n) {
	if (screen_len + n + 1 > screen_cap) {
		screen_cap = (screen_len + n + 1) * 2;
		screen = realloc(screen, screen_cap);
		if (!screen) exit(70);
	}
	memcpy(screen + screen_len, buf, n);
	screen_len += n;
}

/* Reads until the pty has been quiet for `quiet` seconds, or `seconds` elapse.
 * The quiet clock only starts after the first byte: before it, the frame we are
 * waiting for has not been drawn yet. Returns 0 once the child's side closes. */
static int pump(double seconds, double quiet) {
	double deadline = now() + seconds, idle_since = -1;
	int got_any = 0;
	char buf[65536];

	for (;;) {
		double left = deadline - now();
		if (left <= 0) return 1;
		struct pollfd p = {fd, POLLIN, 0};
		int ms = (int)(left * 1000);
		if (ms > 10) ms = 10;
		if (ms < 1) ms = 1;
		int r = poll(&p, 1, ms);
		if (r > 0) {
			ssize_t n = read(fd, buf, sizeof buf);
			if (n <= 0) return 0;
			collect(buf, n);
			got_any = 1;
			idle_since = -1;
		} else if (got_any) {
			if (idle_since < 0)
				idle_since = now();
			else if (now() - idle_since >= quiet)
				return 1;
		}
	}
}

/* Decodes the python-style escapes the tests spell their keys with: \r, \t,
 * \e, \xHH and octal \NNN. */
static size_t unescape(const char *in, size_t len, char *out) {
	size_t o = 0;
	for (size_t i = 0; i < len; i++) {
		if (in[i] != '\\' || i + 1 >= len) {
			out[o++] = in[i];
			continue;
		}
		char c = in[++i];
		switch (c) {
		case 'n': out[o++] = '\n'; break;
		case 'r': out[o++] = '\r'; break;
		case 't': out[o++] = '\t'; break;
		case 'a': out[o++] = '\a'; break;
		case 'b': out[o++] = '\b'; break;
		case 'f': out[o++] = '\f'; break;
		case 'v': out[o++] = '\v'; break;
		case 'e': out[o++] = 033; break;
		case '\\': out[o++] = '\\'; break;
		case 'x': {
			int v = 0, d = 0;
			while (d < 2 && i + 1 < len && isxdigit((unsigned char)in[i + 1])) {
				char h = in[++i];
				v = v * 16 + (h <= '9' ? h - '0' : (h | 32) - 'a' + 10);
				d++;
			}
			out[o++] = (char)v;
			break;
		}
		default:
			if (c >= '0' && c <= '7') {
				int v = c - '0', d = 1;
				while (d < 3 && i + 1 < len && in[i + 1] >= '0' && in[i + 1] <= '7') {
					v = v * 8 + (in[++i] - '0');
					d++;
				}
				out[o++] = (char)v;
			} else {
				out[o++] = c;
			}
		}
	}
	return o;
}

int main(int argc, char **argv) {
	if (argc < 4) {
		fprintf(stderr, "usage: pty-run <outfile> <keys> <cmd> [args...]\n");
		return 64;
	}
	const char *outfile = argv[1], *keys = argv[2];

	pid_t pid = forkpty(&fd, NULL, NULL, NULL);
	if (pid < 0) return 70;
	if (pid == 0) {
		execvp(argv[3], argv + 3);
		_exit(127);
	}

	/* A forked pty has no window size, and the TUI would fall back to its 40x10
	 * minimum -- narrower and shorter than any real terminal. */
	struct winsize ws = {24, 80, 0, 0};
	ioctl(fd, TIOCSWINSZ, &ws);

	/* Put the pty in character mode before the child can read: keys written
	 * while the line discipline is still canonical are either swallowed (\003
	 * becomes a SIGINT the app never sees) or held back until a newline, and
	 * the app then hangs on a key that never arrives. A pty shares its termios
	 * with the master side, so do it from here. OPOST stays on -- the recorded
	 * screen keeps the CRLFs a real terminal would show. */
	struct termios tio;
	if (tcgetattr(fd, &tio) == 0) {
		tio.c_lflag &= ~(ICANON | ISIG | ECHO);
		tio.c_cc[VMIN] = 1;
		tio.c_cc[VTIME] = 0;
		tcsetattr(fd, TCSANOW, &tio);
	}

	int alive = 1;
	char *chunk = malloc(strlen(keys) + 1);
	if (!chunk) return 70;
	const char *p = keys;
	while (alive && *p) {
		const char *bar = strchr(p, '|');
		size_t len = bar ? (size_t)(bar - p) : strlen(p);
		size_t n = unescape(p, len, chunk);
		/* Every key these two programs take redraws, so silence means the
		 * keystroke was dropped between raw mode and the app's first read --
		 * resend it rather than wait out the 10s deadline on a hung child. */
		for (int try = 0; try < 4; try++) {
			size_t before = screen_len;
			if (n && write(fd, chunk, n) < 0) { alive = 0; break; }
			alive = pump(1.5, 0.02);
			if (!alive || screen_len != before) break;
		}
		if (!bar) break;
		p = bar + 1;
	}

	int status = 0;
	if (alive && pump(10.0, 10.0)) kill(pid, SIGKILL);
	if (waitpid(pid, &status, 0) != pid) return 70;

	FILE *fh = fopen(outfile, "wb");
	if (!fh) return 70;
	if (screen_len) fwrite(screen, 1, screen_len, fh);
	fclose(fh);

	if (WIFEXITED(status)) return WEXITSTATUS(status);
	if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
	return 1;
}
