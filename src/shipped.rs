const SHIPPED: &str = include_str!("../SHIPPED");

#[derive(Default)]
pub struct Shipped {
    pub skills: Vec<&'static str>,
    pub lib: Vec<&'static str>,
    pub hostlib: Vec<&'static str>,
    pub renamed_skills: Vec<&'static str>,
    pub retired_skills: Vec<&'static str>,
    pub retired_lib: Vec<&'static str>,
}

pub fn shipped() -> Shipped {
    let mut s = Shipped::default();
    for line in SHIPPED.lines().filter(|l| !l.starts_with('#')) {
        let f: Vec<&'static str> = line.split_whitespace().collect();
        match f[..] {
            ["skill", n] => s.skills.push(n),
            ["lib", n] => s.lib.push(n),
            ["hostlib", n] => s.hostlib.push(n),
            ["renamed", "skill", n] => s.renamed_skills.push(n),
            ["retired", "skill", n] => s.retired_skills.push(n),
            ["retired", "lib", n] => s.retired_lib.push(n),
            _ => {}
        }
    }
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lists_come_from_the_shipped_file() {
        let s = shipped();
        assert!(s.skills.contains(&"radin-batch"));
        assert!(s.hostlib.contains(&"radin-run.md"));
        assert!(s.renamed_skills.contains(&"radin-execute"));
        assert!(s.retired_skills.contains(&"radin-show"));
        assert!(!s.lib.contains(&"radin-execute-gate.md"));
    }
}
