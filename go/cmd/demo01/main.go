// Demo 01：Quick-start —— 编译一段 Stope 源码，再把它跑起来。
//
// 1. 编译：Lexer / Parser / Compiler / Program —— 编译器接口，Program 有明确的
//    编码契约，宿主可以依赖（也可以照抄）。
// 2. 执行：stope/basicvm —— 内置的基础虚拟机，不属于标准。
//
// 运行：go run ./cmd/demo01
package main

import (
	"fmt"
	"os"

	"stope"
	"stope/basicvm"
)

const src = `
// example: sum all arguments

let result = 0.0;
let i = 0;
while i < argc {
  result = result + args[i];
  i = i + 1;
}

fmt:println("结果为: ", result);
return result;
`

// myArgs 实参表：源码里的 args[i] / argc 都落到它身上。
type myArgs struct{ data []basicvm.Value }

func (a *myArgs) At(s *basicvm.State, key basicvm.Value) basicvm.Value {
	idx, ok := key.(int64)
	if !ok || idx < 0 || int(idx) >= len(a.data) {
		s.Error("argument out of range. ")
		return nil
	}
	return a.data[idx]
}
func (a *myArgs) Num() int { return len(a.data) }

// fmtV 浮点按 %g 打印（15.0 -> "15"），与库里的 FmtG 一致。
func fmtV(v basicvm.Value) string {
	if f, ok := v.(float64); ok {
		return stope.FmtG(f)
	}
	if v == nil {
		return "null"
	}
	switch x := v.(type) {
	case int64:
		return fmt.Sprintf("%d", x)
	case string:
		return x
	}
	return fmt.Sprint(v)
}

func printlnFunc(argv []basicvm.Value) basicvm.Value {
	// 宿主函数。签名统一是 func(argv []Value) Value：参数整包进来，自己拆。
	// 函数本身就是值 —— 塞进变量槽，Call 指令就能调到它。
	out := "[Host] "
	for _, a := range argv {
		out += fmtV(a)
	}
	fmt.Println(out)
	return nil
}

func main() {
	// ---------------- 1. 编译：源码 -> Program ----------------
	lexer := stope.NewLexer(src)
	parser := stope.NewParser(lexer, nil) // 第二参是 CustomOpcodeConfig，这里没有自定义指令
	tree := &stope.Prog{}
	parser.ParseProgram(tree)

	compiler := stope.NewCompiler(nil)
	program := stope.NewProgram()
	if compiler.Compile(tree, program, nil) != stope.RSuccess {
		// 三个环节都不抛异常，错误各自攒在 .Errors 里；编译失败时 program 已被清空
		var all []string
		all = append(all, lexer.Errors...)
		all = append(all, parser.Errors...)
		all = append(all, compiler.Errors...)
		fmt.Fprintln(os.Stderr, stringsJoin(all, "\n"))
		os.Exit(1)
	}

	fmt.Println(stope.DisasmNoCustom(program)) // 看一眼编出来的字节码

	// ---------------- 2. 执行：Program -> 结果 ----------------
	// 从这里开始是内置的基础虚拟机，不属于标准；换一个执行器，这段可以整个换掉。
	state := &basicvm.State{}
	state.SetApi(basicvm.NewApi())
	state.SetProgram(program)
	state.SetArguments(&myArgs{data: []basicvm.Value{1.0, 2.0, 3.0, 4.0, 5.0}})

	// 未声明的 fmt:println 被编译器当作外部变量登记进 exports；
	// 按名字取到槽位，填上宿主函数即可。
	idx, _ := program.ExportOf("fmt:println")
	state.Variables[idx] = basicvm.HostFunction(printlnFunc)

	if state.Run() != stope.RSuccess {
		fmt.Fprintln(os.Stderr, stringsJoin(state.Errors, "\n"))
		os.Exit(1)
	}
	fmt.Println("result: " + fmtV(state.Returns[0]))
}

func stringsJoin(ss []string, sep string) string {
	out := ""
	for i, s := range ss {
		if i > 0 {
			out += sep
		}
		out += s
	}
	return out
}
