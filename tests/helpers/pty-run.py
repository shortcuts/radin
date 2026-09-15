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


def pump(seconds):
    global screen
    deadline = time.time() + seconds
    while time.time() < deadline:
        if select.select([fd], [], [], 0.05)[0]:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                return False
            if not chunk:
                return False
            screen += chunk
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
