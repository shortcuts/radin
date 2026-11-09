const SAFE: &str = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_@%+=:,./-";

fn blank(c: char) -> bool {
    c == ' ' || c == '\t' || c == '\n'
}

pub fn split(s: &str) -> Option<Vec<String>> {
    let mut words = Vec::new();
    let mut it = s.chars().peekable();
    while it.peek().is_some() {
        while it.next_if(|&c| blank(c)).is_some() {}
        if it.peek().is_none() {
            break;
        }
        let mut w = String::new();
        while let Some(&c) = it.peek() {
            if blank(c) {
                break;
            }
            it.next();
            match c {
                '\'' => loop {
                    match it.next()? {
                        '\'' => break,
                        c => w.push(c),
                    }
                },
                '"' => loop {
                    match it.next()? {
                        '"' => break,
                        '\\' => w.push(it.next()?),
                        c => w.push(c),
                    }
                },
                '\\' => w.push(it.next()?),
                c => w.push(c),
            }
        }
        words.push(w);
    }
    Some(words)
}

pub fn quote(w: &str) -> String {
    if w.is_empty() {
        "''".into()
    } else if w.chars().all(|c| SAFE.contains(c)) {
        w.into()
    } else {
        format!("'{}'", w.replace('\'', "'\"'\"'"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn s(w: &[&str]) -> Option<Vec<String>> {
        Some(w.iter().map(|x| x.to_string()).collect())
    }

    #[test]
    fn splits_on_blanks_and_honours_quotes() {
        assert_eq!(split("  a\tb\nc "), s(&["a", "b", "c"]));
        assert_eq!(split("'a b' c"), s(&["a b", "c"]));
        assert_eq!(split(r#""a \" b"x"#), s(&["a \" bx"]));
        assert_eq!(split(r"a\ b"), s(&["a b"]));
        assert_eq!(split(r#""a\n""#), s(&["an"]));
        assert_eq!(split(""), s(&[]));
        assert_eq!(split("''"), s(&[""]));
    }

    #[test]
    fn unterminated_quote_or_trailing_backslash_is_none() {
        assert_eq!(split("'abc"), None);
        assert_eq!(split("\"abc"), None);
        assert_eq!(split("abc\\"), None);
    }

    #[test]
    fn quotes_like_shlex() {
        assert_eq!(quote(""), "''");
        assert_eq!(quote("/a/b-c_d.e:f,g@h%i+j=k"), "/a/b-c_d.e:f,g@h%i+j=k");
        assert_eq!(quote("a b"), "'a b'");
        assert_eq!(quote("it's"), "'it'\"'\"'s'");
    }
}
