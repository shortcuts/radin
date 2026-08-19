# Runs a bash snippet on a real pty, so install.sh's raw-mode arrow-key picker
# can be tested -- it refuses to draw on anything that isn't a terminal.
# argv: <snippet.sh> <outfile> <keys> <default-index> <option>...
import os
import pty
import select
import sys
import time

snippet, outfile, keys, default = sys.argv[1:5]
opts = " ".join('"%s"' % o for o in sys.argv[5:])
cmd = (
    'YES=""; RAT=""; BOLD=""; DIM=""; CYAN=""; YELLOW=""; RED=""; RESET=""; '
    "source %s; prompt_pick 'pick one' %s %s > %s" % (snippet, default, opts, outfile)
)

pid, fd = pty.fork()
if pid == 0:
    os.execvp("bash", ["bash", "-c", cmd])

time.sleep(0.4)  # let the first frame render before the keys land
os.write(fd, keys.encode().decode("unicode_escape").encode("latin1"))

deadline = time.time() + 10
while time.time() < deadline:
    if select.select([fd], [], [], 0.1)[0]:
        try:
            if not os.read(fd, 4096):
                break
        except OSError:
            break
    if os.waitpid(pid, os.WNOHANG)[0]:
        sys.exit(0)
else:
    os.kill(pid, 9)
    sys.exit(1)

sys.exit(os.waitstatus_to_exitcode(os.waitpid(pid, 0)[1]))
