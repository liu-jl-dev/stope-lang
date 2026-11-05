// Demo 05: 宿主侧的面向对象 —— 对应 cpp/demo/05-object/。
//
// 多文件拆分与 C++ 参考实现同构（demo/05-object/ 目录）：
//   object.js（对象模型）、classes.js（类/方法/函数）、object_manager.js
//   （obj:* 域行为）、runtime.js（装配与调用）、doc_visitor.js（STML -> 类与
//   函数）、api.js（Handle 三开口转发）；本文件只留文档、装配与入口。
//   设计推导见 cpp/docs/object-oriented.md，JS 侧差异见 docs/object-oriented.md。
//
// 运行：node demo/05-object.js
//
// Stope 的值世界里没有对象：类、属性、方法、构造、析构全部长在宿主侧。
// 语言/编译器零改动，BasicVM 只认 Handle（宿主引用）——At 读 / Assign 写 /
// Call 调三个动作经 Api 的 handleAt / handleAssign / handleCall 虚方法转交
// ObjectManager。
//
// ★ JS 侧的内存管理（与 C++ demo 的差异，详见 docs/object-oriented.md）：
//   · JS 引擎是**追踪式 GC**（标记清除 + 分代），对象**无法手动释放**；
//   · 「手动管理」因此模拟为：删除标记（deleted）+ 使用检测（用后即报
//     use after free，而不是 C++ 的悬空 UB）；
//   · **析构函数的有效性不受影响**：<delete> 只在显式 obj:delete 时运行，
//     时机确定；对象内存的真正回收时机交由 GC——不可达之后由引擎决定；
//   · 描述符同样交给 GC：驱逐缓存后不可达即回收，不需要 C++ 的 freeDescs
//     复用池；bindCache 用两级 Map（对象 -> (成员 id -> 描述符)），驱逐是
//     O(1) 整组摘除。

import {
  BasicVM,
  Result,
  StmlElement,
  StmlLexer,
  StmlParser,
  StmlState,
} from '../src/index.js'
import { DocVisitor } from './05-object/doc_visitor.js'
import { Runtime } from './05-object/runtime.js'

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

// ==================== 入口 ====================

function main() {
  const runtime = new Runtime()
  runtime.addHostFunction('println', hostPrintln)

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

  // ---------- 3. 装配主 State：绑定归 Runtime.bindEntry ----------
  const state = new BasicVM.State()
  state.SetApi(runtime.api)
  state.SetProgram(mainFunc.program)
  runtime.bindEntry(state, mainFunc)

  // ---------- 4. 运行 + 手动清理诊断 ----------
  if (state.Run() !== Result.Success) {
    for (const e of state.errors) console.log('  vm: ' + e)
  }
  runtime.objMgr.reportLive() // 忘了 obj:delete 的对象在这里现形
  if (state.errors.length > 0) process.exitCode = 1
}

// 宿主函数：与 C++ demo 一致——只格式化 Integer / Float / String，其余忽略。
// JS 宿主函数就是栈上的一个值，签名 fn(argv)（参数整包传入）。
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
