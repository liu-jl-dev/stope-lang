// Demo 06：宿主侧的垃圾回收 —— 对应 cpp/demo/06-gc/。
//
// 多文件拆分与 C++ 参考实现同构：object.go（gc 节点）、gc.go（分配器：链表/
// 计数/同步/标记清除）、object_manager.go（obj:* 域行为 + 安全点）、
// runtime.go（装配与调用 + liveStates/pinned）、doc_visitor.go（STML -> 类
// 与函数）、api.go（Handle 三开口转发）；本文件只留文档、装配与入口。
// 设计推导见 cpp/docs/gc.md，Go 侧差异见 docs/gc.md。
//
// 语法（与 cpp demo 逐字一致）：
//
//	Person:New("Tom", 18)     构造（对象生命期归 gc，无 obj:delete）
//	obj:friend[p] = null      字段覆盖：计数归零 -> 立即级联
//	gc:Collect()              宿主函数：强制标记清除
//
// ★ Go 侧的内存管理（与 C++ demo 的差异，详见 docs/gc.md）：
//
//	· gc 决定「何时判死」：<delete> 在判死时运行、时机确定；节点摘链后
//	  不可达，内存交给 Go GC——没有 C++ 的 delete/trash（对象不会地址
//	  复用，悬空指针不存在）；
//	· 描述符交给 GC：bind 每次新建，不可达即回收，不需要 Pin；
//	· 「正在执行方法」的对象由 runtime.pinned 强引用保活（Go 描述符不参与
//	  gc，C++ 靠绑定描述符的字段引用，这里是等价物）；
//	· MaxNodes 只计业务对象（描述符由 GC 管）。
//
// 运行：go run ./cmd/demo06
package main

import (
	"fmt"
	"os"

	"stope/stml"
)

// doc STML 文档：类定义与主程序（三段剧情与 C++ demo 逐字一致）。
const doc = `
<stml>

<class name="Person">
  <property name="name" />
  <property name="age" />
  <property name="friend" />
  <property name="partner" />
  <method name="Greet">
    println("i am ", self:name, ", ", self:age, " years old.");
  </method>
  <method name="Age">
    return self:age;
  </method>
  <method name="Introduce">
    println("-- introducing --");
    self:Greet();
    println("age via self:Age() = ", self:Age());
  </method>
  <method name="BlockGuard">
    // 块内 let 的 guard 对象：块退出不产生任何指令——槽位归还编译器的
    // 复用池，但值还在 variables 里，gc 根扫描每次都扫得到。
    {
      let f = Person:New("block-guard", 1);
    }
    println("-- block exited: nothing freed, nothing printed --");
  </method>
  <method name="Pair">
    // 循环引用：a、b 互指，且只存在于本方法的变量里。方法一返回，两个
    // 变量槽位随栈帧销毁，引用计数停在 1 互相锁定——计数收不走，只能
    // 等标记清除裁决。
    let a = Person:New("cycle.a", 1);
    let b = Person:New("cycle.b", 2);
    obj:partner[a] = b;
    obj:partner[b] = a;
  </method>
  <new name="New" params="name age">
    self:name = name;
    self:age = age;
  </new>
  <delete>
    // 析构函数：gc 回收对象前自动跑，可以打遗言、清理宿主的非托管资源。
    println("[Person] deleted: ", self:name);
  </delete>
</class>

<func name="main">
  let p = Person:New("James", 18);
  obj:Introduce[p]();

  // 1) 引用计数级联：孩子只挂在字段上，覆盖成 null 旧值计数归零，
  //    立即析构（安全点刚同步过根，VM 侧再无 Handle，即时释放是可靠的）。
  obj:friend[p] = Person:New("Jimmy", 1);
  println("-- expect [Person] deleted: Jimmy right above --");
  obj:friend[p] = null;

  // 2) 循环引用：引用计数收不走，脚本侧也没有 gc 函数可调——裁决时机在
  //    宿主手里：驱动循环的帧边界 Collect（见 main），游戏里就是
  //    「每 N 帧收集一次」。
  obj:Pair[p]();
  println("-- expect nothing above: the pair is locked in a cycle --");
  println("-- expect two [Person] deleted above at a frame-boundary collect --");

  // 3) 垃圾 churn：丢弃结果的对象走引用计数路径，在下个安全点被逐个收走；
  //    一路积累的一次性描述符（self 绑定等）由帧边界的标记清除成批收走。
  let i = 0;
  while i < 100 {
    Person:New("garbage", i);
    i = i + 1;
  }
  println("-- expect batches of deleted above: safe-point refcount + frame-boundary sweep --");
</func>

</stml>
`

// hostPrintln 宿主函数：与 C++ demo 一致——只格式化 Integer / Float / String。
func hostPrintln(argv []any) any {
	var out string
	for _, a := range argv {
		switch v := a.(type) {
		case int64:
			out += fmt.Sprintf("%d", v)
		case float64:
			out += fmtFloat(v)
		case string:
			out += v
		}
	}
	fmt.Println(out)
	return nil
}

// gc:Collect 已删：宿主本来就能直接调 Collect()，注册成 VM 宿主函数只是让
// 脚本能「主动要求 gc」——裁决时机现在完全归 main() 的帧循环
// （runtimeRef 桥接变量也跟着删了）。

// fmtFloat 浮点按 C++ iostream 默认精度（6 位有效数字）的样子打。
func fmtFloat(v float64) string {
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
	runtime.objMgr.alloc.maxNodes = 4096 // gc 节点上限（Go 只计业务对象）；顶到
	// 上限先 Collect 仍不够则开口报 too many gc nodes.；0 = 不限
	runtime.addHostFunction("println", hostPrintln)
	// 注意没有 gc:Collect：宿主本来就能直接调 Collect()，注册成 VM 宿主函数
	// 只是让脚本能「主动要求 gc」——去掉之后桥接变量（runtimeRef）也跟着删，
	// gc 时机完全归帧循环（下方的 slices%25 == 0）。

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

	// ---------- 4. 运行：两种驱动，随时可切 + 帧边界 collect ----------
	// 限步：runSteps(20) 每帧最多 20 条指令，帧间就是宿主的逻辑帧；每 25
	//   帧做一次标记清除——gc 时机完全由这个循环决定，脚本侧无感。单步
	//   调试就把 20 改成 1。
	// 直接：runAll() 一口气跑到帧栈清空——没有帧边界，gc 的裁决点只剩
	//   maxNodes 顶满与收尾那次 Collect。demo 先限步 25 帧（第一轮帧边界
	//   Collect 在这里触发，循环引用被破环），再直接执行跑完剩下的。
	slices := 0
	for slices < 25 && runtime.runSteps(20) {
		slices++
		if slices%25 == 0 {
			runtime.objMgr.alloc.Collect()
			fmt.Printf("[gc] frame slice %d: collect freed %d\n", slices, runtime.objMgr.alloc.lastFreed)
		}
	}
	runtime.runAll()
	fmt.Printf("-- %d stepped slice(s), 20 steps each, then RunAll --\n", slices)
	runtime.objMgr.alloc.Collect()    // 入口帧弹出后 p 不可达：最后一次收集
	runtime.objMgr.reportLive()       // 帧栈已空，根集合随最后一步同步清零
	runtime.objMgr.alloc.DisposeAll() // 退出兜底：剩余对象逐个跑 <delete>
	if runtime.hadErrors {
		os.Exit(1)
	}
}
