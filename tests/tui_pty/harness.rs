use portable_pty::{native_pty_system, Child, CommandBuilder, MasterPty, PtySize};
use std::io::{Read, Write};
use std::num::NonZeroU16;
use std::path::Path;
use std::sync::mpsc::{self, Receiver};
use std::time::{Duration, Instant};

pub struct Term {
    child: Box<dyn Child + Send + Sync>,
    _master: Box<dyn MasterPty + Send>,
    writer: Box<dyn Write + Send>,
    rx: Receiver<Vec<u8>>,
    parser: vt100::Parser,
    raw: Vec<u8>,
    cols: u16,
}

impl Term {
    /// Spawns radin in `proj` with an isolated HOME; `env` adds or, with an empty value, removes variables.
    pub fn spawn(proj: &Path, size: (u16, u16), env: &[(&str, &str)]) -> Term {
        let (cols, rows) = size;
        let pair = native_pty_system()
            .openpty(PtySize {
                rows,
                cols,
                pixel_width: 0,
                pixel_height: 0,
            })
            .unwrap();
        let home = proj.parent().unwrap().join("home");
        let mut cmd = CommandBuilder::new(env!("CARGO_BIN_EXE_radin"));
        cmd.cwd(proj);
        cmd.env("HOME", &home);
        cmd.env("XDG_CONFIG_HOME", home.join(".config"));
        cmd.env("CODEX_HOME", home.join(".codex"));
        cmd.env("TERM", "xterm");
        for v in [
            "COLORTERM",
            "NO_COLOR",
            "CLAUDE_CONFIG_DIR",
            "OPENCODE_CONFIG",
            "OPENCODE",
            "EDITOR",
            "PAGER",
        ] {
            cmd.env_remove(v);
        }
        for (k, v) in env {
            if v.is_empty() {
                cmd.env_remove(k);
            } else {
                cmd.env(k, v);
            }
        }
        let child = pair.slave.spawn_command(cmd).unwrap();
        let mut reader = pair.master.try_clone_reader().unwrap();
        let writer = pair.master.take_writer().unwrap();
        let (tx, rx) = mpsc::channel();
        std::thread::spawn(move || {
            let mut buf = [0u8; 8192];
            while let Ok(n @ 1..) = reader.read(&mut buf) {
                if tx.send(buf[..n].to_vec()).is_err() {
                    break;
                }
            }
        });
        Term {
            child,
            _master: pair.master,
            writer,
            rx,
            parser: vt100::Parser::new(
                NonZeroU16::new(rows).unwrap(),
                NonZeroU16::new(cols).unwrap(),
                0,
            ),
            raw: Vec::new(),
            cols,
        }
    }

    /// Runs `sh -c script` in `proj` on a pty, for cases the app itself must reject.
    pub fn spawn_cmd(proj: &Path, script: &str) -> Term {
        let mut t = Term::spawn(proj, (80, 24), &[]);
        let _ = t.child.kill();
        let pair = native_pty_system()
            .openpty(PtySize {
                rows: 24,
                cols: 80,
                pixel_width: 0,
                pixel_height: 0,
            })
            .unwrap();
        let mut cmd = CommandBuilder::new("sh");
        cmd.args(["-c", script]);
        cmd.cwd(proj);
        cmd.env("TERM", "xterm");
        t.child = pair.slave.spawn_command(cmd).unwrap();
        let mut reader = pair.master.try_clone_reader().unwrap();
        t.writer = pair.master.take_writer().unwrap();
        t._master = pair.master;
        let (tx, rx) = mpsc::channel();
        std::thread::spawn(move || {
            let mut buf = [0u8; 8192];
            while let Ok(n @ 1..) = reader.read(&mut buf) {
                if tx.send(buf[..n].to_vec()).is_err() {
                    break;
                }
            }
        });
        t.rx = rx;
        t
    }

    fn pump(&mut self) -> bool {
        let mut any = false;
        while let Ok(chunk) = self.rx.try_recv() {
            self.raw.extend_from_slice(&chunk);
            self.parser.process(&chunk);
            any = true;
        }
        any
    }

    /// One `write`, so a key string reaches the app in one read.
    pub fn send(&mut self, bytes: &str) {
        self.writer.write_all(bytes.as_bytes()).unwrap();
        self.writer.flush().unwrap();
    }

    /// Sends keys, then waits until the screen stops changing.
    pub fn keys(&mut self, bytes: &str) {
        self.send(bytes);
        self.quiet();
    }

    pub fn quiet(&mut self) {
        let mut last = Instant::now();
        let start = last;
        while last.elapsed() < Duration::from_millis(300)
            && start.elapsed() < Duration::from_secs(10)
        {
            std::thread::sleep(Duration::from_millis(10));
            if self.pump() {
                last = Instant::now();
            }
        }
    }

    pub fn wait_for(&mut self, text: &str) {
        let end = Instant::now() + Duration::from_secs(10);
        while !self.screen().contains(text) {
            assert!(
                Instant::now() < end,
                "timed out waiting for {text:?}\n{}",
                self.screen()
            );
            std::thread::sleep(Duration::from_millis(10));
            self.pump();
        }
    }

    pub fn screen(&mut self) -> String {
        self.pump();
        let mut rows: Vec<String> = self
            .parser
            .screen()
            .rows(0, self.cols)
            .map(|r| r.trim_end().to_string())
            .collect();
        while rows.last().is_some_and(String::is_empty) {
            rows.pop();
        }
        rows.join("\n")
    }

    /// Every byte the app wrote so far, for text a pager prints on the normal screen.
    pub fn raw(&mut self) -> String {
        self.pump();
        String::from_utf8_lossy(&self.raw).into_owned()
    }

    /// Milliseconds from writing `bytes` to the end of the next synchronized frame.
    #[allow(dead_code)] // each test crate compiles the harness alone; only the bench calls this
    pub fn time_to_frame(&mut self, bytes: &str) -> f64 {
        self.pump();
        let mark = self.raw.len();
        let start = Instant::now();
        self.send(bytes);
        while !self.raw[mark..].windows(8).any(|w| w == b"\x1b[?2026l") {
            assert!(
                start.elapsed() < Duration::from_secs(10),
                "no frame after {bytes:?}"
            );
            if let Ok(chunk) = self.rx.recv_timeout(Duration::from_millis(1)) {
                self.raw.extend_from_slice(&chunk);
                self.parser.process(&chunk);
            }
        }
        start.elapsed().as_secs_f64() * 1000.0
    }

    pub fn cells(&mut self) -> Vec<vt100::Color> {
        self.pump();
        let (rows, cols) = self.parser.screen().size();
        let (rows, cols) = (rows.get(), cols.get());
        (0..rows)
            .flat_map(|r| (0..cols).map(move |c| (r, c)))
            .map(|(r, c)| self.parser.screen().cell(r, c).unwrap().fgcolor())
            .collect()
    }

    /// The exit code once the app ends.
    pub fn exit_code(&mut self) -> u32 {
        let end = Instant::now() + Duration::from_secs(10);
        loop {
            self.pump();
            if let Some(s) = self.child.try_wait().unwrap() {
                std::thread::sleep(Duration::from_millis(100));
                self.pump();
                return s.exit_code();
            }
            assert!(Instant::now() < end, "app did not exit\n{}", self.screen());
            std::thread::sleep(Duration::from_millis(10));
        }
    }
}

impl Drop for Term {
    fn drop(&mut self) {
        let _ = self.child.kill();
    }
}
