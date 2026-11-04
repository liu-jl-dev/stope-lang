//! 参考执行器：值语义 + 两条驱动路径。**没有 golden 数据**。
//!
//! 这一组锁两件事：
//! 1. **run 与 step 一致** —— 两条独立实现，连走的条数都一样；
//! 2. **与另外五份实现同一种答案** —— 算术 / 序列 / 真值 / 除零 / 回绕 / 相等。

use common::fmt_g;
use std::rc::Rc;
use stope::basic_vm::{equals, truely, Arguments, Api, State, Value};
use stope::common::Result as StopeResult;
use stope::opcode::{Opcode, K_FIRST_CUSTOM_OPCODE};
use stope::{Compiler, CustomOpcodeConfig, Parser, Prog, Program};

mod common;

// ============================== 夹具 ==============================

/// 这组用例都不用 args / argc；真被取到就报错，立刻暴露「用例写错了」。
struct NoArgs;
impl Arguments for NoArgs {
    fn at(&self, state: &mut State, _key: &Value) -> Value {
        state.error("args not provided in this test. ");
        Value::Null
    }
    fn num(&self) -> i64 {
        0
    }
}

struct ArrayArgs {
    data: Vec<Value>,
}
impl Arguments for ArrayArgs {
    fn at(&self, state: &mut State, key: &Value) -> Value {
        match key {
            Value::Int(i) if *i >= 0 && (*i as usize) < self.data.len() => {
                self.data[*i as usize].clone()
            }
            _ => {
                state.error("argument out of range. ");
                Value::Null
            }
        }
    }
    fn num(&self) -> i64 {
        self.data.len() as i64
    }
}

/// 编译；成功返回 (Program, [])，失败返回 (None, 错误列表)。
fn compile(src: &str, custom: Option<Rc<CustomOpcodeConfig>>) -> (Option<Program>, Vec<String>) {
    let mut ps = Parser::new(src, custom.clone());
    let mut tree = Prog::default();
    ps.parse_program(&mut tree);
    let mut prog = Program::new();
    let mut c = Compiler::new(custom);
    c.compile(&tree, &mut prog, &[]);
    let mut errs = ps.lexer().errors.clone();
    errs.extend(ps.errors.clone());
    errs.extend(c.errors.clone());
    if errs.is_empty() {
        (Some(prog), vec![])
    } else {
        (None, errs)
    }
}

fn state_with(prog: &Program, args: Option<Rc<dyn Arguments>>) -> State {
    let mut s = State::new();
    s.reset(Rc::new(Api::new()), Rc::new(prog.clone()), args);
    s
}

/// 编译并执行；失败返回 (None, 错误列表)。
fn build(src: &str, args: Option<Rc<dyn Arguments>>) -> (Option<State>, Vec<String>) {
    let (prog, errs) = compile(src, None);
    let Some(prog) = prog else { return (None, errs) };
    let mut s = state_with(&prog, args);
    s.run();
    (Some(s), vec![])
}

/// 紧凑写法：null / 整数 / 浮点（无小数点时补 .0）/ 字符串原样 / 字节数组 [1,2]。
fn fmt(v: &Value) -> String {
    match v {
        Value::Null => "null".to_string(),
        Value::Int(i) => i.to_string(),
        Value::Float(f) => {
            if f.is_nan() {
                "nan".to_string()
            } else if *f == f64::INFINITY {
                "inf".to_string()
            } else if *f == f64::NEG_INFINITY {
                "-inf".to_string()
            } else {
                let t = fmt_g(*f);
                if !t.contains('.') && !t.contains('e') {
                    format!("{}.0", t)
                } else {
                    t
                }
            }
        }
        Value::Str(u) => String::from_utf16(u).unwrap_or_default(),
        Value::BinArr(b) => format!("[{}]", b.iter().map(|x| x.to_string()).collect::<Vec<_>>().join(",")),
        Value::HostFunction(_) => "<other>".to_string(),
        Value::Identifier(_) => "<other>".to_string(),
    }
}

fn fmt_returns(s: &State) -> String {
    format!("[{}]", s.returns.iter().map(fmt).collect::<Vec<_>>().join(","))
}

/// `"3 Div: msg"` → `msg`：前缀（下标 + 指令名）由实现决定，跨实现只比消息。
fn msg_only(e: &str) -> &str {
    match e.find(": ") {
        Some(i) => &e[i + 2..],
        None => e,
    }
}

fn returns(src: &str, want: &str, cid: &str) {
    let (s, errs) = build(src, None);
    let Some(s) = s else {
        panic!("{}: 编译失败：{} | {}", cid, src, errs.concat());
    };
    assert_eq!(want, fmt_returns(&s), "{}: returns", cid);
    assert_eq!("", s.errors.join("|"), "{}: errors", cid);
}

fn errs(src: &str, want_msg: &str, cid: &str) {
    let (s, build_errs) = build(src, None);
    let Some(s) = s else {
        panic!("{}: 编译失败：{} | {}", cid, src, build_errs.concat());
    };
    assert_eq!(1, s.errors.len(), "{}: 错误条数", cid);
    assert_eq!(want_msg, msg_only(&s.errors[0]), "{}: 错误消息", cid);
}

fn inst_count(p: &Program) -> usize {
    // 产物里有几条指令（跳过操作数格）—— 与「走了几步」对照用
    let mut n = 0;
    let mut i = 0;
    let ops = &p.opcodes;
    while i < ops.len() {
        n += 1;
        i += if stope::opcode_has_arg(ops[i]) { 2 } else { 1 };
    }
    n
}

#[test]
fn vm_values() {
    // ==================== 布尔就是整数 1 / 0 ====================
    returns("return true;", "[1]", "V-06");
    returns("return false;", "[0]", "V-06b");
    returns("let t = true; let f = false; return t + f + (1 == 1);", "[2]", "V-06c");
    returns("let a = 1; let b = 2; return a < b;", "[1]", "V-06d");

    // ==================== 整数幂：回绕 / 负指数转浮点 ====================
    returns("let a = 2; let b = 64; return a ^ b;", "[0]", "V-07");
    returns("let a = 2; return a ^ -1;", "[0.5]", "V-07b");
    // ⚠ 负底数 + 分数指数：C++ 是 nan
    returns("let a = -8.0; let b = 0.5; return a ^ b;", "[nan]", "V-07c");

    // ==================== 序列重复与拼接 ====================
    returns("let s = \"ab\"; return s * 2;", "[abab]", "V-08");
    returns("let s = \"ab\"; return 2 * s;", "[abab]", "V-08b");
    returns("let b = 'd 1 2'; return b * 2;", "[[1,2,1,2]]", "V-08c");
    errs(
        "let s = \"ab\"; let n = -1; return s * n;",
        "\"Mul\" cannot repeat a sequence by a negative number. ",
        "V-08d",
    );
    returns("let a = \"x\"; let b = \"y\"; return a + b;", "[xy]", "V-08e");
    returns("let a = 'd 1'; let b = 'd 2'; return a + b;", "[[1,2]]", "V-08f");
    errs(
        "let b = 'd 1'; let n = -2; return b * n;",
        "\"Mul\" cannot repeat a sequence by a negative number. ",
        "V-08g",
    );

    // ==================== 真值 ====================
    returns("let s = \"\"; if s { return 1; } return 2;", "[2]", "V-09");
    returns("let s = \"x\"; if s { return 1; } return 2;", "[1]", "V-09b");
    returns("let b = 'd'; if b { return 1; } return 2;", "[2]", "V-09c");

    // ==================== 除零 ====================
    errs("let a = 1; let b = 0; return a / b;", "\"Div\" division by zero. ", "V-10");
    errs("let a = 1; let b = 0; return a idiv b;", "\"IDiv\" division by zero. ", "V-10b");
    errs("let a = 1; let b = 0; return a % b;", "\"Mod\" division by zero. ", "V-10c");
    // 浮点除零走 IEEE，不报错
    returns("let a = 1.0; let b = 0; return a / b;", "[inf]", "V-10d");
    returns("let a = 0.0; let b = 0; return a / b;", "[nan]", "V-10e");
    returns("let a = 1.5; let b = 0; return a % b;", "[nan]", "V-10f");
    returns("let a = -7.0; let b = 2.0; return a % b;", "[-1.0]", "V-10g");

    // ==================== `!` 只接受 null / 整数 / 浮点 ====================
    errs("let s = \"abc\"; return !s;", "\"Not\" can only operate on integer or float. ", "V-11");

    // ==================== INT64_MIN 的三个角落（回绕必须有）====================
    returns("let m = 0 - 9223372036854775807 - 1; return -m;", "[-9223372036854775808]", "V-12");
    returns(
        "let m = 0 - 9223372036854775807 - 1; return m idiv -1;",
        "[-9223372036854775808]",
        "V-12b",
    );
    returns("let m = 0 - 9223372036854775807 - 1; return m % -1;", "[0]", "V-12c");

    // ==================== idiv：含浮点仍向零取整，但保持浮点 ====================
    returns("let a = 7; let b = 2; return a idiv b;", "[3]", "V-13");
    returns("let a = 7.5; let b = 2; return a idiv b;", "[3.0]", "V-13b");
    returns("let a = 1.0; let b = 0; return a idiv b;", "[inf]", "V-13c");

    // ==================== 相等：类型不同一律不等 ====================
    returns("let a = \"1\"; let b = 1; return a == b;", "[0]", "V-15");
    returns("let a = null; let b = 0; return a == b;", "[0]", "V-15b");
    returns("let a = 'd 1 2'; let b = 'd 1 2'; return a == b;", "[1]", "V-15c");
    returns("let a = 'd 1'; let b = 'd 2'; return a == b;", "[0]", "V-15d");
    returns("let a = \"ab\"; let n = 0; return a * n;", "[]", "V-15e");

    // ==================== 下标取码元 ====================
    returns("let b = 'd 1 2'; return b[1];", "[2]", "V-15f");
    // ⚠ 取的是 UTF-16 码元：非 BMP 字符（U+1F600）给出高位代理 55357
    returns("let s = \"\u{1F600}\"; return s[0];", "[55357]", "V-15g");
    errs("let b = 'd 1'; return b[5];", "index out of range. ", "V-15h");
}

#[test]
fn vm_host_functions() {
    // 宿主函数：一个值，直接放变量槽
    let (prog, build_errs) = compile("return f(1, 2);", None);
    let prog = prog.unwrap_or_else(|| panic!("V-14: 编译失败：{}", build_errs.concat()));
    let mut s = state_with(&prog, None);
    // 未声明就被调用 → 编译器隐式登记进 exports；槽位号由编译器分配，不能写死
    let slot = *prog.exports.get("f").unwrap() as usize;
    s.variables[slot] = Value::HostFunction(Rc::new(|_st, argv| match (&argv[0], &argv[1]) {
        (Value::Int(a), Value::Int(b)) => Value::Int(a.wrapping_add(*b)),
        _ => Value::Null,
    }));
    let rc = s.run();
    assert!(rc == StopeResult::Success, "V-14: run 返回");
    assert_eq!("[3]", fmt_returns(&s), "V-14: returns");

    // Call 到非函数
    let (s, _) = build("let x = 1; return x(2);", None);
    let s = s.expect("V-17: 编译失败");
    assert_eq!(1, s.errors.len(), "V-17: 错误条数");
    assert_eq!("\"Call\" can only call a function. ", msg_only(&s.errors[0]), "V-17: 错误消息");
}

#[test]
fn vm_arguments() {
    // argc + args[i]
    let (s, _) = build("return argc + args[0];", Some(Rc::new(ArrayArgs { data: vec![Value::Int(2)] })));
    let s = s.expect("V-18: 编译失败");
    assert_eq!("[3]", fmt_returns(&s), "V-18"); // argc(1) + args[0](2)

    // 没给实参表
    let (s, _) = build("return argc;", None);
    let s = s.expect("V-19: 编译失败");
    assert_eq!(1, s.errors.len(), "V-19: 错误条数");
    assert_eq!("no args. ", msg_only(&s.errors[0]), "V-19: 错误消息");

    // 实参表越界由宿主自己报错
    let (s, _) = build("return args[5];", Some(Rc::new(ArrayArgs { data: vec![Value::Int(1)] })));
    let s = s.expect("V-20: 编译失败");
    assert_eq!(1, s.errors.len(), "V-20: 错误条数");
    assert_eq!("argument out of range. ", msg_only(&s.errors[0]), "V-20: 错误消息");

    // 宿主 at() 里报错之后执行器必须停：错误进同一个 errors，且定位到 GetArg 那条
    let (prog, _) = compile("return args[0];", None);
    let prog = prog.expect("V-04: 编译失败");
    let mut opts = state_with(&prog, Some(Rc::new(NoArgs)));
    let rc = opts.run();
    assert!(rc == StopeResult::Error, "V-04: run 返回");
    assert_eq!(1, opts.errors.len(), "V-04: 错误条数");
    assert_eq!("args not provided in this test. ", msg_only(&opts.errors[0]), "V-04: 错误消息");
    assert!(
        opts.i < prog.opcodes.len() as isize
            && prog.opcodes[opts.i as usize] == Opcode::GetArg as i32,
        "V-04: 停机在 GetArg 上"
    );
}

#[test]
fn vm_error_index() {
    // 错误串前缀是 "<指令下标>: " —— 下标就是出错那条指令在产物里的位置。
    let (s, _) = build("return 1 / 0;", None);
    let s = s.expect("V-16: 编译失败");
    assert_eq!(1, s.errors.len(), "V-16: `return 1 / 0;` 应当恰好报一条错");
    // 产物是 PushInt(0) PushInt(1) Div Return(1) —— Div 在下标 4
    assert!(
        s.errors[0].starts_with("4: \"Div\" division by zero. "),
        "V-16: 错误串形如 \"4: ...\"：{}",
        s.errors[0]
    );
}

#[test]
fn vm_custom_opcode() {
    // 自定义指令（编号 >= 33）能跑、能报错，且 set_opcode 会把中间补齐。
    let mut cfg = CustomOpcodeConfig::new();
    cfg.add_custom_opcode("my:boom", K_FIRST_CUSTOM_OPCODE, 0);
    let cfg = Rc::new(cfg);
    let (prog, errs) = compile("my:boom();", Some(cfg.clone()));
    let prog = match prog {
        Some(p) => p,
        None => panic!("V-05: 编译失败：{}", errs.concat()),
    };

    fn boom(s: &mut State) {
        s.error("boom. ");
    }

    let mut api = Api::new();
    api.set_opcode(K_FIRST_CUSTOM_OPCODE, boom);
    let mut s = State::new();
    s.reset(Rc::new(api), Rc::new(prog), Some(Rc::new(NoArgs)));
    let rc = s.run();
    assert!(rc == StopeResult::Error, "V-05: run 返回");
    assert_eq!(1, s.errors.len(), "V-05: 错误条数");
    assert_eq!("0: boom. ", s.errors.join("|"), "V-05: 错误全文");

    // 跳号注册：33 是刚注册的，34/35 必须补成占位函数而不是留空
    let api2 = Api::new();
    assert_eq!(K_FIRST_CUSTOM_OPCODE as usize, api2.op_map.len(), "V-05b: 内置表长度");
    let mut api3 = Api::new();
    api3.set_opcode(K_FIRST_CUSTOM_OPCODE + 2, boom);
    assert_eq!((K_FIRST_CUSTOM_OPCODE + 3) as usize, api3.op_map.len(), "V-05b: 补齐后长度");
}

#[test]
fn vm_run_step_equivalence() {
    // `run` 与 `step` 是两份独立实现（热循环不套函数调用）。同一批程序跑两遍：
    // 返回值必须一致，顺序执行时**指令条数也必须一致**。
    let cases: [(&str, bool); 6] = [
        ("return 1 + 2 * 3;", true),
        ("let a = 1; while a < 5 { a = a + 1; } return a;", false),
        (
            "let s = 0; let i = 0; while i < 10 { if i % 2 == 0 { s = s + i; } i = i + 1; } return s;",
            false,
        ),
        ("let a = 1; let b = 2; return a < b and b < 3;", false),
        ("if 1 { return 10; } else { return 20; }", false),
        ("let x = 0; while { x = x + 1; if x > 3 { break; } } return x;", false),
    ];

    for (src, linear) in cases {
        let (prog, errs) = compile(src, None);
        let prog = match prog {
            Some(p) => p,
            None => panic!("V-21: 编译失败：{} | {}", src, errs.concat()),
        };

        let mut s1 = state_with(&prog, None);
        s1.run();

        let mut s2 = state_with(&prog, None);
        let mut steps = 0;
        while s2.i < prog.opcodes.len() as isize && s2.step() == StopeResult::Success {
            steps += 1;
            if steps > 100000 {
                break;
            }
        }

        assert_eq!(fmt_returns(&s1), fmt_returns(&s2), "V-21 {}: returns", src);
        assert_eq!(s1.errors.join("|"), s2.errors.join("|"), "V-21 {}: errors", src);
        assert!(s2.i >= prog.opcodes.len() as isize, "V-21 {}: step 应把指令流走完", src);
        assert_eq!(s1.i, s2.i, "V-21 {}: 停机时 i", src);
        if linear {
            assert_eq!(inst_count(&prog), steps, "V-21 {}: 步数应等于指令条数", src);
        }

        // 停机后再驱动一次：不执行指令、不追加错误（结束态与错误态都应如此）
        let err_before = s2.errors.len();
        let i_before = s2.i;
        let again = s2.step();
        assert!(again == StopeResult::Success, "V-21 {}: 停机后 step 返回 Success", src);
        assert_eq!(i_before, s2.i, "V-21 {}: 停机后 i 不变", src);
        assert_eq!(err_before, s2.errors.len(), "V-21 {}: 停机后 errors 不变", src);
    }
}

#[test]
fn vm_semantics_helpers() {
    // 真值 / 相等的直接单测（补齐 V 系列没覆盖到的分支）
    assert!(!truely(&Value::Null));
    assert!(truely(&Value::Int(1)));
    assert!(!truely(&Value::Int(0)));
    assert!(!truely(&Value::Float(0.0)));
    assert!(truely(&Value::Float(0.5)));
    assert!(truely(&Value::str_from_utf8("x")));
    assert!(!truely(&Value::str_from_utf8("")));
    assert!(truely(&Value::BinArr(Rc::new(vec![1]))));
    assert!(!truely(&Value::BinArr(Rc::new(vec![]))));

    assert!(equals(&Value::Null, &Value::Null));
    assert!(!equals(&Value::Null, &Value::Int(0)));
    assert!(equals(&Value::Int(1), &Value::Float(1.0)));
    assert!(equals(&Value::Float(1.0), &Value::Int(1)));
    assert!(!equals(&Value::Int(1), &Value::Float(1.5)));
    assert!(!equals(&Value::Float(1.5), &Value::Int(1)));
    assert!(equals(&Value::str_from_utf8("ab"), &Value::str_from_utf8("ab")));
    assert!(!equals(&Value::str_from_utf8("ab"), &Value::Int(0)));
    assert!(equals(&Value::BinArr(Rc::new(vec![1, 2])), &Value::BinArr(Rc::new(vec![1, 2]))));
    assert!(!equals(&Value::BinArr(Rc::new(vec![1])), &Value::BinArr(Rc::new(vec![2]))));
    // 溢出回绕的等值
    assert!(equals(&Value::Int(i64::MIN), &Value::Int(i64::MIN)));
}
