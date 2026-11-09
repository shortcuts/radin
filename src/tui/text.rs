use unicode_width::{UnicodeWidthChar, UnicodeWidthStr};

pub fn dwidth(s: &str) -> usize {
    s.width()
}

/// A tab or control byte prints as one space, so no cell ever holds a byte that moves the cursor.
pub fn clean(s: &str) -> String {
    s.chars()
        .map(|c| if c.is_control() { ' ' } else { c })
        .collect()
}

/// Byte offset where a line of at most `width` columns ends: the last space before the cut, else mid-word.
pub fn wrap_at(text: &str, width: usize) -> usize {
    let (mut col, mut last_sp) = (0, None);
    for (off, c) in text.char_indices() {
        let cw = c.width().unwrap_or(0);
        if col + cw > width {
            return match last_sp {
                Some(sp) if sp > 0 => sp,
                _ if off > 0 => off,
                _ => c.len_utf8(),
            };
        }
        if c == ' ' {
            last_sp = Some(off);
        }
        col += cw;
    }
    text.len()
}

/// Truncates to `width` display columns without splitting a wide glyph.
pub fn fit(text: &str, width: usize) -> &str {
    let mut col = 0;
    for (off, c) in text.char_indices() {
        let cw = c.width().unwrap_or(0);
        if col + cw > width {
            return &text[..off];
        }
        col += cw;
    }
    text
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum MdStyle {
    Plain,
    Bold,
    Dim,
}

/// One markdown source line as `(text, style, wrap indent)`; stateless, so a `#` inside a fence still renders bold.
pub fn md_line(src: &str) -> (String, MdStyle, usize) {
    let p = src.trim_start_matches(' ');
    let lead = src.len() - p.len();
    let hashes = p.chars().take_while(|&c| c == '#').count();
    let after = &p[hashes..];
    let (text, style, indent) = if p.is_empty() {
        (String::new(), MdStyle::Plain, 0)
    } else if (1..=6).contains(&hashes) && (after.is_empty() || after.starts_with(' ')) {
        (after.trim_start_matches(' ').to_string(), MdStyle::Bold, 0)
    } else if p.starts_with('>') {
        let mut rest = p;
        let mut lvl = 0;
        while let Some(r) = rest.strip_prefix('>') {
            rest = r.strip_prefix(' ').unwrap_or(r);
            lvl += 1;
        }
        (
            format!("{}{rest}", " ".repeat(lvl * 2)),
            MdStyle::Dim,
            lvl * 2,
        )
    } else if let Some(item) = ["- ", "* ", "+ "].iter().find_map(|m| p.strip_prefix(m)) {
        (
            format!("{}  \u{2022} {item}", " ".repeat(lead)),
            MdStyle::Plain,
            lead + 4,
        )
    } else {
        (src.to_string(), MdStyle::Plain, 0)
    };
    (text.replace("**", ""), style, indent)
}

fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let doy = (153 * (m + if m > 2 { -3 } else { 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146097 + doe - 719468
}

/// Task age as a short cell ("5d", "3w", "8mo", "2y"); empty when the stamp is missing or unparsable.
pub fn age_cell(iso: &str, now: i64) -> String {
    let Some(epoch) = parse_iso(iso) else {
        return String::new();
    };
    let d = ((now - epoch) / 86400).max(0);
    match d {
        0..=13 => format!("{d}d"),
        14..=59 => format!("{}w", d / 7),
        60..=364 => format!("{}mo", d / 30),
        _ => format!("{}y", d / 365),
    }
}

fn parse_iso(s: &str) -> Option<i64> {
    let s = s.strip_suffix('Z')?;
    let (date, time) = s.split_once('T')?;
    let mut d = date.splitn(3, '-');
    let mut t = time.splitn(3, ':');
    let n = |it: &mut std::str::SplitN<char>| it.next()?.parse::<i64>().ok();
    let (y, mo, da) = (n(&mut d)?, n(&mut d)?, n(&mut d)?);
    let (h, mi, se) = (n(&mut t)?, n(&mut t)?, n(&mut t)?);
    Some(days_from_civil(y, mo, da) * 86400 + h * 3600 + mi * 60 + se)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wrap_keeps_the_last_space_before_the_cut() {
        assert_eq!(wrap_at("aaa bbb", 5), 3);
        assert_eq!(wrap_at("aaa bbb", 7), 7);
    }

    #[test]
    fn wrap_cuts_one_long_word_mid_word() {
        assert_eq!(wrap_at("abcdefgh", 3), 3);
        assert_eq!(wrap_at("\u{3042}\u{3042}", 1), 3);
    }

    #[test]
    fn fit_never_splits_a_wide_glyph() {
        assert_eq!(fit("\u{3042}\u{3042}\u{3042}", 5), "\u{3042}\u{3042}");
        assert_eq!(dwidth(fit("\u{3042}\u{3042}\u{3042}", 5)), 4);
    }

    #[test]
    fn clean_turns_tab_and_control_into_a_space() {
        assert_eq!(clean("X\tY\u{1}Z"), "X Y Z");
    }

    #[test]
    fn md_heading_is_bold_without_hashes() {
        assert_eq!(md_line("## Title"), ("Title".to_string(), MdStyle::Bold, 0));
        assert_eq!(md_line("#nospace").1, MdStyle::Plain);
        assert_eq!(md_line("####### seven").1, MdStyle::Plain);
    }

    #[test]
    fn md_quote_levels_indent_two_each() {
        assert_eq!(
            md_line(">> deep"),
            ("    deep".to_string(), MdStyle::Dim, 4)
        );
    }

    #[test]
    fn md_bullet_gets_a_dot_and_hanging_indent() {
        assert_eq!(
            md_line("  - item"),
            ("    \u{2022} item".to_string(), MdStyle::Plain, 6)
        );
    }

    #[test]
    fn md_strips_every_double_star() {
        assert_eq!(md_line("**bold** text").0, "bold text");
    }

    #[test]
    fn age_buckets() {
        let now = days_from_civil(2026, 1, 1) * 86400;
        let at = |d: i64| {
            let t = now - d * 86400;
            let (y, m, dd) = civil(t / 86400);
            format!("{y:04}-{m:02}-{dd:02}T00:00:00Z")
        };
        assert_eq!(age_cell(&at(5), now), "5d");
        assert_eq!(age_cell(&at(14), now), "2w");
        assert_eq!(age_cell(&at(60), now), "2mo");
        assert_eq!(age_cell(&at(400), now), "1y");
        assert_eq!(age_cell("", now), "");
        assert_eq!(age_cell("not a date", now), "");
        assert_eq!(age_cell("2030-01-01T00:00:00Z", now), "0d");
    }

    fn civil(z: i64) -> (i64, i64, i64) {
        let z = z + 719468;
        let era = z.div_euclid(146097);
        let doe = z - era * 146097;
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        let mp = (5 * doy + 2) / 153;
        let d = doy - (153 * mp + 2) / 5 + 1;
        let m = if mp < 10 { mp + 3 } else { mp - 9 };
        (yoe + era * 400 + i64::from(m <= 2), m, d)
    }
}
