// Demo 04：预导出（preExports）—— 宿主先把形参塞进作用域，再编译函数体。
//
// 场景：STML 文档里定义函数，参数表写在标签属性上（params="a b"），函数体是
// Stope 源码。编译函数体时把 params 里的名字当 preExports 传进去，它们就先占好槽位、
// 进 Program.Exports；宿主在 Run() 之前把实参写进这些槽位，函数体里的 a、b
// 直接就能读到。
//
// 运行：go run ./cmd/demo04
package main

import (
	"fmt"
	"os"
	"strings"

	"stope"
	"stope/basicvm"
	"stope/stml"
)

const doc = `
<stml>
<func name="add" params="a b" stope>
    return a + b;
</func>
</stml>
`

// contentKind 带 stope 属性的元素，内容按 Stope 代码扫；切出来的 text 就是原样源码。
func contentKind(tag string, attrs map[string]string) stml.LexerState {
	if _, ok := attrs["stope"]; ok {
		return stml.StopeState
	}
	return stml.XmlState
}

// childByName 按名字找子元素。
func childByName(ele *stml.Element, tag string) *stml.Element {
	for _, c := range ele.Children {
		if c.Tag == tag {
			return c
		}
	}
	return nil
}

// compileSrc 编译一段源码，preExports 原样交给 Compiler。失败时打印错误并返回 false。
//
// startLine 是 src 首行的物理行号 —— 从 STML 切出来的代码段不是从 1 开始，设给
// lexer 之后报错行号才和文档对得上（这里直接从 fn.TextLine 取）。
func compileSrc(src string, startLine int, preExports []string, out *stope.Program) bool {
	lexer := stope.NewLexer(src)
	lexer.Line = startLine
	parser := stope.NewParser(lexer, nil)
	tree := &stope.Prog{}
	parser.ParseProgram(tree)
	for _, e := range lexer.Errors {
		fmt.Println("  lexer: " + e)
	}
	for _, e := range parser.Errors {
		fmt.Println("  parser: " + e)
	}

	compiler := stope.NewCompiler(nil)
	rc := compiler.Compile(tree, out, preExports)
	for _, e := range compiler.Errors {
		fmt.Println("  compiler: " + e)
	}
	return rc == stope.RSuccess && len(lexer.Errors) == 0 && len(parser.Errors) == 0
}

func main() {
	// ---------------- 1. 从 STML 里取出函数定义 ----------------
	lexer := stml.NewLexer(doc, stml.XmlState)
	parser := stml.NewParser(lexer)
	root := stml.NewElement()
	if parser.Parse(root, contentKind) != stml.Success {
		var all []string
		all = append(all, lexer.Errors...)
		all = append(all, parser.Errors...)
		fmt.Fprintln(os.Stderr, strings.Join(all, "\n"))
		os.Exit(1)
	}

	fn := childByName(root, "func")
	name := fn.Attr("name")
	params := strings.Fields(fn.Attr("params")) // "a b" -> ["a", "b"]
	fmt.Printf("[1] 从 <func> 取出：%s(%s)\n", name, strings.Join(params, ", "))

	// ---------------- 2. 用参数表当 preExports 编译 ----------------
	// 形参先占槽位（a=0、b=1），函数体里的 a、b 于是解析到文件作用域 ——
	// 反汇编里是 PushValue(0) / PushValue(1)。
	program := stope.NewProgram()
	fmt.Println("\n[2] 编译函数体（preExports = 形参表）：")
	if !compileSrc(fn.Text, fn.TextLine, params, program) {
		os.Exit(1)
	}
	fmt.Println(stope.DisasmNoCustom(program))
	fmt.Print("  exports: ")
	for i, e := range program.Exports {
		if i > 0 {
			fmt.Print(" ")
		}
		fmt.Printf("%s=%d", e.Name, e.Index)
	}
	fmt.Println()

	// ---------------- 3. 塞实参、运行 ----------------
	// 编译期就知道槽位，所以 Run() 之前就能把值写进去 —— 这才是预导出的用处：
	// 宿主的「调用」就是写变量 + 跑一遍，不需要额外的参数传递机制。
	state := &basicvm.State{}
	state.Reset(basicvm.NewApi(), program, nil)
	aIdx, _ := program.ExportOf("a")
	bIdx, _ := program.ExportOf("b")
	state.Variables[aIdx] = int64(3)
	state.Variables[bIdx] = int64(4)

	state.Run()
	fmt.Printf("\n[3] add(3, 4) = %d\n", state.Returns[0].(int64))

	// ---------------- 4. 陷阱：预导出的名字不能再声明 ----------------
	// 名字已经进了文件作用域，源码里再 export 同名、或顶层 let 同名，都是 duplicate。
	// 预导出的变量只能赋值（a = 1;），不能重新声明。
	fmt.Println("\n[4] 函数体里又写 export a;：")
	compileSrc("export a; return a;", 1, params, stope.NewProgram())
}
