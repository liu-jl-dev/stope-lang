//! 二进制数组解析 + 常量折叠矩阵：`golden_binarr.txt`（86 条）。
//!
//! 文件里有两类记录：
//! * `BA\t内容\tok|err\t[字节]` —— 直接打 BinaryArrayParser；
//! * `FB` / `FU\t运算符\t是否折叠\t结果` —— 直接打常量折叠矩阵。

use common::{check, fmt_bytes, fmt_g, read_text};
use std::rc::Rc;
use stope::ast::Expr;
use stope::binarr::parse_binary_array;
use stope::common::Result as StopeResult;
use stope::expr_optim::optimize;
use stope::token::TokenType;

mod common;

const INT64_MAX: i64 = i64::MAX;
const INT64_MIN: i64 = i64::MIN;

// BA 用例表：与 GD test_parser.gd 的 _dump_binarr 逐条一致
const BA_CASES: [&str; 31] = [
    "", " ", "a", "ab", "b 0100 0001", "b 01000001", "B 1", "o 101", "O 7",
    "d 65", "d 300", "D 255 0", "x 41", "x ff FF", "X 0f", "41", "4_1", "_41",
    "01 02", "  01   02  ", "x zz", "z", "b", "d", "b 2", "o 8", "0 1",
    "9999999999999999999999", "d 2147483647", "d 2147483648", "ff",
];

fn val(e: &Expr) -> String {
    match e {
        Expr::Null(_) => "Null".to_string(),
        Expr::Bool(_, v) => if *v { "true" } else { "false" }.to_string(),
        Expr::Int(_, v) => v.to_string(),
        Expr::Float(_, v) => fmt_g(*v),
        Expr::BinArr(_, b) => format!("[{}]", fmt_bytes(b)),
        Expr::Str(_, s) => format!("\"{}\"", s),
        _ => "?".to_string(),
    }
}

fn int(line: i32, v: i64) -> Expr {
    Expr::Int(line, v)
}
fn float(line: i32, v: f64) -> Expr {
    Expr::Float(line, v)
}
fn boolv(line: i32, v: bool) -> Expr {
    Expr::Bool(line, v)
}
fn null(line: i32) -> Expr {
    Expr::Null(line)
}
fn strv(line: i32, v: &str) -> Expr {
    Expr::Str(line, v.to_string())
}
fn bin(line: i32, v: &[u8]) -> Expr {
    Expr::BinArr(line, Rc::new(v.to_vec()))
}

fn fb(name: &str, op: TokenType, l: Expr, r: Expr) -> String {
    let o = optimize(Expr::BinaryOp { line: 1, op, left: Box::new(l), right: Box::new(r) });
    let folded = if matches!(o, Expr::BinaryOp { .. }) { 0 } else { 1 };
    format!("FB\t{}\t{}\t{}", name, folded, val(&o))
}

fn fu(name: &str, op: TokenType, v: Expr) -> String {
    let o = optimize(Expr::UnaryOp { line: 1, op, expr: Box::new(v) });
    let folded = if matches!(o, Expr::UnaryOp { .. }) { 0 } else { 1 };
    format!("FU\t{}\t{}\t{}", name, folded, val(&o))
}

/// 按 golden 文件的顺序产出一整份文本的行列表。
fn dump_all() -> Vec<String> {
    let mut out = Vec::new();

    // ---- BA：二进制数组解析 ----
    for t in BA_CASES {
        let mut buf = Vec::new();
        let ok = parse_binary_array(t, &mut buf);
        out.push(format!(
            "BA\t{}\t{}\t[{}]",
            t,
            if ok == StopeResult::Success { "ok" } else { "err" },
            fmt_bytes(&buf)
        ));
    }

    // ---- FB：二元折叠 ----
    out.push(fb("+", TokenType::Add, int(1, 1), int(1, 2)));
    out.push(fb("-", TokenType::Sub, int(1, 5), int(1, 3)));
    out.push(fb("*", TokenType::Mul, int(1, 2), int(1, 3)));
    out.push(fb("/", TokenType::Div, int(1, 7), int(1, 2)));
    out.push(fb("/", TokenType::Div, int(1, 6), int(1, 3)));
    out.push(fb("/", TokenType::Div, int(1, 1), int(1, 0)));
    out.push(fb("idiv", TokenType::IDiv, int(1, 7), int(1, 2)));
    out.push(fb("%", TokenType::Mod, int(1, 7), int(1, 2)));
    out.push(fb("^", TokenType::Pow, int(1, 2), int(1, 10)));
    out.push(fb("^", TokenType::Pow, int(1, 2), int(1, -1)));
    out.push(fb("+", TokenType::Add, float(1, 1.5), int(1, 1)));
    out.push(fb("+", TokenType::Add, int(1, INT64_MAX), int(1, 1)));
    out.push(fb("*", TokenType::Mul, int(1, INT64_MAX), int(1, 2)));
    out.push(fb("+", TokenType::Add, boolv(1, true), boolv(1, true)));
    out.push(fb("+", TokenType::Add, strv(1, "ab"), strv(1, "cd")));
    out.push(fb("*", TokenType::Mul, strv(1, "ab"), int(1, 3)));
    out.push(fb("*", TokenType::Mul, int(1, 3), strv(1, "ab")));
    out.push(fb("*", TokenType::Mul, strv(1, ""), int(1, 1000000)));
    out.push(fb("*", TokenType::Mul, strv(1, "ab"), int(1, -1)));
    out.push(fb("*", TokenType::Mul, float(1, 1.5), strv(1, "ab")));
    out.push(fb("+", TokenType::Add, bin(1, &[1]), bin(1, &[2])));
    out.push(fb("*", TokenType::Mul, bin(1, &[1]), int(1, 3)));
    out.push(fb("+", TokenType::Add, null(1), int(1, 5)));
    out.push(fb("+", TokenType::Add, int(1, 5), null(1)));
    out.push(fb("+", TokenType::Add, null(1), null(1)));
    out.push(fb("-", TokenType::Sub, null(1), int(1, 5)));
    out.push(fb("-", TokenType::Sub, int(1, 5), null(1)));
    out.push(fb("-", TokenType::Sub, null(1), null(1)));
    out.push(fb("*", TokenType::Mul, null(1), int(1, 5)));
    out.push(fb("^", TokenType::Pow, null(1), int(1, 5)));
    out.push(fb("==", TokenType::EQ, null(1), null(1)));
    out.push(fb("==", TokenType::EQ, null(1), int(1, 1)));
    out.push(fb("!=", TokenType::NE, null(1), int(1, 1)));
    out.push(fb("<", TokenType::LT, null(1), int(1, 1)));
    out.push(fb("==", TokenType::EQ, boolv(1, true), boolv(1, true)));
    out.push(fb("==", TokenType::EQ, boolv(1, true), int(1, 1)));
    out.push(fb("==", TokenType::EQ, int(1, 1), float(1, 1.0)));
    out.push(fb("==", TokenType::EQ, strv(1, "a"), strv(1, "a")));
    out.push(fb("<", TokenType::LT, int(1, 1), int(1, 2)));
    out.push(fb("<", TokenType::LT, boolv(1, true), int(1, 2)));
    out.push(fb("<=", TokenType::LE, float(1, 1.5), float(1, 1.5)));
    out.push(fb(">", TokenType::GT, int(1, 2), int(1, 1)));
    out.push(fb(">=", TokenType::GE, int(1, 2), int(1, 2)));
    out.push(fb("and", TokenType::And, int(1, 1), int(1, 0)));
    out.push(fb("or", TokenType::Or, int(1, 0), strv(1, "a")));

    // ---- FU：一元折叠 ----
    out.push(fu("-", TokenType::Sub, boolv(1, true)));
    out.push(fu("-", TokenType::Sub, boolv(1, false)));
    out.push(fu("-", TokenType::Sub, int(1, 5)));
    out.push(fu("-", TokenType::Sub, float(1, 1.5)));
    out.push(fu("-", TokenType::Sub, int(1, INT64_MIN)));
    out.push(fu("!", TokenType::Not, null(1)));
    out.push(fu("!", TokenType::Not, int(1, 0)));
    out.push(fu("!", TokenType::Not, float(1, 0.0)));
    out.push(fu("!", TokenType::Not, int(1, 5)));
    out.push(fu("!", TokenType::Not, strv(1, "")));
    out
}

#[test]
fn golden_binarr() {
    let want: Vec<String> = read_text("golden_binarr.txt")
        .split('\n')
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
        .map(String::from)
        .collect();
    let got = dump_all();
    assert_eq!(86, want.len(), "golden_binarr.txt 行数");
    assert_eq!(86, got.len(), "dump_all 行数");
    for i in 0..want.len().min(got.len()) {
        check(&format!("#{}", i + 1), "行", &want[i], &got[i]);
    }
}
