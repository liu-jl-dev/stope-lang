//! 反汇编：`golden_disasm.txt`（12 条）。
//!
//! 逐字节比 `disasm` 的完整输出（含 `variables:` / 常量池 / warning 段）。

use common::{check, main_cfg, read_golden, unescape};
use std::rc::Rc;
use stope::{
    custom_opcode_has_arg, disasm, disasm_no_custom, Compiler, CustomOpcodeConfig, Opcode,
    Parser, Prog, Program, opcode_has_arg,
};

mod common;

/// 与探针里的 g_cfg 一致：myop #100（2 个参数）/ vop #101（变长）
fn main_cfg_rc() -> Rc<CustomOpcodeConfig> {
    main_cfg()
}

/// 故意撞内置 Add
fn collide_cfg() -> Rc<CustomOpcodeConfig> {
    let mut cfg = CustomOpcodeConfig::new();
    cfg.add_custom_opcode("my:steal", Opcode::Add as i32, 2);
    Rc::new(cfg)
}

#[test]
fn golden_disasm() {
    let cases = read_golden("golden_disasm.txt", true);
    assert_eq!(12, cases.len(), "golden_disasm.txt 应为 12 条");

    for rec in &cases {
        let cid = rec.get("ID").map(String::as_str).unwrap_or("");
        let cfg_name = rec.get("CFG").map(String::as_str).unwrap_or("none");
        let cfg = match cfg_name {
            "main" => Some(main_cfg_rc()),
            "collide" => Some(collide_cfg()),
            _ => None,
        };

        let got = if rec.get("MODE").map(String::as_str) == Some("src") {
            // SRC 是 E_(escUtf8(源码))，要解两层
            let src = unescape(rec.get("SRC").map(String::as_str).unwrap_or(""));
            let mut ps = Parser::new(&src, cfg.clone());
            let mut tree = Prog::default();
            ps.parse_program(&mut tree);
            let mut prog = Program::new();
            Compiler::new(cfg.clone()).compile(&tree, &mut prog, &[]);
            disasm(&prog, cfg.as_deref())
        } else {
            // raw：直接给指令流，不经过前端
            let mut prog = Program::new();
            for s in rec.get("OPS").map(String::as_str).unwrap_or("").split(',') {
                if !s.is_empty() {
                    prog.opcodes.push(s.parse::<i32>().unwrap());
                }
            }
            prog.variable_num = rec.get("VARS").map(String::as_str).unwrap_or("0").parse().unwrap_or(0);
            disasm(&prog, cfg.as_deref())
        };
        check(cid, "DIS", rec.get("DIS").map(String::as_str).unwrap_or(""), &got);
    }
}

#[test]
fn disasm_details() {
    // ---- 单测：这四条锁的是「golden 恰好看不出差别」的细节 ----
    assert_eq!(
        disasm_no_custom(&Program::new()),
        disasm(&Program::new(), None),
        "DISP-NOCUSTOM: disasm_no_custom 等价于 disasm(prog, None)"
    );

    // OpcodeHasArg 的分档：PushInt..At 与 If/GoTo/Return 带操作数
    let mut want_arg = vec![false; 33];
    for op in Opcode::PushInt as i32..=Opcode::At as i32 {
        want_arg[op as usize] = true;
    }
    want_arg[Opcode::If as usize] = true;
    want_arg[Opcode::GoTo as usize] = true;
    want_arg[Opcode::Return as usize] = true;
    let bad: Vec<i32> = (0..33).filter(|&op| opcode_has_arg(op) != want_arg[op as usize]).collect();
    assert!(bad.is_empty(), "DISP-ARG: opcode_has_arg 的分档错在 {:?}", bad);

    // 只有变长自定义指令才带操作数
    assert!(!custom_opcode_has_arg_raw(100), "DISP-CUSTOM-ARG: 定长指令不带操作数");
    assert!(custom_opcode_has_arg_raw(101), "DISP-CUSTOM-ARG: 变长指令带操作数");

    // custom opcodes 段按**编号**排序，不是名字序（golden 那 12 条两种序恰好一致，
    // 看不出来；这里构造一组「名字序与编号序相反」的配置把它锁住）
    let mut cfg = CustomOpcodeConfig::new();
    cfg.add_custom_opcode("a_first", 101, -1); // 名字序在前，编号在后
    cfg.add_custom_opcode("b_second", 100, 2); // 名字序在后，编号在前
    let mut prog = Program::new();
    prog.opcodes.extend([101, 0, 100, 3]);
    let text = disasm(&prog, Some(&cfg));
    let table = &text[text.find("custom opcodes:").unwrap()..];
    assert!(
        table.find("b_second").unwrap() < table.find("a_first").unwrap(),
        "DISP-SORT: custom opcodes 段按编号排序（100 在 101 之前）"
    );
}

fn custom_opcode_has_arg_raw(opcode: i32) -> bool {
    let mut cfg = CustomOpcodeConfig::new();
    cfg.add_custom_opcode("x", opcode, if opcode == 101 { -1 } else { 2 });
    custom_opcode_has_arg(opcode, &cfg)
}
