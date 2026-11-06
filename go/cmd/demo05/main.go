// Demo 05：宿主侧的面向对象 —— 对应 cpp/demo/05-object/。
//
// 多文件拆分与 C++ 参考实现同构：object.go（对象模型）、class.go（类/方法/
// 函数）、object_manager.go（obj:* 域行为）、runtime.go（装配与调用）、
// doc_visitor.go（STML -> 类与函数）、api.go（Handle 三开口转发）；本文件只留
// 文档、装配与入口。设计推导见 cpp/docs/object-oriented.md，Go 侧差异见
// docs/object-oriented.md。
//
// Stope 的值世界里没有对象：类、属性、方法、构造、析构全部长在宿主侧。
// 语言/编译器零改动，BasicVM 只认 Handle（宿主引用）——At 读 / Assign 写 /
// Call 调三个动作经 Api 接口的 HandleAt / HandleAssign / HandleCall 方法转交
// ObjectManager。
//
// ★ Go 侧的内存管理（与 C++ demo 的差异，详见 docs/object-oriented.md）：
//
//	· Go 是**并发三色标记清除 GC**，对象无法手动释放；
//	· 「手动管理」模拟为：删除标记（deleted）+ 使用检测（用后即报
//	  use after free，而不是 C++ 的悬空 UB）；
//	· **析构函数的有效性不受影响**：<delete> 只在显式 obj:delete 时运行，
//	  时机确定；对象内存的真正回收交由 GC——不可达之后由并发收集器决定；
//	· 描述符同样交给 GC：驱逐缓存后不可达即回收，不需要 C++ 的 freeDescs
//	  复用池；bindCache 用两级 map（对象 -> map[成员 id]描述符），键是
//	  指针（同一性），驱逐是 O(1) 整组摘除。
//
// 运行：go run ./cmd/demo05
package main

import (
	"fmt"
	"os"
	"strings"

	"stope/basicvm"
	"stope/stml"
)

const doc = `
<stml>

<class name="Person">
  <property name="name" />
  <property name="age" />
  <method name="Greet">
    println("i am ", self:name, ", ", self:age, " years old.");
  </method>
  <method name="Age">
    return self:age;
  </method>
  <method name="Introduce">
    // self:<方法名>() 调用同对象的另一个方法，无需 [对象]：self 绑定
    println("-- introducing --");
    self:Greet();
    println("age via self:Age() = ", self:Age());
  </method>
  <new name="New" params="name age">
    self:name = name;
    self:age = age;
  </new>
  <delete>
    // 析构函数，可以用来清理宿主的非托管资源等
    println("[Person] deleted!");
  </delete>
</class>

<func name="main">
  let p = Person:New("Tom", 18);
  obj:name[p] = "James";
  obj:Introduce[p]();
  obj:delete(p);
</func>

</stml>
`

// hostPrintln 宿主函数：与 C++ demo 一致——只格式化 Integer / Float / String，
// 其余忽略。Go 宿主函数就是栈上的一个值，签名 fn(argv)（参数整包传入）。
func hostPrintln(argv []basicvm.Value) basicvm.Value {
	var sb strings.Builder
	for _, a := range argv {
		switch x := a.(type) {
		case int64:
			sb.WriteString(fmt.Sprintf("%d", x))
		case float64:
			sb.WriteString(strconvFormatFloat(x))
		case string:
			sb.WriteString(x)
		}
	}
	fmt.Println(sb.String())
	return nil
}

// strconvFormatFloat 浮点按 C++ iostream 默认精度（6 位有效数字）的样子打。
func strconvFormatFloat(v float64) string {
	if v == float64(int64(v)) && v < 1e15 && v > -1e15 {
		return fmt.Sprintf("%d", int64(v))
	}
	return fmt.Sprintf("%g", v)
}

// contentKind 带 stope 属性的元素，内容按 Stope 代码扫；其余按子元素列表解析。
func contentKind(tag string, _ map[string]string) stml.LexerState {
	if tag == "method" || tag == "new" || tag == "delete" || tag == "func" {
		return stml.StopeState
	}
	return stml.XmlState
}

func main() {
	runtime := newRuntime()
	runtime.objMgr.MaxObjects = 4096 // 存活对象上限：忘了 obj:delete 顶到上限时构造器直接报错
	runtime.addHostFunction("println", hostPrintln)

	// ---------- 1. STML 解析：代码段标签按 Stope 代码扫 ----------
	lexer := stml.NewLexer(doc, stml.XmlState)
	parser := stml.NewParser(lexer)
	root := stml.NewElement()
	if parser.Parse(root, contentKind) != stml.Success {
		for _, e := range parser.Errors {
			fmt.Println(e)
		}
		os.Exit(1)
	}

	// ---------- 2. 访问文档：构建类、编译函数 ----------
	visitor := &docVisitor{}
	var mainFunc *FunctionInfo
	func() {
		defer func() {
			if r := recover(); r != nil {
				fmt.Println(r)
				os.Exit(1)
			}
		}()
		visitor.visitDoc(root, runtime)
		mainFunc = runtime.findFunction("main")
	}()
	if mainFunc == nil {
		fmt.Println("no main function")
		os.Exit(1)
	}

	// ---------- 3. 装配入口帧：绑定归 Runtime.pushEntryFrame ----------
	runtime.pushEntryFrame(mainFunc)

	// ---------- 4. 运行：两种驱动，随时可切 + 手动清理诊断 ----------
	// 限步：runSteps(20) 每帧最多 20 条指令，帧间就是宿主的逻辑帧——方法
	//   调用压帧、返回弹帧，预算跨调用共享。单步调试就把 20 改成 1。
	// 直接：runAll() 一口气跑到帧栈清空。demo 先限步 1 帧（点出「每帧
	//   限步」是驱动方式而非程序属性），再直接执行跑完剩下的。
	slices := 0
	for slices < 1 && runtime.runSteps(20) {
		slices++
	}
	runtime.runAll()
	fmt.Printf("-- %d stepped slice(s), 20 steps each, then RunAll --\n", slices)
	runtime.objMgr.reportLive() // 忘了 obj:delete 的对象在这里现形
	if runtime.hadErrors {
		os.Exit(1)
	}
}
