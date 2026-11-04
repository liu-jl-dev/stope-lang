//! STML：`stml_cases.txt`（125 条用例清单）+ `golden_stml.txt`（126 条记录）。
//!
//! ⚠ `golden_stml.txt` 的字段**不解转义**（探针只做了 escUtf8），读进来是什么就比什么。
//! 而 `stml_cases.txt` 的 `SRC` 要按 `\\ \n \r \t` 解一层。

use common::{check, esc16, join_esc16, read_golden, read_stml_cases};
use std::collections::BTreeMap;
use stope::common::Result as StopeResult;
use stope::stml::{Element, LexerState, TokenType, type_name};
use stope::stml_lexer::{Lexer, HAS_LEXEME};
use stope::stml_parser::{default_state_func, Parser, StateFuncOpt};

mod common;

fn state_of(name: &str) -> LexerState {
    match name {
        "Text" => LexerState::Text,
        "Nevext" => LexerState::Nevext,
        "Stope" => LexerState::Stope,
        _ => LexerState::Xml,
    }
}

/// 元素形状串。字段顺序固定：tag、行号、自闭合、属性（**字典序**）、文本、子元素。
fn shape(e: &Element) -> String {
    let mut out = format!("Elem({}, L{}", esc16(&e.tag), e.line);
    if e.self_closing {
        out += ", /";
    }
    for (name, value) in &e.attrs {
        out += &format!(", @{}", esc16(name));
        if !value.is_empty() {
            out += &format!("=\"{}\"", esc16(value));
        }
    }
    if !e.text.is_empty() {
        out += &format!(", T(L{})=\"{}\"", e.text_line, esc16(&e.text));
    }
    if !e.children.is_empty() {
        out += ", C=[";
        out += &e.children.iter().map(shape).collect::<Vec<_>>().join(" ");
        out += "]";
    }
    out + ")"
}

fn run_lex(case: &BTreeMap<String, String>, want: &BTreeMap<String, String>, src: &str) {
    let cid = case["ID"].as_str();
    let st = state_of(case.get("ST").map(String::as_str).unwrap_or("Xml"));
    let mut lx = Lexer::with_state(src, st);
    let mut toks: Vec<String> = Vec::new();
    let mut lexs: Vec<String> = Vec::new();
    for i in 0..10000 {
        // 死循环保险丝（NextToken 不消费字符时）
        let t = lx.next_token();
        toks.push(format!("{}({})", type_name(t.type_), t.line));
        if HAS_LEXEME.contains(&t.type_) {
            lexs.push(format!("{}:{}", i, esc16(&t.lexeme)));
        }
        if t.type_ == TokenType::Eof {
            break;
        }
    }
    check(cid, "TOKS", want.get("TOKS").map(String::as_str).unwrap_or(""), &toks.join(" "));
    check(cid, "LEXS", want.get("LEXS").map(String::as_str).unwrap_or(""), &lexs.join(","));
    check(cid, "ERRN", want.get("ERRN").map(String::as_str).unwrap_or(""), &lx.errors.len().to_string());
    check(cid, "ERRS", want.get("ERRS").map(String::as_str).unwrap_or(""), &join_esc16(&lx.errors));
}

fn run_parse(case: &BTreeMap<String, String>, want: &BTreeMap<String, String>, src: &str) {
    let cid = case["ID"].as_str();
    let mut lx = Lexer::new(src);
    let mut root = Element::new();
    let (rc, perrs, lerrs) = {
        let mut ps = Parser::new(&mut lx);
        ps.max_depth = case.get("MD").and_then(|s| s.parse::<i32>().ok()).unwrap_or(256);
        let sf = case.get("SF").map(String::as_str).unwrap_or("default");
        let state_func = match sf {
            "null" => StateFuncOpt::None,
            "text" => {
                StateFuncOpt::Custom(Box::new(|_tag: &str, _attrs: &BTreeMap<String, String>| {
                    LexerState::Text
                }))
            }
            _ => StateFuncOpt::Default, // default_state_func
        };
        let rc = ps.parse(&mut root, state_func);
        (rc, ps.errors.clone(), ps.lexer().errors.clone())
    };
    check(cid, "SHAPE", want.get("SHAPE").map(String::as_str).unwrap_or(""), &shape(&root));
    check(
        cid,
        "RESULT",
        want.get("RESULT").map(String::as_str).unwrap_or(""),
        &if rc == StopeResult::Success { "Success" } else { "Error" }.to_string(),
    );
    check(cid, "ERRN", want.get("ERRN").map(String::as_str).unwrap_or(""), &perrs.len().to_string());
    check(cid, "ERRS", want.get("ERRS").map(String::as_str).unwrap_or(""), &join_esc16(&perrs));
    check(cid, "LEXERRN", want.get("LEXERRN").map(String::as_str).unwrap_or(""), &lerrs.len().to_string());
    check(cid, "LEXERRS", want.get("LEXERRS").map(String::as_str).unwrap_or(""), &join_esc16(&lerrs));
}

#[test]
fn golden_stml() {
    let cases = read_stml_cases();
    assert!(!cases.is_empty(), "stml_cases.txt 一条都没读到");
    let want = read_golden("golden_stml.txt", false);
    assert_eq!(126, want.len(), "golden_stml.txt 应为 126 条");
    let want_by_id: BTreeMap<&str, &BTreeMap<String, String>> =
        want.iter().map(|r| (r["ID"].as_str(), r)).collect();

    let mut seen_lex = 0;
    let mut seen_parse = 0;
    for case in &cases {
        let cid = case["ID"].as_str();
        let Some(rec) = want_by_id.get(cid) else {
            panic!("{}: golden_stml.txt 里没有这条", cid);
        };
        let times: usize = case.get("times").and_then(|s| s.parse().ok()).unwrap_or(1);
        let src = case["src"].repeat(times);
        if case.get("KIND").map(String::as_str) == Some("parse") {
            seen_parse += 1;
            run_parse(case, rec, &src);
        } else {
            seen_lex += 1;
            run_lex(case, rec, &src);
        }
    }

    // 清单与期望值必须一一对应（少一条就是「用例没跑」而不是「用例通过」）
    assert_eq!(126, cases.len(), "清单 ↔ golden 条数");
    assert_eq!(126, seen_lex + seen_parse, "词法 + 语法");

    // default_state_func 的行为契约（<sto>/<nev>/<p>）
    assert_eq!(LexerState::Stope, default_state_func("sto", &BTreeMap::new()));
    assert_eq!(LexerState::Nevext, default_state_func("nev", &BTreeMap::new()));
    assert_eq!(LexerState::Text, default_state_func("p", &BTreeMap::new()));
    assert_eq!(LexerState::Xml, default_state_func("other", &BTreeMap::new()));
}
