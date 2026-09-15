# Measures radin tui's startup and per-keypress redraw on a real pty, the same
# way tests/helpers/pty-run.py drives it for the bats suite.
#
# argv: <cwd> <tui-path> [iterations]
#
# The frame sentinel is the cursor move bar() emits as the last write of every
# frame ("\x1b[<ROWS>;1H"). Footer text is not usable: bar truncates it to
# $COLS, so a narrow terminal drops the tail.
import fcntl
import os
import pty
import select
import statistics
import struct
import sys
import termios
import time

ROWS, COLS = 40, 120
cwd, tui = sys.argv[1:3]
iterations = int(sys.argv[3]) if len(sys.argv) > 3 else 20

SENTINEL = ("\x1b[%d;1H" % ROWS).encode()

os.chdir(cwd)
spawned = time.time()
pid, fd = pty.fork()
if pid == 0:
    os.execvp("bash", ["bash", tui])

fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))

buf = b""


def wait_frame(began=None, timeout=20.0):
    """Block until the next frame sentinel lands; return elapsed seconds."""
    global buf
    buf = b""
    began = time.time() if began is None else began
    deadline = began + timeout
    while time.time() < deadline:
        if select.select([fd], [], [], 0.05)[0]:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            buf += chunk
            if SENTINEL in buf:
                return time.time() - began
    raise SystemExit("bench-tui: no frame within %.0fs" % timeout)


startup = wait_frame(spawned)
print("startup_ms %.1f" % (startup * 1000), flush=True)

samples = []
for n in range(iterations):
    os.write(fd, b"j" if n % 2 == 0 else b"k")
    samples.append(wait_frame() * 1000)
    print("redraw_ms %.1f" % samples[-1], flush=True)

print(
    "redraw_median_ms %.1f  n=%d  min=%.1f  max=%.1f"
    % (statistics.median(samples), len(samples), min(samples), max(samples)),
    flush=True,
)

# Bounded, non-blocking teardown: a harness that blocks waiting on the child
# reads as a hang, and the numbers above are already printed.
try:
    os.kill(pid, 9)
    for _ in range(20):
        if os.waitpid(pid, os.WNOHANG)[0]:
            break
        time.sleep(0.05)
except OSError:
    pass
os._exit(0)
