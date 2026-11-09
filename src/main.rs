use std::io::IsTerminal;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let (code, out, err) = radin::run(
        &args,
        &|k| std::env::var(k).ok(),
        std::io::stdout().is_terminal(),
    );
    print!("{out}");
    eprint!("{err}");
    std::process::exit(code);
}
