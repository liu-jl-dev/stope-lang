//! Demo 03：自定义指令 —— 登记几条自己的指令，编译并反汇编。
//!
//! 项目只规定 33 条内置指令和 `Program` 的编码契约；再往上加是宿主自己的事，三步：
//! 1. 用 `CustomOpcodeConfig` 登记「名字 -> (编号, 参数个数)」；
//! 2. **同一份 config 同时交给 Parser 和 Compiler**；
//! 3. 产物里就只是一串 number —— 编号什么含义、谁来执行，全由宿主决定。
//!
//! 本 demo 不运行程序：自定义指令在 `basic_vm` 里没有实现，也不该有。
//!
//! 运行：cargo run --bin demo03

use std::rc::Rc;
use stope::{
    disasm, Compiler, CustomOpcodeConfig, K_FIRST_CUSTOM_OPCODE, Opcode, Parser, Prog, Program,
};

const SRC: &str = "
let x = 3;

my:add(x, 4);        // 定长 2 参
my:log(\"x =\", x);    // 变长 2 参
my:log();            // 变长 0 参
my:halt();           // 定长 0 参

return x;
";

/// 编译一份源码，返回 `(program, 错误列表)`。`config` 可空。
fn compile_src(src: &str, config: Option<Rc<CustomOpcodeConfig>>) -> (Program, Vec<String>) {
    let mut parser = Parser::new(src, config.clone());
    let mut tree = Prog::default();
    parser.parse_program(&mut tree);

    let mut program = Program::new();
    let mut compiler = Compiler::new(config); // 配置只在构造时注入一次
    compiler.compile(&tree, &mut program, &[]);
    let mut errors = parser.lexer().errors.clone();
    errors.extend(parser.errors.clone());
    errors.extend(compiler.errors.clone());
    (program, errors)
}

fn main() {
    // ---------------- 1. 登记 ----------------
    // arg_num >= 0 定长；< 0（默认 -1）变长，产物里会多写一个「本次调用的参数个数」。
    let mut config = CustomOpcodeConfig::new();
    println!("[1] 登记自定义指令：");
    config.add_custom_opcode("my:add", K_FIRST_CUSTOM_OPCODE + 0, 2);
    config.add_custom_opcode("my:log", K_FIRST_CUSTOM_OPCODE + 1, -1);
    config.add_custom_opcode("my:halt", K_FIRST_CUSTOM_OPCODE + 2, 0);
    let config = Rc::new(config);
    for (name, info) in &config.opcodes {
        // 保持登记顺序
        let kind = if info.is_var_arg {
            "变长".to_string()
        } else {
            format!("定长 {} 参", info.arg_num)
        };
        println!("  {} -> #{}（{}）", name, info.opcode, kind);
    }

    // ---------------- 2. 编译 + 反汇编 ----------------
    // 反汇编要认出这些指令，必须拿到同一份 config（否则只能印 Custom#编号）。
    let (program, errors) = compile_src(SRC, Some(config.clone()));
    println!("\n[2] 编译结果：");
    if !errors.is_empty() {
        eprintln!("{}", errors.join("\n"));
        std::process::exit(1);
    }
    print!("{}", disasm(&program, Some(&config)));
    println!();

    // ---------------- 3. 对照：名字没登记就只是普通调用 ----------------
    // 词法器只有在 config 里查得到名字时才吐 Custom token，否则 "my:add" 就是个普通
    // 标识符 —— 编译成 Call，即「调用一个名叫 my:add 的宿主函数」。
    let (plain, _) = compile_src("my:add(1, 2);", None);
    println!("\n[3] 同样的调用，不传 config：");
    print!("{}", disasm(&plain, None));
    println!();

    // ---------------- 4. 参数个数不符 ----------------
    // 定长指令的参数量在编译期校验；报错后 compile() 会把 program 复原为空。
    let (bad, errors) = compile_src("my:add(1);", Some(config.clone()));
    println!("\n[4] 定长 2 参却只给 1 个：");
    println!("  {}", errors.join("\n  "));
    println!(
        "  -> 编译失败，Program 已清空（opcodes 剩 {} 个 number）",
        bad.opcodes.len()
    );

    // ---------------- 5. 陷阱：编号撞到内置指令 ----------------
    // 编号必须 >= K_FIRST_CUSTOM_OPCODE，否则与内置指令无法区分：编译器写出的仍是
    // 同一个 number，disasm() 只能按内置指令解码，并把它报成 warning。
    let mut collide = CustomOpcodeConfig::new();
    collide.add_custom_opcode("my:steal", Opcode::Add as i32, 2);
    let collide = Rc::new(collide);
    let (stolen, _) = compile_src("my:steal(1, 2);", Some(collide.clone()));
    println!("\n[5] 用内置 Add 的编号注册 my:steal：");
    print!("{}", disasm(&stolen, Some(&collide)));
    println!();
    println!("  -> 反汇编只认得出 Add：my:steal 这个名字已经丢了。");
}
