//! 编译器：`golden.txt` 的 `CMP` / `OUT` / `CERRS` 三个字段（215 条）。

use common::{check, dump_program, join_esc, main_cfg, read_golden, unescape};
use stope::{Compiler, Parser, Prog, Program, Result as StopeResult};

mod common;

#[test]
fn golden_compiler() {
    let cases = read_golden("golden.txt", true);
    assert_eq!(215, cases.len(), "golden.txt 应为 215 条");
    let cfg = main_cfg();
    let mut n = 0;
    for rec in &cases {
        let cid = rec.get("ID").map(String::as_str).unwrap_or("");
        let src = unescape(rec.get("SRC").map(String::as_str).unwrap_or(""));

        let mut ps = Parser::new(&src, Some(cfg.clone()));
        ps.const_folding = rec.get("FOLD").map(String::as_str) == Some("1");
        let mut tree = Prog::default();
        ps.parse_program(&mut tree);

        // PRE：预导出名单，逗号分隔（空元素表示一个空名字）；字段为空 = 不预导出
        let pre = rec.get("PRE").map(String::as_str).unwrap_or("").to_string();
        let pre_exports: Vec<&str> = if pre.is_empty() {
            vec![]
        } else {
            pre.split(',').collect()
        };
        let mut prog = Program::new();
        let mut c = Compiler::new(Some(cfg.clone()));
        let rc = c.compile(&tree, &mut prog, &pre_exports);
        check(cid, "CMP", rec.get("CMP").map(String::as_str).unwrap_or(""), &match rc {
            StopeResult::Success => "OK".to_string(),
            _ => "ERR".to_string(),
        });
        check(cid, "OUT", rec.get("OUT").map(String::as_str).unwrap_or(""), &dump_program(&prog, Some(&cfg)));
        check(cid, "CERRS", rec.get("CERRS").map(String::as_str).unwrap_or(""), &join_esc(&c.errors));
        n += 3;
    }
    assert_eq!(215 * 3, n, "编译器断言总数");
}
