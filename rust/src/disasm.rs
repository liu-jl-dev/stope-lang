//! `Program` 反汇编（调试用）—— 对齐 `python/stope/debug.py` 的 `disasm`。
//!
//! 输出与 C++ / GDScript / Node.js / C# **逐字节一致**（`golden_disasm.txt` 是五方的
//! 共同期望值）：编号列宽 8、名字列宽 `max(10, 最长名字)`（按 UTF-8 字节数丈量）、
//! int/float 常量同列连排、字符串常量一行一个、二进制数组只印字节数、最后是 warning 段。

use crate::opcode::{BUILTIN_COUNT, BUILTIN_NAMES, CustomOpcodeConfig, Opcode, K_FIRST_CUSTOM_OPCODE};
use crate::program::Program;
use crate::utf::fmt_g;

/// 名字列的对齐宽度下限 = 内置名里最长的两个（PushString / PushBinArr，10 字节）。
const MIN_NAME_WIDTH: usize = 10;

/// 内置指令是否带一个操作数（操作数占紧随其后的一个数字）。
pub fn opcode_has_arg(op: i32) -> bool {
    if !(0..BUILTIN_COUNT).contains(&op) {
        return false;
    }
    if op >= Opcode::PushInt as i32 && op <= Opcode::At as i32 {
        return true;
    }
    op == Opcode::If as i32 || op == Opcode::GoTo as i32 || op == Opcode::Return as i32
}

/// 自定义指令只有在**变长参数**时才带操作数。
pub fn custom_opcode_has_arg(raw: i32, config: &CustomOpcodeConfig) -> bool {
    config
        .opcodes
        .iter()
        .any(|(_, info)| info.opcode == raw && info.is_var_arg)
}

/// 按 UTF-8 字节数右填充空格（非 ASCII 名会少填几个空格，与 C++ 一致）。
fn pad_right(s: &str, width: usize) -> String {
    let n = s.len();
    if n >= width {
        s.to_string()
    } else {
        format!("{}{}", s, " ".repeat(width - n))
    }
}

/// 把 `Program` 反汇编成可读文本。
///
/// `config` 可空：产物里没有自定义指令时传 `None` 即可（等价于
/// [`disasm_no_custom`]）。含自定义指令时**必须**传注册时用的那一份。
pub fn disasm(prog: &Program, config: Option<&CustomOpcodeConfig>) -> String {
    // ---------- 编号 -> (名字, is_var_arg, arg_num) 的反查表 ----------
    // C++ 的 CustomOpcodeConfig 是 std::map（按名字字典序）：先按名字排序建表，
    // 撞号时「谁赢」取决于此。
    let mut custom_by_opcode: std::collections::BTreeMap<i32, (String, bool, i32)> =
        std::collections::BTreeMap::new();
    let mut warnings: Vec<String> = Vec::new();
    let mut name_width = MIN_NAME_WIDTH;
    if let Some(cfg) = config {
        let mut names: Vec<&(String, crate::opcode::CustomOpcode)> = cfg.opcodes.iter().collect();
        names.sort_by(|a, b| a.0.cmp(&b.0));
        for (name, info) in names {
            if info.opcode < K_FIRST_CUSTOM_OPCODE {
                let what = if (0..BUILTIN_COUNT).contains(&info.opcode) {
                    BUILTIN_NAMES[info.opcode as usize].to_string()
                } else {
                    "(not an opcode)".to_string()
                };
                warnings.push(format!(
                    "custom opcode \"{}\" uses #{}, which collides with {}; builtin decoding wins.",
                    name, info.opcode, what
                ));
                continue;
            }
            if let Some(prev) = custom_by_opcode.get(&info.opcode) {
                warnings.push(format!(
                    "custom opcodes \"{}\" and \"{}\" share #{}; the former wins.",
                    prev.0, name, info.opcode
                ));
                continue;
            }
            custom_by_opcode.insert(info.opcode, (name.clone(), info.is_var_arg, info.arg_num));
            name_width = name_width.max(name.len());
        }
    }

    // ---------- 指令流 ----------
    let mut parts: Vec<String> = Vec::new();
    let mut unknown: Vec<i32> = Vec::new(); // 不认识的编号，最后统一提示（保持首次出现顺序）
    let ops = &prog.opcodes;
    let n = ops.len();
    let mut i = 0usize;
    while i < n {
        let raw = ops[i];
        let has_arg;
        let name;
        if (0..BUILTIN_COUNT).contains(&raw) {
            name = BUILTIN_NAMES[raw as usize].to_string();
            has_arg = opcode_has_arg(raw);
        } else if let Some(it) = custom_by_opcode.get(&raw) {
            name = it.0.clone();
            has_arg = it.1;
        } else {
            // 编号不认识就只能印数字。绝不能猜「有没有操作数」。
            name = if raw > Opcode::Return as i32 {
                format!("Custom{}", raw)
            } else {
                format!("Op#{}", raw)
            };
            if !unknown.contains(&raw) {
                unknown.push(raw);
            }
            has_arg = false;
        }
        parts.push(pad_right(&format!("[{}]", i), 8));
        parts.push(pad_right(&name, name_width));
        parts.push(" ".to_string());
        i += 1;
        if has_arg {
            if i < n {
                parts.push(ops[i].to_string());
                i += 1;
            } else {
                parts.push("<missing operand>".to_string());
                warnings.push(format!(
                    "opcode at [{}] expects an operand but the stream ends there.",
                    i - 1
                ));
            }
        }
        parts.push("\n".to_string());
    }
    let mut ss: String = parts.concat();

    // ---------- 自定义指令表（名字、编号、参数形态一次交代清楚） ----------
    // 必须按**编号**排序打印：C++ 的 customByOpcode 是 map<short, ...>，迭代序是编号序。
    if !custom_by_opcode.is_empty() {
        ss += "custom opcodes:\n";
        for (opcode, (name, is_var_arg, arg_num)) in &custom_by_opcode {
            ss += "  ";
            ss += &pad_right(name, name_width);
            ss += " -> ";
            ss += &opcode.to_string();
            if *is_var_arg {
                ss += " (vararg)";
            } else {
                ss += &format!(" ({} args)", arg_num);
            }
            ss += "\n";
        }
    }

    // ---------- 变量表与常量池 ----------
    ss += "variables:\n";
    let mut variables: Vec<String> = vec![String::new(); prog.variable_num.max(0) as usize];
    for (name, idx) in &prog.exports {
        if (*idx as usize) < variables.len() {
            variables[*idx as usize] = name.clone();
        }
    }
    ss += "  ";
    for (k, v) in variables.iter().enumerate() {
        ss += &format!("\"{}\"", v);
        if k < variables.len() - 1 {
            ss += " ";
        }
    }
    ss += "\nint consts:\n";
    for v in &prog.int_consts {
        ss += &format!("  {}", v);
    }
    ss += "\nfloat consts:\n";
    for v in &prog.float_consts {
        ss += &format!("  {}", fmt_g(*v));
    }
    ss += "\nstring consts:\n";
    for v in &prog.string_consts {
        ss += &format!("  \"{}\"\n", v);
    }
    ss += "binary array consts:\n";
    for v in &prog.binarr_consts {
        ss += &format!("  {} bytes\n", v.len());
    }
    ss += &format!("max return num: {}\n", prog.max_return_num);
    ss += &format!("required stack size: {}\n", prog.required_stack_size);

    for raw in &unknown {
        if *raw > Opcode::Return as i32 {
            warnings.push(format!(
                "opcode #{} is not a builtin; pass the CustomOpcodeConfig to Disasm() to decode it.",
                raw
            ));
        } else {
            warnings.push(format!(
                "opcode #{} is not a valid instruction (unpatched placeholder?).",
                raw
            ));
        }
    }
    for w in &warnings {
        ss += &format!("warning: {}\n", w);
    }
    ss
}

/// 产物里确定没有自定义指令时的简写。
pub fn disasm_no_custom(prog: &Program) -> String {
    disasm(prog, None)
}
