# Runs a command on a real pty and sends it keystrokes, so the TUI -- which
# refuses to draw on anything that isn't a terminal -- can be tested.
# argv: <outfile> <keys separated by |> <cmd> [args...]
# Each key chunk is written after the previous frame had time to render;
# escape sequences may be spelled with Python escapes ("\r", "\x1b[B").
import fcntl
import os
import pty
import select
import struct
import sys
import termios
import time

outfile, keys = sys.argv[1:3]
cmd = sys.argv[3:]

pid, fd = pty.fork()
if pid == 0:
    os.execvp(cmd[0], cmd)

# A forked pty has no window size, and the TUI would fall back to its 40x10
# minimum -- narrower and shorter than any real terminal.
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))

screen = b""


# A redraw takes ~4ms, so waiting out the whole deadline on every key cost the
# suite ~0.6s per keystroke. Return once the pty has gone quiet instead, and
# only start that clock after the first byte -- before it, the frame we are
# waiting for has not been drawn yet.
def pump(seconds, quiet=0.02):
    global screen
    deadline = time.time() + seconds
    idle_since = None
    got_any = False
    while time.time() < deadline:
        if select.select([fd], [], [], 0.01)[0]:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                return False
            if not chunk:
                return False
            screen += chunk
            got_any = True
            idle_since = None
        elif got_any:
            if idle_since is None:
                idle_since = time.time()
            elif time.time() - idle_since >= quiet:
                return True
    return True


pump(0.6)
for chunk in keys.split("|") if keys else []:
    os.write(fd, chunk.encode().decode("unicode_escape").encode("latin1"))
    if not pump(0.6):
        break

deadline = time.time() + 10
status = None
while time.time() < deadline:
    pump(0.1)
    wpid, st = os.waitpid(pid, os.WNOHANG)
    if wpid:
        status = st
        break
if status is None:
    os.kill(pid, 9)
    status = os.waitpid(pid, 0)[1]

with open(outfile, "wb") as fh:
    fh.write(screen)
sys.exit(os.waitstatus_to_exitcode(status))
