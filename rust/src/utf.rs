//! 跨实现逐字节一致的格式化小工具。
//!
//! 对齐 `python/stope/format.py` 与 C++ 的 `escUtf8`：凡是出现在 golden 数据里的
//! 字符串都必须用这里的函数生成。字符串在内部一律是 UTF-8 `str`（输出错误消息、
//! dump 时按码点遍历转义，非 ASCII 一律 `?`，与 golden 的探针一致）。

/// 与 C++ 的 `escUtf8` 一致：`\ " \n \r \t` 转义，非 ASCII 一律 `?`（按码点遍历）。
pub fn esc(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for ch in s.chars() {
        match ch {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 128 => out.push(c),
            _ => out.push('?'),
        }
    }
    out
}

/// 词法比对专用转义：比 [`esc`] 多 `\v \f`、不转义引号（`golden_lex.txt` 的
/// `TOKS` / `LEXEMES` / `ERRS` 用）。
pub fn esc_lex(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for ch in s.chars() {
        match ch {
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '\u{0b}' => out.push_str("\\v"),
            '\u{0c}' => out.push_str("\\f"),
            c if (c as u32) < 128 => out.push(c),
            _ => out.push('?'), // 非 ASCII 变 ?：对应 C++ 侧打印用的 toUtf8（只做打印映射）
        }
    }
    out
}

/// `E_()` 那一套：把 `\` 与 `"` 双写（`golden_stml.txt` 的 `ERRS` 用）。
pub fn esc_quote(s: &str) -> String {
    s.replace('\\', "\\\\").replace('"', "\\\"")
}

/// 二进制数组 → `01,0a,ff`（小写两位十六进制，逗号分隔）。
pub fn fmt_bytes(b: &[u8]) -> String {
    let mut out = String::with_capacity(b.len() * 3);
    for (i, x) in b.iter().enumerate() {
        if i > 0 {
            out.push(',');
        }
        out.push_str(&format!("{:02x}", x));
    }
    out
}

/// `printf("%g")` 的忠实实现（精度 6）。
///
/// C 的规则：按 `%e`（精度 5）舍入后的指数 X，`-4 <= X < 6` 走 `%f`（精度
/// `5 - X`），否则走 `%e`（精度 5）；再去掉尾零与多余小数点。`nan` / `inf` /
/// `-inf` 小写，`-0.0` 打成 `-0`。
pub fn fmt_g(v: f64) -> String {
    if v.is_nan() {
        // 与 C 的 printf 一致：符号位为 1 时输出 "-nan"
        return if v.is_sign_negative() { "-nan".into() } else { "nan".into() };
    }
    if v == f64::INFINITY {
        return "inf".into();
    }
    if v == f64::NEG_INFINITY {
        return "-inf".into();
    }
    if v == 0.0 {
        return if v.is_sign_negative() { "-0".into() } else { "0".into() };
    }
    const PREC: i32 = 6;
    // 用精度 5 的科学计数求「舍入后的指数」，与 C 选路用的 X 完全一致
    let sci = format!("{:.5e}", v.abs());
    let exp: i32 = sci[sci.find('e').unwrap() + 1..].parse().unwrap();
    if exp >= -4 && exp < PREC {
        let mut t = format!("{:.*}", (PREC - 1 - exp) as usize, v);
        strip_trailing_zeros(&mut t);
        t
    } else {
        let t = format!("{:.5e}", v);
        let epos = t.find('e').unwrap();
        let mut mant = t[..epos].to_string();
        strip_trailing_zeros(&mut mant);
        let expi: i32 = t[epos + 1..].parse().unwrap();
        let sign = if expi < 0 { '-' } else { '+' };
        format!("{}e{}{:02}", mant, sign, expi.abs())
    }
}

/// 去掉小数部分尾零；整数则连小数点一起去掉（保留正负号）。
fn strip_trailing_zeros(s: &mut String) {
    if s.contains('.') {
        while s.ends_with('0') {
            s.pop();
        }
        if s.ends_with('.') {
            s.pop();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fmt_g_matches_c() {
        assert_eq!(fmt_g(0.0), "0");
        assert_eq!(fmt_g(-0.0), "-0");
        assert_eq!(fmt_g(1.0), "1");
        assert_eq!(fmt_g(1.5), "1.5");
        assert_eq!(fmt_g(15.0), "15");
        assert_eq!(fmt_g(0.5), "0.5");
        assert_eq!(fmt_g(-1.0), "-1");
        assert_eq!(fmt_g(1e6), "1e+06");
        assert_eq!(fmt_g(999999.0), "999999");
        assert_eq!(fmt_g(1000000.0), "1e+06");
        assert_eq!(fmt_g(0.0001), "0.0001");
        assert_eq!(fmt_g(0.00001), "1e-05");
        assert_eq!(fmt_g(123456789.0), "1.23457e+08");
        assert_eq!(fmt_g(f64::NAN), "nan");
        assert_eq!(fmt_g(f64::INFINITY), "inf");
        assert_eq!(fmt_g(f64::NEG_INFINITY), "-inf");
        assert_eq!(fmt_g(3.5), "3.5");
        assert_eq!(fmt_g(-0.5), "-0.5");
        assert_eq!(fmt_g(2.0_f64.powi(64)), "1.84467e+19");
    }

    #[test]
    fn esc_basic() {
        assert_eq!(esc("a\"b\\c\nd\te"), "a\\\"b\\\\c\\nd\\te");
        assert_eq!(esc("中文"), "??");
    }
}
