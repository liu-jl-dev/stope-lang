# Stope Quick Start（Go 版）

## 安装

需要 Go 1.27 或更高版本（本仓库在 Go 1.27.3 上验证）。本实现零第三方依赖，
不需要 `go mod download`：

```bash
git clone <仓库地址>
cd stope-lang/go
go build ./...
```

## 最小示例：编译并执行一段 Stope 源码

```go
package main

import (
	"fmt"

	"stope"
	"stope/basicvm"
)

func main() {
	// 1. 词法 + 语法
	lexer := stope.NewLexer("let a = 40; return a + 2;")
	parser := stope.NewParser(lexer, nil)
	tree := &stope.Prog{}
	parser.ParseProgram(tree)

	// 2. 编译成 Program（指令流 + 常量池 + 变量表）
	program := stope.NewProgram()
	compiler := stope.NewCompiler(nil)
	if compiler.Compile(tree, program, nil) != stope.RSuccess {
		for _, e := range compiler.Errors {
			fmt.Println(e)
		}
		return
	}

	// 3. 用内置参考执行器跑（不是标准的一部分）
	state := &basicvm.State{}
	state.SetApi(basicvm.NewApi())
	state.SetProgram(program)
	state.Run()
	fmt.Println(state.Returns[0]) // 42
}
```

运行方式（本仓库内）：

```bash
cd go
mkdir -p cmd/hello && cp main.go cmd/hello/   # 上面的代码
go run ./cmd/hello                            # 输出 42
```

## 看一眼编译产物

```go
fmt.Println(stope.DisasmNoCustom(program))
```

输出形如：

```
[0]     PushId     0
[2]     PushInt    0
[4]     Assign     
[5]     PushValue  0
[7]     PushInt    1
[9]     Add        
[10]    Return     1
...
```

## 带实参执行

源码里的 `argc` / `args[i]` 落到宿主实现的 `basicvm.Arguments` 上：

```go
type myArgs struct{ data []basicvm.Value }

func (a *myArgs) At(s *basicvm.State, key basicvm.Value) basicvm.Value {
	return a.data[key.(int64)]
}
func (a *myArgs) Num() int { return len(a.data) }

state.SetApi(basicvm.NewApi())
state.SetProgram(program)
state.SetArguments(&myArgs{data: []basicvm.Value{int64(1), int64(2)}})
```

## 宿主函数

宿主函数是一个值，直接塞进变量槽（未声明就被调用的标识符会被编译器登记进
`Program.Exports`）：

```go
idx, _ := program.ExportOf("fmt:println")
state.Variables[idx] = basicvm.HostFunction(func(argv []basicvm.Value) basicvm.Value {
	fmt.Println(argv)
	return nil
})
```

## 更多

* STML 标记语言：见 `cmd/demo02` 与 [`stml.md`](stml.md)。
* 自定义指令：见 `cmd/demo03` 与 [`custom-opcode.md`](custom-opcode.md)。
* 预导出（preExports）：见 `cmd/demo04` 与 [`../docs/zh-cn/pre-export.md`](../docs/zh-cn/pre-export.md)。
* 宿主侧面向对象：见 `cmd/demo05` 与 [`object-oriented.md`](object-oriented.md)。
* 宿主侧垃圾回收：见 `cmd/demo06` 与 [`gc.md`](gc.md)。
* 语义细节以 C++ 为权威：[`../cpp/docs/`](../cpp/docs/)；语义契约与测试见 `../docs/zh-cn/`。
