use std::io::{IsTerminal, Read};

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut stdin: Option<String> = None;
    let stdin_verbs = ["scope", "state", "install", "update"];
    if args
        .iter()
        .find(|a| !a.starts_with('-') && !["claude", "agents"].contains(&a.as_str()))
        .is_some_and(|a| stdin_verbs.contains(&a.as_str()))
        && !args
            .iter()
            .any(|a| ["--yes", "--update", "--list"].contains(&a.as_str()))
        && !std::io::stdin().is_terminal()
        && !stdin_is_socket()
    {
        let mut b = Vec::new();
        let _ = std::io::stdin().read_to_end(&mut b);
        stdin = Some(String::from_utf8_lossy(&b).into_owned());
    }
    let (code, out, err) = radin::run_in(
        &args,
        &|k| std::env::var(k).ok(),
        std::io::stdout().is_terminal(),
        &std::env::current_dir().unwrap_or_default(),
        stdin.as_deref(),
    );
    print!("{out}");
    eprint!("{err}");
    std::process::exit(code);
}

// An agent's shell passes an open socket on stdin that never reaches EOF.
fn stdin_is_socket() -> bool {
    use std::os::fd::AsFd;
    use std::os::unix::fs::FileTypeExt;
    std::io::stdin()
        .as_fd()
        .try_clone_to_owned()
        .map(std::fs::File::from)
        .and_then(|f| f.metadata())
        .is_ok_and(|m| m.file_type().is_socket())
}
