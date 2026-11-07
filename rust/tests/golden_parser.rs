//! 语法：`golden.txt`（215 条）+ 嵌套深度上限。
//!
//! 每条用例断言六件事：AST 形状串、语句行号序列、语法 / 词法错误条数与文案。

use common::{check, join_esc, main_cfg, read_golden, unescape};
use stope::{Parser, Prog};

mod common;

#[test]
fn golden_parser() {
    let cases = read_golden("golden.txt", true);
    assert_eq!(215, cases.len(), "golden.txt 应为 215 条");
    let mut n = 0;
    for rec in &cases {
        let cid = rec.get("ID").map(String::as_str).unwrap_or("");
        let src = unescape(rec.get("SRC").map(String::as_str).unwrap_or(""));

        let mut ps = Parser::new(&src, Some(main_cfg()));
        ps.const_folding = rec.get("FOLD").map(String::as_str) == Some("1");
        let mut tree = Prog::default();
        ps.parse_program(&mut tree);

        check(cid, "SHAPE", rec.get("SHAPE").map(String::as_str).unwrap_or(""), &stope::ast::shape_prog(&tree));
        check(
            cid,
            "LINES",
            rec.get("LINES").map(String::as_str).unwrap_or(""),
            &tree.stmts.iter().map(|s| s.line().to_string()).collect::<Vec<_>>().join(","),
        );
        check(cid, "PERR", rec.get("PERR").map(String::as_str).unwrap_or(""), &ps.errors.len().to_string());
        check(cid, "PERRS", rec.get("PERRS").map(String::as_str).unwrap_or(""), &join_esc(&ps.errors));
        check(cid, "LEXERR", rec.get("LEXERR").map(String::as_str).unwrap_or(""), &ps.lexer().errors.len().to_string());
        check(cid, "LEXERRS", rec.get("LEXERRS").map(String::as_str).unwrap_or(""), &join_esc(&ps.lexer().errors));
        n += 6;
    }
    assert_eq!(215 * 6, n, "语法断言总数");
}

// ---------------- 嵌套深度上限 ----------------
// 期望值不 dump：限额与错误文案是**四方约定**。任一侧改了计数口径或文案，
// 各实现的测试都会红。

fn depth_source(kind: &str, n: i32) -> String {
    // 与 GD 侧 _depth_case 的构造逐字一致：块里要有语句，否则永远进不到
    // parse_expr，深度计数根本没机会检查。
    match kind {
        "paren" => format!("{}a{};", "(".repeat(n as usize), ")".repeat(n as usize)),
        "block" => format!("{}a;{}", "{".repeat(n as usize), "}".repeat(n as usize)),
        "unary" => format!("{}a;", "-".repeat(n as usize)),
        "at" => format!("{}0{};", "a[".repeat(n as usize), "]".repeat(n as usize)),
        _ => panic!("unknown kind {}", kind),
    }
}

fn parse_depth(kind: &str, n: i32) -> (Vec<String>, Prog) {
    let mut ps = Parser::new(&depth_source(kind, n), None);
    let mut tree = Prog::default();
    ps.parse_program(&mut tree);
    (ps.errors, tree)
}

#[test]
fn parser_depth_limit() {
    let depth_cases: [(&str, &str, i32, bool); 9] = [
        ("PD-DEPTH-1", "paren", 200, false), // 限额内：照常解析
        ("PD-DEPTH-2", "paren", 300, true),
        ("PD-DEPTH-3", "block", 300, true),
        ("PD-DEPTH-4", "unary", 300, true), // 没有括号的递归
        ("PD-DEPTH-5", "at", 300, true),
        ("PD-DEPTH-6", "paren", 12000, true), // 曾真的栈溢出
        ("PD-DEPTH-7", "block", 200, false),
        ("PD-DEPTH-8", "unary", 200, false),
        ("PD-DEPTH-9", "at", 200, false),
    ];
    for (cid, kind, n, deep) in depth_cases {
        let (errors, tree) = parse_depth(kind, n);
        if !deep {
            assert_eq!(0, errors.len(), "{} {} {}: 错误条数", cid, kind, n);
            assert!(tree.stmts.len() > 0, "{} 应解析出语句", cid);
            continue;
        }
        // 超限只报一条（不刷连锁噪音），文案逐字固定
        assert_eq!(1, errors.len(), "{} {} {}: 错误条数", cid, kind, n);
        assert_eq!("line 1: nesting too deep (max 256). ", errors[0], "{} 错误文案", cid);
    }

    assert_eq!(256, Parser::new("", None).max_depth, "默认 max_depth");

    // max_depth = 0 时不检查：600 层（远超 256）仍能解析
    let mut ps0 = Parser::new(&depth_source("paren", 600), None);
    ps0.max_depth = 0;
    let mut tree0 = Prog::default();
    ps0.parse_program(&mut tree0);
    assert_eq!(0, ps0.errors.len(), "PD-NOLIMIT 错误条数");
    assert_eq!(1, tree0.stmts.len(), "PD-NOLIMIT 语句数");
}
