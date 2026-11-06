// Demo 06: 宿主侧的垃圾回收 —— 对应 cpp/demo/06-gc/。
//
// 多文件拆分与 C++ 参考实现同构（demo/06-gc/ 目录）：
//   object.js（gc 节点 + 描述符）、gc.js（分配器：链表/计数/同步/标记清除）、
//   object_manager.js（obj:* 域行为 + 安全点）、runtime.js（装配与调用 +
//   liveStates）、doc_visitor.js（STML -> 类与函数）、api.js（三开口转发）；
//   本文件只留文档、装配与入口。
//   设计推导见 cpp/docs/gc.md，JS 侧差异见 docs/gc.md。
//
// 语法（与 cpp demo 逐字一致）：
//   Person:New("Tom", 18)     构造（对象生命期归 gc，无 obj:delete）
//   obj:friend[p] = null      字段覆盖：计数归零 -> 立即级联
//   gc:Collect()              宿主函数：强制标记清除
//
// ★ JS 侧的内存管理（与 C++ demo 的差异，详见 docs/gc.md）：
//   · gc 决定「何时判死」：<delete> 在判死时运行、时机确定；节点摘链后
//     不可达，JS 内存由引擎回收——没有 C++ 的 delete/trash（对象不会地址
//     复用，悬空指针不存在）；
//   · 描述符交给引擎 GC：Bind 每次新建，不可达即回收，不需要 Pin；
//   · 「正在执行方法」的对象由 runtime.pinned 强引用保活（JS 描述符不参与
//     gc，C++ 靠绑定描述符的字段引用，这里是等价物）；
//   · maxNodes 只计业务对象（描述符由引擎管）。

import {
  BasicVM,
  Result,
  StmlElement,
  StmlLexer,
  StmlParser,
  StmlState,
} from '../src/index.js'
import { DocVisitor } from './06-gc/doc_visitor.js'
import { Runtime } from './06-gc/runtime.js'

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

  // 1) 引用计数级联：朋友只挂在字段上，覆盖成 null 旧值计数归零，
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

function main() {
  const runtime = new Runtime()
  runtime.objMgr.alloc.maxNodes = 4096 // gc 节点上限（JS 只计业务对象）；
  // 顶到上限先 Collect 仍不够则开口报 too many gc nodes.；0 = 不限
  runtime.addHostFunction('println', hostPrintln)
  // 注意没有 gc:Collect：宿主本来就能直接调 collect()，注册成 VM 宿主函数
  // 只是让脚本能「主动要求 gc」——去掉之后模块级桥接（runtimeRef）也跟着
  // 删，gc 时机完全归帧循环（下方的 slices % 25 === 0）。

  // ---------- 1. STML 解析：代码段标签按 Stope 代码扫 ----------
  const lexer = new StmlLexer(doc)
  const stmlParser = new StmlParser(lexer)
  const root = new StmlElement()
  if (stmlParser.Parse(root, stateFunc) !== Result.Success) {
    for (const e of stmlParser.errors) console.log(e)
    process.exitCode = 1
    return
  }

  // ---------- 2. 访问文档：构建类、编译函数 ----------
  const visitor = new DocVisitor()
  let mainFunc = null
  try {
    visitor.visitDoc(root, runtime)
    mainFunc = runtime.findFunction('main')
  } catch (e) {
    console.log(e.message)
    process.exitCode = 1
    return
  }
  if (mainFunc === null) {
    console.log('no main function')
    process.exitCode = 1
    return
  }

  // ---------- 3. 装配入口帧：绑定归 Runtime.pushEntryFrame ----------
  runtime.pushEntryFrame(mainFunc)

  // ---------- 4. 运行：两种驱动，随时可切 + 帧边界 collect ----------
  // 限步：runSteps(20) 每帧最多 20 条指令，帧间就是宿主的逻辑帧；每 25 帧
  //   做一次标记清除——gc 时机完全由这个循环决定，脚本侧无感。单步调试
  //   就把 20 改成 1。
  // 直接：runAll() 一口气跑到帧栈清空——没有帧边界，gc 的裁决点只剩
  //   maxNodes 顶满与收尾那次 collect。demo 先限步 25 帧（第一轮帧边界
  //   Collect 在这里触发，循环引用被破环），再直接执行跑完剩下的。
  let slices = 0
  while (slices < 25 && runtime.runSteps(20)) {
    ++slices
    if (slices % 25 === 0) {
      runtime.objMgr.alloc.collect()
      console.log(`[gc] frame slice ${slices}: collect freed ${runtime.objMgr.alloc.lastFreed}`)
    }
  }
  runtime.runAll()
  console.log(`-- ${slices} stepped slice(s), 20 steps each, then RunAll --`)
  runtime.objMgr.alloc.collect() // 入口帧弹出后 p 不可达：最后一次收集
  runtime.objMgr.reportLive() // 帧栈已空，根集合随最后一步同步清零
  runtime.objMgr.alloc.disposeAll() // 退出兜底：剩余对象逐个跑 <delete>
  if (runtime.hadErrors) process.exitCode = 1
}

// 宿主函数：与 C++ demo 一致——只格式化 Integer / Float / String，其余忽略。
function hostPrintln(args) {
  let out = ''
  for (const a of args) {
    if (typeof a === 'bigint') out += a.toString()
    else if (typeof a === 'number') out += formatFloat(a)
    else if (typeof a === 'string') out += a
  }
  console.log(out)
  return null
}

// gc:Collect 已删：宿主本来就能直接调 collect()，注册成 VM 宿主函数只是
// 让脚本能「主动要求 gc」——裁决时机现在完全归 main() 的帧循环。

// 浮点按 C++ iostream 默认精度（6 位有效数字）的样子打，读起来对得上
function formatFloat(v) {
  if (Number.isInteger(v) && Math.abs(v) < 1e15) return String(v)
  return String(Number(v.toPrecision(6)))
}

// 带 stope 属性的元素，内容按 Stope 代码扫；其余按子元素列表（Xml）解析。
function stateFunc(tag, attrs) {
  return tag === 'method' || tag === 'new' || tag === 'delete' || tag === 'func'
    ? StmlState.Stope
    : StmlState.Xml
}

main()
