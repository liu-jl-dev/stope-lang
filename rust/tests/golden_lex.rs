//! 词法：全部由 `golden_lex.txt`（147 条）驱动。
//!
//! 每条用例断言四件事：`TOKS` / `LEXEMES` / `ERRN` / `ERRS`。合计 588 条断言。
//!
//! ⚠ 这个文件的 TOKS / LEXEMES / ERRS **不做二次转义**：直接就是 esc_lex 形态，
//! 只有 SRC 是转义过的（且转义表里多 \v \f）。

use common::{check, data_path, esc_lex, fmt_g, main_cfg, read_golden, unescape_lex};
use stope::lexer::Lexer;
use stope::token::{type_name, TokenType};

mod common;

const LEXEME_TYPES: [TokenType; 4] =
    [TokenType::Integer, TokenType::Float, TokenType::String, TokenType::BinArr];

/// 扫到底，返回 (TOKS, LEXEMES, ERR_N, ERRS) 四个字段的实际值。
fn one(src: &str, cfg: &std::rc::Rc<stope::CustomOpcodeConfig>) -> (String, String, usize, String) {
    let mut lx = Lexer::new(src);
    let mut toks: Vec<String> = Vec::new();
    let mut lexemes: Vec<String> = Vec::new();
    for i in 0..10000 {
        let t = lx.next_token(Some(cfg));
        let mut s = format!("{}({})", type_name(t.type_), t.line);
        if !t.parsed.is_empty() {
            s += &format!("[{}]", esc_lex(&t.parsed));
        }
        match t.type_ {
            TokenType::Integer => s += &format!("={}", t.int_value()),
            TokenType::Float => s += &format!("={}", fmt_g(t.float_value())),
            _ => {}
        }
        toks.push(s);
        if LEXEME_TYPES.contains(&t.type_) {
            lexemes.push(format!("{}:{}", i, esc_lex(&t.lexeme)));
        }
        if t.type_ == TokenType::Eof {
            break;
        }
    }
    (toks.join(" "), lexemes.join(","), lx.errors.len(), common::join_esc(&lx.errors))
}

#[test]
fn golden_lex() {
    let cfg = main_cfg();
    let cases = read_golden("golden_lex.txt", false);
    assert_eq!(153, cases.len(), "golden_lex.txt 应为 153 条");
    let mut n = 0;
    for c in &cases {
        let cid = c.get("ID").map(String::as_str).unwrap_or("");
        let src = unescape_lex(c.get("SRC").map(String::as_str).unwrap_or(""));
        let (toks, lexemes, errn, errs) = one(&src, &cfg);
        check(cid, "TOKS", c.get("TOKS").map(String::as_str).unwrap_or(""), &toks);
        check(cid, "LEXEMES", c.get("LEXEMES").map(String::as_str).unwrap_or(""), &lexemes);
        check(cid, "ERRN", c.get("ERRN").map(String::as_str).unwrap_or(""), &errn.to_string());
        check(cid, "ERRS", c.get("ERRS").map(String::as_str).unwrap_or(""), &errs);
        n += 4;
    }
    assert_eq!(612, n, "词法断言总数");
    // 数据路径存在性：确保读的是原路径而不是复制品
    assert!(data_path("golden_lex.txt").exists());
}
