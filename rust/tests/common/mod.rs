//! golden 数据的读取、转义与「单行产物格式」—— 对齐 `python/tests/golden.py`。
//!
//! 数据真源在 `gdscript/test/data/`（只读，绝不复制）。
//!
//! ⚠ 转义约定每个文件都不一样：
//!
//! | 文件            | 值要不要解转义 | SRC 用什么解 |
//! |-----------------|----------------|--------------|
//! | golden.txt      | 解一层         | 解两层       |
//! | golden_disasm   | 解一层         | 解两层       |
//! | golden_lex.txt  | **不解**       | unescape_lex |
//! | golden_stml.txt | **不解**       | unescape_lex |
//! | stml_cases.txt  | —（清单本身）  | unescape_lex |

// 各测试 crate 只用其中一部分函数
#![allow(dead_code)]

use std::collections::BTreeMap;
use std::path::PathBuf;
use stope::esc;

/// golden 数据目录：`<repo>/gdscript/test/data`（测试直接读原路径）。
pub fn data_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..").join("gdscript").join("test").join("data")
}

pub fn data_path(name: &str) -> PathBuf {
    data_dir().join(name)
}

/// 读一份数据文件，统一剥掉 `\r`（Windows 上探针输出 CRLF）。
pub fn read_text(name: &str) -> String {
    std::fs::read_to_string(data_path(name))
        .unwrap_or_else(|e| panic!("读取 {} 失败: {}", data_path(name).display(), e))
        .replace('\r', "")
}

/// 反转义：与探针的 `E_()` 对称（`\\ \n \r \t`，其余原样保留）。
pub fn unescape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars().peekable();
    while let Some(ch) = chars.next() {
        if ch != '\\' {
            out.push(ch);
            continue;
        }
        let c = chars.next().unwrap_or('\0');
        match c {
            '\\' => out.push('\\'),
            'n' => out.push('\n'),
            'r' => out.push('\r'),
            't' => out.push('\t'),
            other => {
                out.push('\\');
                out.push(other);
            }
        }
    }
    out
}

/// 与 [`unescape`] 相同，但**多认 `\v` 与 `\f`** —— 词法与 STML 的 SRC 用这套。
pub fn unescape_lex(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let chars: Vec<char> = s.chars().collect();
    let mut i = 0;
    while i < chars.len() {
        let ch = chars[i];
        if ch == '\\' && i + 1 < chars.len() {
            let c = chars[i + 1];
            let mapped = match c {
                '\\' => Some('\\'),
                'n' => Some('\n'),
                'r' => Some('\r'),
                't' => Some('\t'),
                'v' => Some('\u{0b}'),
                'f' => Some('\u{0c}'),
                _ => None,
            };
            if let Some(m) = mapped {
                out.push(m);
                i += 2;
                continue;
            }
        }
        out.push(ch);
        i += 1;
    }
    out
}

/// 词法比对专用转义：比 [`esc`](stope::esc) 多 `\v \f`、不转义引号。
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
            c => out.push(c),
        }
    }
    out
}

/// `E_()` 那一套：把 `\` 与 `"` 双写（`golden_stml.txt` 的 `ERRS` 用）。
pub fn esc_quote(s: &str) -> String {
    s.replace('\\', "\\\\").replace('"', "\\\"")
}

pub fn join_quoted<'a>(errs: impl IntoIterator<Item = &'a String>) -> String {
    errs.into_iter().map(|e| esc_quote(e)).collect::<Vec<_>>().join("|")
}

pub fn join_esc<'a>(errs: impl IntoIterator<Item = &'a String>) -> String {
    errs.into_iter().map(|e| esc_lex(e)).collect::<Vec<_>>().join("|")
}

/// escUtf8 的忠实实现，但按 **UTF-16 码元**遍历 —— 与 C++ 的 u16string 一致。
pub fn esc16(text: &str) -> String {
    let units: Vec<u16> = text.encode_utf16().collect();
    let mut out = String::new();
    for c in units {
        match c {
            0x5C => out.push_str("\\\\"),
            0x22 => out.push_str("\\\""),
            0x0A => out.push_str("\\n"),
            0x0D => out.push_str("\\r"),
            0x09 => out.push_str("\\t"),
            _ if c < 128 => out.push(c as u8 as char),
            _ => out.push('?'),
        }
    }
    out
}

pub fn join_esc16<'a>(errs: impl IntoIterator<Item = &'a String>) -> String {
    errs.into_iter().map(|e| esc16(e)).collect::<Vec<_>>().join("|")
}

/// 读一份 golden 文件 → 若干 `KEY=VALUE` 字典，行首 `#` 是注释。
pub fn read_golden(name: &str, unescape_values: bool) -> Vec<BTreeMap<String, String>> {
    let mut out = Vec::new();
    for line in read_text(name).split('\n') {
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let mut rec = BTreeMap::new();
        for field in line.split('\t') {
            let Some(eq) = field.find('=') else { continue };
            let v = &field[eq + 1..];
            rec.insert(field[..eq].to_string(), if unescape_values { unescape(v) } else { v.to_string() });
        }
        if !rec.is_empty() {
            out.push(rec);
        }
    }
    out
}

/// `golden_binarr.txt` 有两类记录，按 TAB 位置切。
pub fn read_binarr_golden() -> Vec<String> {
    read_text("golden_binarr.txt")
        .split('\n')
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
        .map(String::from)
        .collect()
}

/// `stml_cases.txt`：STML 的**用例清单**（四方共用）。
pub fn read_stml_cases() -> Vec<BTreeMap<String, String>> {
    let mut out = Vec::new();
    for line in read_text("stml_cases.txt").split('\n') {
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let mut rec = BTreeMap::new();
        for part in line.split('\t') {
            let Some(eq) = part.find('=') else { continue };
            rec.insert(part[..eq].to_string(), part[eq + 1..].to_string());
        }
        if !rec.contains_key("ID") {
            continue;
        }
        rec.insert("src".to_string(), unescape_lex(rec.get("SRC").map(String::as_str).unwrap_or("")));
        rec.insert(
            "times".to_string(),
            rec.get("TIMES").map(String::as_str).unwrap_or("1").to_string(),
        );
        out.push(rec);
    }
    out
}

pub fn fmt_g(v: f64) -> String {
    stope::fmt_g(v)
}

pub fn fmt_bytes(b: &[u8]) -> String {
    stope::fmt_bytes(b)
}

use stope::opcode::{Opcode, BUILTIN_NAMES};

/// 「单行产物格式」（docs/zh-cn/compiler-test-plan.md §2.3）。
pub fn dump_program(prog: &stope::Program, custom: Option<&stope::CustomOpcodeConfig>) -> String {
    fn has_arg(op: i32, custom: Option<&stope::CustomOpcodeConfig>) -> bool {
        if op > Opcode::Return as i32 {
            if let Some(cfg) = custom {
                for (_, info) in &cfg.opcodes {
                    if info.opcode == op {
                        return info.is_var_arg;
                    }
                }
            }
            return false;
        }
        stope::opcode_has_arg(op)
    }

    let mut out = String::from("code[");
    let ops = &prog.opcodes;
    let mut i = 0usize;
    let mut first = true;
    while i < ops.len() {
        if !first {
            out.push(' ');
        }
        first = false;
        let op = ops[i];
        i += 1;
        if op > Opcode::Return as i32 {
            out.push_str(&format!("Opcode({})", op));
        } else {
            out.push_str(BUILTIN_NAMES[op as usize]);
        }
        if has_arg(op, custom) && i < ops.len() {
            out.push_str(&format!("({})", ops[i]));
            i += 1;
        }
    }
    out.push(']');

    out += &format!(" vars={}", prog.variable_num);
    out += &format!(" stack={}", prog.required_stack_size);
    out += &format!(" maxRet={}", prog.max_return_num);
    out += &format!(
        " ints=[{}]",
        prog.int_consts.iter().map(|x| x.to_string()).collect::<Vec<_>>().join(",")
    );
    out += &format!(
        " floats=[{}]",
        prog.float_consts.iter().map(|x| fmt_g(*x)).collect::<Vec<_>>().join(",")
    );
    out += &format!(
        " strs=[{}]",
        prog.string_consts.iter().map(|s| esc(s)).collect::<Vec<_>>().join(",")
    );
    out += &format!(
        " binarrs=[{}]",
        prog.binarr_consts
            .iter()
            .map(|b| format!("[{}]", fmt_bytes(b)))
            .collect::<Vec<_>>().join(" ")
    );
    // C++ 的 exports 是 std::map：按名字排序打印（BTreeMap 迭代即字典序）
    out += &format!(
        " exports=[{}]",
        prog.exports
            .iter()
            .map(|(k, v)| format!("{}:{}", esc(k), v))
            .collect::<Vec<_>>().join(",")
    );
    out
}

/// golden 里的通用自定义指令配置（与 cpp/tools/golden.cpp 的 g_cfg 一致）。
pub fn main_cfg() -> std::rc::Rc<stope::CustomOpcodeConfig> {
    let mut cfg = stope::CustomOpcodeConfig::new();
    cfg.add_custom_opcode("myop", 100, 2);
    cfg.add_custom_opcode("vop", 101, -1);
    std::rc::Rc::new(cfg)
}

/// 断言工具：期望 / 实际不一致时 panic，消息里带用例 ID 与字段名。
pub fn check(cid: &str, field: &str, want: &str, got: &str) {
    assert_eq!(want, got, "用例 {} 字段 {}", cid, field_label(field, want, got));
}

fn field_label(field: &str, want: &str, got: &str) -> String {
    format!("{} 不匹配\n  期望: {}\n  实际: {}", field, want, got)
}

// ==================== 词法 → 语法 → 编译 的一次跑完 ====================

/// 跑一条 golden 用例：词法 → 语法，把结果摊平成与记录同名的字段。
///
/// ⚠ `SRC` 要解**两**层转义：golden 里存的是 `E_(escUtf8(源码))`，读文件时已解了
/// 外层的 `E_`，这里再解一层 `escUtf8`。而 `SHAPE` / `OUT` 这些字段只解一层。
pub fn run_parse_case(rec: &Rec) -> Rec {
    use stope::{ast, Parser, Prog};
    let src = unescape(rec.get("SRC").map(String::as_str).unwrap_or(""));
    let fold = rec.get("FOLD").map(String::as_str) == Some("1");

    let mut ps = Parser::new(&src, Some(main_cfg()));
    ps.const_folding = fold;
    let mut tree = Prog::default();
    ps.parse_program(&mut tree);

    let mut out = Rec::new();
    out.insert("SRC".into(), src);
    out.insert("SHAPE".into(), ast::shape_prog(&tree));
    out.insert(
        "LINES".into(),
        tree.stmts.iter().map(|s| s.line().to_string()).collect::<Vec<_>>().join(","),
    );
    out.insert("PERR".into(), ps.errors.len().to_string());
    out.insert("PERRS".into(), join_esc(&ps.errors));
    out.insert("LEXERR".into(), ps.lexer().errors.len().to_string());
    out.insert("LEXERRS".into(), join_esc(&ps.lexer().errors));
    out
}

#[allow(dead_code)]
pub type Rec = BTreeMap<String, String>;
