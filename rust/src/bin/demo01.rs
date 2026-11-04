//! Quick-start demo：编译一段 Stope 源码，再把它跑起来。
//!
//! Stope 只规定三件事：语言、STML、编译产物 `Program`，**不规定虚拟机**。所以下面
//! 两个阶段性质不同：编译是接口，执行走内置的 `basic_vm`（不是标准）。
//!
//! 运行：cargo run --bin demo01

use std::rc::Rc;
use stope::{
    disasm, fmt_g, Api, Arguments, Compiler, Parser, Prog, Program, Result as StopeResult, State,
    Value,
};

const SRC: &str = "
// example: sum all arguments

let result = 0.0;
let i = 0;
while i < argc {
  result = result + args[i];
  i = i + 1;
}

fmt:println(\"结果为: \", result);
return result;
";

/// 实参表：源码里的 `args[i]` / `argc` 都落到它身上。
struct MyArgs {
    data: Vec<Value>,
}

impl Arguments for MyArgs {
    fn at(&self, state: &mut State, index_or_key: &Value) -> Value {
        match index_or_key {
            Value::Int(i) if *i >= 0 && (*i as usize) < self.data.len() => {
                self.data[*i as usize].clone()
            }
            _ => {
                // 真取不到时：先 state.error("...") 再返回 Null
                state.error("argument out of range. ");
                Value::Null
            }
        }
    }
    fn num(&self) -> i64 {
        self.data.len() as i64
    }
}

/// 浮点按 `%g` 打印（15.0 -> "15"），与库里的 `fmt_g` 一致。
fn fmt(v: &Value) -> String {
    match v {
        Value::Null => "null".to_string(),
        Value::Float(f) => fmt_g(*f),
        Value::Int(i) => i.to_string(),
        Value::Str(u) => String::from_utf16(u).unwrap_or_default(),
        _ => "<other>".to_string(),
    }
}

/// 宿主函数。签名统一是 `fn(&mut State, &[Value]) -> Value`：参数整包进来，自己拆。
/// 函数本身就是值 —— 塞进变量槽，`Call` 指令就能调到它。
fn println_host(_state: &mut State, argv: &[Value]) -> Value {
    let mut s = String::new();
    for a in argv {
        s.push_str(&fmt(a));
    }
    println!("[Host] {}", s);
    Value::Null
}

fn main() {
    // ---------------- 1. 编译：源码 -> Program ----------------
    let mut parser = Parser::new(SRC, None); // 第二参是 CustomOpcodeConfig，这里没有自定义指令
    let mut tree = Prog::default();
    parser.parse_program(&mut tree);

    let mut compiler = Compiler::new(None);
    let mut program = Program::new();
    if compiler.compile(&tree, &mut program, &[]) != StopeResult::Success {
        // 三个环节都不抛异常，错误各自攒在 errors 里；编译失败时 program 已被清空
        let mut errs: Vec<String> = parser.lexer().errors.clone();
        errs.extend(parser.errors.clone());
        errs.extend(compiler.errors.clone());
        eprintln!("{}", errs.join("\n"));
        std::process::exit(1);
    }

    print!("{}", disasm(&program, None)); // 看一眼编出来的字节码（文本自带尾换行）
    println!();

    // ---------------- 2. 执行：Program -> 结果 ----------------
    // 从这里开始是内置的基础虚拟机，不属于标准；换一个执行器，这段可以整个换掉。
    let program = Rc::new(program);
    let mut state = State::new();
    state.reset(
        Rc::new(Api::new()),
        program.clone(),
        Some(Rc::new(MyArgs {
            data: vec![
                Value::Float(1.0),
                Value::Float(2.0),
                Value::Float(3.0),
                Value::Float(4.0),
                Value::Float(5.0),
            ],
        })),
    );

    // 未声明的 fmt:println 被编译器当作外部变量登记进 exports；
    // 按名字取到槽位，填上宿主函数即可。
    let slot = *program.exports.get("fmt:println").unwrap() as usize;
    state.variables[slot] = Value::HostFunction(Rc::new(println_host));

    if state.run() != StopeResult::Success {
        eprintln!("{}", state.errors.join("\n"));
        std::process::exit(1);
    }
    println!("result: {}", fmt(&state.returns[0]));
}
