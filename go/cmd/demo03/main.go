// Demo 03：自定义指令 —— 登记几条自己的指令，编译并反汇编。
//
// 项目只规定 33 条内置指令和 Program 的编码契约；再往上加是宿主自己的事，三步：
//  1. 用 CustomOpcodeConfig 登记「名字 -> (编号, 参数个数)」；
//  2. 同一份 config 同时交给 Parser 和 Compiler；
//  3. 产物里就只是一串 number —— 编号什么含义、谁来执行，全由宿主决定。
//
// 本 demo 不运行程序：自定义指令在 stope/basicvm 里没有实现，也不该有。
//
// 运行：go run ./cmd/demo03
package main

import (
	"fmt"
	"os"
	"strings"

	"stope"
)

const src = `
let x = 3;

my:add(x, 4);        // 定长 2 参
my:log("x =", x);    // 变长 2 参
my:log();            // 变长 0 参
my:halt();           // 定长 0 参

return x;
`

// compileSrc 编译一份源码，返回 (program, 错误列表)。config 可空。
func compileSrc(src string, config *stope.CustomOpcodeConfig) (*stope.Program, []string) {
	lexer := stope.NewLexer(src)
	parser := stope.NewParser(lexer, config)
	tree := &stope.Prog{}
	parser.ParseProgram(tree)

	program := stope.NewProgram()
	compiler := stope.NewCompiler(config) // 配置只在构造时注入一次
	compiler.Compile(tree, program, nil)
	var errs []string
	errs = append(errs, lexer.Errors...)
	errs = append(errs, parser.Errors...)
	errs = append(errs, compiler.Errors...)
	return program, errs
}

func main() {
	// ---------------- 1. 登记 ----------------
	// argNum >= 0 定长；< 0（默认 -1）变长，产物里会多写一个「本次调用的参数个数」。
	config := stope.NewCustomOpcodeConfig()
	fmt.Println("[1] 登记自定义指令：")
	config.AddCustomOpcode("my:add", stope.KFirstCustomOpcode+0, 2)
	config.AddCustomOpcode("my:log", stope.KFirstCustomOpcode+1, -1)
	config.AddCustomOpcode("my:halt", stope.KFirstCustomOpcode+2, 0)
	for _, name := range config.Order { // Order 是登记序
		info := config.Opcodes[name]
		kind := "变长"
		if !info.IsVarArg {
			kind = fmt.Sprintf("定长 %d 参", info.ArgNum)
		}
		fmt.Printf("  %s -> #%d（%s）\n", name, info.Opcode, kind)
	}

	// ---------------- 2. 编译 + 反汇编 ----------------
	// 反汇编要认出这些指令，必须拿到同一份 config（否则只能印 Custom#编号）。
	program, errors := compileSrc(src, config)
	fmt.Println("\n[2] 编译结果：")
	if len(errors) > 0 {
		fmt.Fprintln(os.Stderr, strings.Join(errors, "\n"))
		os.Exit(1)
	}
	fmt.Println(stope.Disasm(program, config))

	// ---------------- 3. 对照：名字没登记就只是普通调用 ----------------
	// 词法器只有在 config 里查得到名字时才吐 Custom token，否则 "my:add" 就是个普通
	// 标识符 —— 编译成 Call，即「调用一个名叫 my:add 的宿主函数」。
	plain, _ := compileSrc("my:add(1, 2);", nil)
	fmt.Println("\n[3] 同样的调用，不传 config：")
	fmt.Println(stope.DisasmNoCustom(plain))

	// ---------------- 4. 参数个数不符 ----------------
	// 定长指令的参数量在编译期校验；报错后 Compile 会把 program 复原为空。
	bad, errors := compileSrc("my:add(1);", config)
	fmt.Println("\n[4] 定长 2 参却只给 1 个：")
	fmt.Println("  " + strings.Join(errors, "\n  "))
	fmt.Printf("  -> 编译失败，Program 已清空（opcodes 剩 %d 个 number）\n", len(bad.Opcodes))

	// ---------------- 5. 陷阱：编号撞到内置指令 ----------------
	// 编号必须 >= KFirstCustomOpcode，否则与内置指令无法区分：编译器写出的仍是同一个
	// number，Disasm 只能按内置指令解码，并把它报成 warning。
	collide := stope.NewCustomOpcodeConfig()
	collide.AddCustomOpcode("my:steal", int(stope.OpAdd), 2)
	stolen, _ := compileSrc("my:steal(1, 2);", collide)
	fmt.Println("\n[5] 用内置 Add 的编号注册 my:steal：")
	fmt.Println(stope.Disasm(stolen, collide))
	fmt.Println("  -> 反汇编只认得出 Add：my:steal 这个名字已经丢了。")
}
