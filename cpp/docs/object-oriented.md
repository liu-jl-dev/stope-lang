# 面向对象：宿主侧的对象（demo 05）

> 本文与 `demo/05-object/` 是一份**面向对象编程范式**的参考实现，**不属于 Stope 标准**。演示如何在不改语言、不改编译器、
> **不改库源码**的前提下，把类、属性、方法、构造、析构**全部长在宿主侧**。正文按实现的先后顺序
> 逐步讲解——每一步做什么、为什么这样做、落在哪个文件。
>
> 相关知识：[`vm-guide.md`](../../docs/zh-cn/vm-guide.md)
> （BasicVM 的 Value / State / opcode）、[`stml.md`](stml.md)（STML 四态与回调）、
> [`custom-opcode.md`](custom-opcode.md)（宿主扩展的另一条路，与本文互补）。
>
> 一个重要的定位：Stope 的值世界里**没有对象**——六种可观测值没有记录，也没有
> 字段访问。所以「面向对象」不是语言特性，而是一份宿主侧的工程方案。本文实现
> 的对象**没有 GC**：要手动 `obj:delete`，忘了删会怎样、怎么现形，都是演示的
> 一部分（第 7 步）；demo 6 再把生命周期交给 GC。
>
> **维护承诺**：demo 5 / 6 有一定参考价值且较为繁琐，后续会持续**修 bug、
> 优化结构与可读性**；但**不修未定义行为与已知局限**——它们被如实记录在
> 第 10 节的清单里，参考本 demo 前请先读那份清单。

## 路线图

整个实现分七步，依赖关系自底向上：

| 步骤 | 做什么 | 落点 |
| --- | --- | --- |
| 1 | 认识 BasicVM 内建的 Handle 缝（**不改库源码**，覆写在第 4 步展开） | `basic_vm.hpp`（只读） |
| 2 | 定义宿主侧的对象模型 | `Object.*` |
| 3 | 用 STML 文档描述类并编译出方法 | `DocVisitor.*` / `Class.*` / `Function.*` |
| 4 | 实现 Handle 的三个开口 | `API.*` / `ObjectManager.*` |
| 5 | 设计描述符与绑定（`obj:*` / `<Class>:<New>`） | `ObjectManager.*` / `Runtime.cpp`（BindEntry，由 PushEntryFrame 调） |
| 6 | 接通 self 与字段的槽位契约 | `Runtime.*` |
| 7 | 手动生命周期（new / delete / 泄漏诊断） | `ObjectManager.cpp` |

先看目标效果——demo 文档的 main 函数体（也是教程要支撑的全部语法）：

```stope
let p = Person:New("Tom", 18);   // 构造
obj:name[p] = "James";           // 写属性
obj:Introduce[p]();              // 调方法：方法体内 self:Greet() 调同对象方法
obj:delete(p);                   // 手动删除（跑 <delete> 后回收内存）
```

## 1. 第一步：认识 BasicVM 内建的 Handle 缝

动手前先做缺口分析，结论是好消息：**编译器一行都不用改，库源码也不用改**。
`obj:name` 是一个合法标识符（词法器允许 `:` 进标识符，如 `fmt:println`），编译为
隐式导出变量；而 `a[k]=v` 本来就编译成 At + Assign，`f[k]()` 本来就编译成
At + Call——探测过编译产物，指令序列完全齐备。缺的只有一件事：**VM 遇到一种
新的值（对象引用）时，这三条指令该怎么执行**。

这件事库已经办好了。`basic_vm.hpp` 属于 Stope 发行库的一部分，随库分发——Handle
的缝内建其中。宿主侧要做的只是**继承 `BasicVM::API`
并覆写三个虚函数**（第 4 步展开实现体）。先弄清库里已经有什么，读头文件即可
确认：

**其一**，`Value::Type` 有 `Handle`，`data.data`（`uint64_t`）直接存宿主指针；
`equals` 对 Handle 做同一性比较——两个 Handle 相等当且仅当指针相同。

**其二**，`API` 内置三个**虚函数**。与 `PushId`（VM 槽位引用）对称：Handle 是
宿主引用，可 At 读、Assign 写、Call 调。VM 不解释它的含义，遇到 Handle 只把
值转发给这三个函数；不覆写时默认报错，语义与没有 Handle 的从前完全一致：

```cpp
// basic_vm.hpp
virtual void HandleAt(State& s, const Value& handle, const Value& key,
                      Value& out) {
  s.Error("no implement for container type. ");
}
virtual void HandleAssign(State& s, const Value& handle, const Value& value) {
  s.Error("no implement for value type. ");
}
virtual void HandleCall(State& s, const Value& handle, std::span<Value> args,
                        Value& out) { ... }
```

**其三**，`opAt` / `opAssign` / `opCall` 各有 Handle 分支——识别 Handle、
转发虚调用、检查 `HasError()`、维持栈纪律。以 `opAssign` 为例：

```cpp
// basic_vm.hpp，opAssign 里
if (s.AtTop(2).type == Value::Type::Handle) {  // 宿主引用：写回宿主
  a.HandleAssign(s, s.AtTop(2), s.stack.back());
  if (s.HasError())
    return;  // 错误时栈保持原样，与其它错误路径一致
  s.PopN(2);
  return;
}
```

**为什么虚函数能生效**：`API::opFuncs` 是 static 定长表、handler 全是 static
函数，但 handler 收 `API&`——static 函数体里的 `a.HandleXxx(...)` 走引用做虚
分发，子类覆写自然被调到。这是 C++ 侧「注册自定义行为」的缝，与其余语言实现
各自的扩展点（如 GD 侧 `Api.op_map` 的稠密 Callable 数组）互为对应。

注意 VM 对 Handle 的全部态度：**只存转、不解释**。算术与 At 的既有守卫拒绝
它，`Clear2` / `Copy` 对它无操作（无引用计数）——生命周期完全归宿主。这是
「手动管理」立场的根基，也是 demo 6 的 GC 将要替换的那一条。

库的测试锁定着默认行为：不覆写时遇到 Handle 即报错，与没有 Handle 的从前完全
一致。所以落到你手上的动作只有一件（demo 里就是 `API.hpp`）：

```cpp
struct API : Stope::BasicVM::API {
  void HandleAt(...) override;
  void HandleAssign(...) override;
  void HandleCall(...) override;
};
```

## 2. 第二步：定义宿主侧的对象模型

对象就是宿主堆上的一个 C++ 结构。Handle 与它之间的转换只有两个 helper：

```cpp
// Object.hpp
struct Object {
  int classId = -1;
  std::vector<Stope::BasicVM::Value> fields;  // 按下标对齐 Class::properties
};

Stope::BasicVM::Value ObjectToHandle(Object* p);   // 指针 -> Handle
Object* HandleToObject(const Stope::BasicVM::Value& v);  // Handle -> 指针
```

两个设计决策值得停留：

- **`fields` 按下标对齐 `Class::properties`**——属性名只在类里存一份，对象只
  按下标存值。这让运行中的字段访问退化为数组下标（第 5 步会看到完整收益）。
- **`fields` 的元素是 `Value`**——属性可以是任何 Stope 值，包括指向另一个
  对象的 Handle。demo 5 对此不级联（delete 父不影响子），正好给 demo 6 留
  伏笔。

## 3. 第三步：用 STML 文档描述类

类定义写在 STML 文档里，代码段就是 Stope 源码：

```xml
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
    println("-- introducing --");
    self:Greet();
    println("age via self:Age() = ", self:Age());
  </method>
  <new name="New" params="name age">
    self:name = name;
    self:age = age;
  </new>
  <delete>
    println("[Person] deleted!");
  </delete>
</class>
<func name="main">
  let p = Person:New("Tom", 18);
  obj:name[p] = "James";
  obj:Introduce[p]();
  obj:delete(p);
</func>
```

约定：`<new>` 可有多个，`name` 是构造器名；`<delete>` 至多一个，无名字。

**代码段怎么被扫成 Stope**：STML 默认把元素内文本当 Xml 文本，需要经
`stateFunc` 回调按标签名放行——`method` / `new` / `delete` / `func` 返回
`LexerState::Stope`，其余保持 Xml（回调契约见 [`stml.md`](stml.md) §2）：

```cpp
// demo/05-object.cpp
auto stateFunc = [](std::u16string_view tag,
                    map<u16string_view, u16string_view> attrs) -> STML::LexerState {
  if (tag == u"method" || tag == u"new" || tag == u"delete" ||
      tag == u"func") {
    return STML::LexerState::Stope;
  }
  return STML::LexerState::Xml;
};
```

**编译**（`DocVisitor::VisitMethod`）四件事：

1. `preExports = 形参`——**属性不进 preExports**。方法体里的 `self:<属性>`
   （读或写）与 `self:<方法名>(...)` 是未声明标识符，靠编译器的**隐式导出
   机制**浮现（未声明标识符自动注册：读取走 PushValue，赋值目标走 PushId
   可写回）。这是方案的核心技巧：方法体里 `self:name = name` 只是普通的
   变量赋值，读写经槽位与宿主字段互达（第 6 步）；属性、方法两种 `self:`
   引用在编译后由链接遍统一分类配对——**未使用的属性不占槽位、不参与拷入
   拷出**；
2. `lexer.line = e.textLine`，报错行号对齐原文档；
3. Lexer → Parser → Compiler 常规流水，失败即抛；
4. `m.constAlloc = make_unique<ProgramConstants>(rt.basicAlloc, m.program)`——
   常量表随方法存活。

```cpp
// DocVisitor.cpp，VisitMethod 核心
// preExports = 形参。self:<属性> 不再预导出：方法体里对它们的引用靠编译
// 器的隐式导出机制浮现，链接遍再与字段配对。
Lexer lexer(e.text);
lexer.line = e.textLine;
Parser parser(lexer);
AST::Prog prog;
parser.ParseProgram(prog);
...
Compiler compiler;
if (compiler.Compile(prog, m.program, m.params) != Result::Success) {
  throw runtime_error("Error compiling method: " + compiler.errors[0]);
}
```

`<func>` 的编译走同一条路（`VisitFunc`），只是没有 `self:` 引用。顶层
`<func name="main">` 就是程序入口。

## 4. 第四步：实现 Handle 的三个开口

运行期的全部行为集中在 `ObjectManager`，`API` 只是薄转发：

```
VM opcode（栈纪律归它）
  └─> API::HandleAt / HandleAssign / HandleCall   （虚分发）
        └─> ObjectManager::At / Assign / Call      （值计算在这里）
```

```cpp
// API.hpp
struct API : Stope::BasicVM::API {
  ObjectManager* objMgr = nullptr;
  void HandleAt(Stope::BasicVM::State& s, const Stope::BasicVM::Value& handle,
                const Stope::BasicVM::Value& key, Stope::BasicVM::Value& out) override;
  void HandleAssign(Stope::BasicVM::State& s, const Stope::BasicVM::Value& handle,
                    const Stope::BasicVM::Value& value) override;
  void HandleCall(Stope::BasicVM::State& s, const Stope::BasicVM::Value& handle,
                  std::span<Stope::BasicVM::Value> args, Stope::BasicVM::Value& out) override;
};
```

三个开口的语义：

- **At**：`obj:<名>[p]` → 校验 key 是对象后，把对象绑进描述符副本（`Bind`），
  返回绑定描述符的 Handle。属性引用与绑定方法都从这里出发；
- **Assign**：`obj:<属性>[p] = v` → 经**两层整数查询**定位字段槽位（见第 5 步），
  `Clear2` 旧值后 `Copy` 新值；
- **Call**：按查表得到的 kind 分发——构造描述符走 `NewObject` + `PushMethodFrame`
  （构造器帧不取方法返回值）并把对象 Handle 作为返回值压栈；`kMemberDelete`
  跑 `<delete>` 后回收；绑定方法走 `PushMethodFrame`，开口返回占位 Null、
  弹栈时回填真正的返回值。

`Assign` 的实现不长，可以直接看「两层整数查询」长什么样（描述符的设计见
第 5 步）：

```cpp
// ObjectManager.cpp
void ObjectManager::Assign(BasicVM::State& s, const BasicVM::Value& handle,
                           const BasicVM::Value& value) {
  Object* desc = HandleToDesc(handle);
  if (desc->classId != kMemberDescClass ||
      desc->fields[1].type != BasicVM::Value::Type::Handle) {
    s.Error("not assignable. ");
    return;
  }
  Object* obj = HandleToObject(desc->fields[1]);
  Class& cls = runtime->classes[obj->classId];              // 第一层：classId 选类
  auto it = cls.memberById.find((int)desc->fields[0].data.integer);
  if (it == cls.memberById.end()) {
    s.Error("not assignable. ");  // 该类没有这个成员
    return;
  }
  if (it->second.kind != kMemberProp) {
    s.Error("not assignable. ");  // 方法不可赋值
    return;
  }
  BasicVM::Value& slot = obj->fields[(size_t)it->second.index];  // 第二层
  slot.Clear2(*s.alloc);
  BasicVM::Value::Copy(*s.alloc, const_cast<BasicVM::Value&>(value), slot);
}
```

## 5. 第五步：设计描述符与绑定

现在回答一个问题：`obj:Greet[p]()` 里，VM 拿到的 Handle 指向谁？

答案是**描述符**——一个记录「访问谁、做什么」的小对象。描述符也是 `Object`
（`classId` 取负哨兵，与真实类的非负 id 区分开），Handle 统一指向 `Object`：

| 描述符 | classId | fields |
| --- | --- | --- |
| 成员 `obj:<名>` | `-2` | `[Integer 成员 id, 绑定对象 Handle/Null]` |
| 构造器 `<Class>:<名>` | `-3` | `[Integer 类 id, Integer 构造器下标]` |

**成员定位是两层整数查询**，各层在装配期建好：

1. **第一层**（选类）：绑定对象自己的 `classId` 选出类——同名成员在各类里
   可以落在不同位置，各归各；
2. **第二层**（类内唯一查找表）：成员 id 查该类的 `memberById` 得到
   `MemberRef{kind, index}`——kind 由表揭晓（描述符里不装），index 落进
   `properties` / `methods` 之一。成员 id 由 `Runtime::memberNameMap`
   （成员名 → id，全局跨类共享同名 id）在装配期分配，运行中零字符串比较。

单表还带来一个结构性约束：**同一个名字在同一个类里只能是属性或方法之一**。

注意「统一查找」不等于「统一存储」：`properties` / `methods` 保持两个数组——
属性只有身份（数据在实例 `fields` 里），方法带行为（`Program` 等），混进一个
数组会杀死「`fields` 按下标对齐 `properties`」的不变式，第 6 步的槽位契约
（`self:` 槽位下标即字段下标）依赖它。

**为什么 fields 里装的是整数而不是名字**：按名查找（字符串比较、线性扫、
map）都不该出现在 `RunSteps` 驱动的执行期间。所有索引在**装配期**算好：

- `Method::slotIdx` / `Function::paramVarIdx`：槽位名 → 变量槽位下标（编译后
  从 `exports` 一次抄出）；
- `Method::hostBinds` / `Function::hostBinds`：`(变量槽位下标, 宿主函数序号)`，
  把 `println` 这类宿主函数的绑定目标定死；
- 成员描述符只装成员 id，`Assign` / `Call` 经两层查询定位到具体类的成员。

按名只发生在装配期（DocVisitor 访问文档、`Runtime::BindEntry` 绑定导出名）。
绑定代码是全部「名字出现在运行前」的地方，收在 Runtime 的一个成员函数里——
`obj:*` 命名、`<Class>:<名>` 构造器命名这些约定属于 Runtime 对文档的契约，
嵌入者（入口）只调一行 `runtime.BindEntry(state, *mainFunc);`：

```cpp
// Runtime.cpp，BindEntry——三类绑定：
// 宿主函数：装配期已预算 (槽位下标, 宿主函数序号)，直接绑。
for (auto& [varIdx, hostIdx] : entry.hostBinds) {
  BasicVM::Value& slot = state.variables[varIdx];
  slot.type = BasicVM::Value::Type::HostFunction;
  slot.data.hostFuncPtr = hostFuncs[hostIdx];
}
// 构造器："<Class>:<New 名>" 逐个绑
for (auto& cls : classes) {
  for (auto& [name, methodId] : cls.constructorMap) {
    bind(cls.name + u":" + name, objMgr.NewCtorDesc(cls.id, methodId));
  }
}
// 成员描述符 obj:<属性>/<方法>/<delete>：描述符只装成员 id（kind 由类的
// memberById 查表揭晓）
for (auto& cls : classes) {
  for (auto& prop : cls.properties) {
    bind(u"obj:" + prop, objMgr.NewMemberDesc(NewMemberId(prop)));
  }
  ...
}
```

`bind` 做的事：按导出名查 `exports` 拿槽位下标，把描述符 Handle `Copy` 进
`state.variables` 对应槽位。此后 `obj:Greet` 对 VM 而言只是一个变量，值是
Handle——运行中零查找。

另一个工程决策是**容器的选择按「谁需要地址稳定」区分**：

- **描述符放 `RefCountedPool<Object>`（vector 底）** 且按回收槽位复用——描述符的
  Handle 存**池下标**而非裸指针，vector 下标天然稳定、`realloc` 无所谓，无需
  `deque`；这是 Handle 存下标能成立的前提；
- **类/方法/函数用 `vector`** 就够了——整数索引化之后没有人跨容器扩容持有
  指针（长期引用全是 id / 下标）；`constAlloc` 用 `unique_ptr` 让
  `Method` / `Function` 可移动（库的 `ProgramConstants` 也因此实现了移动
  构造：句柄所有权随向量转移，Allocator 才是真正的拥有者）。

## 6. 第六步：接通 self 与字段的槽位契约

第 3 步的编译靠隐式导出让 `self:` 引用浮现在 `exports` 里，第 6 步把槽位与
字段真正接通。装配期的链接遍（`linkSelfCalls`）先把两类引用配对：

- `selfProps`：`self:<属性>` → `(槽位下标, 字段下标)`，**只含方法体实际引用
  的属性**——未使用的属性不占槽位、不参与拷入拷出；
- `selfMethodBinds`：`self:<方法名>` → `(槽位下标, 成员 id)`。

`Method::InitializeState(state, self, args)` 负责进入时：

1. `selfProps` 逐对从 `self.fields` 复制（只拷实际引用的）；
2. 形参槽位按序注入实参——所有 State 共享一个 `Allocator`，String 句柄直接
   `Copy`，不存在跨 allocator 问题。

`Runtime` 把调用过程拆成「压帧」与「弹帧收尾」两半，共用一个装配函数：

```cpp
// Runtime.cpp —— 装配（PushMethodFrame / InvokeMethod 共用）
void Runtime::SetupMethodState(Method& m, Object& self,
                               std::span<const BasicVM::Value> args,
                               BasicVM::State& state) {
  state.SetAPI(api);
  state.SetAllocator(basicAlloc);
  state.SetProgramConstants(*m.constAlloc);
  state.SetProgram(m.program);
  state.variables.resize(m.program.variableNum);
  m.InitializeState(state, self, args);

  // 方法体里的宿主函数（println 等）绑进隐式导出槽位——装配期已预算好
  // (变量槽位下标, 宿主函数序号) 对，运行中零查找。
  for (auto& [varIdx, hostIdx] : m.hostBinds) { ... }

  // self:<方法名> 槽位绑 self 的绑定方法描述符——self:Greet() 直接调本类
  // 方法，无需 [对象]：描述符创建时即绑定 self，Call 走绑定分支。
  for (auto& [varIdx, memberId] : m.selfMethodBinds) { ... }
}

// Runtime.cpp —— 方法调用：只装配、压帧，**不执行**
void Runtime::PushMethodFrame(Method& m, Object& self,
                              std::span<const BasicVM::Value> args,
                              bool wantsReturn) {
  auto f = make_unique<Frame>();
  SetupMethodState(m, self, args, f->state);
  f->method = &m;
  f->self = &self;
  f->wantsReturn = wantsReturn;
  frames.push_back(std::move(f));
}

// Runtime.cpp —— 驱动循环：只跑栈顶帧，至多 maxSteps 条指令
bool Runtime::RunSteps(int maxSteps) {
  while (maxSteps > 0 && !frames.empty()) {
    BasicVM::State& s = frames.back()->state;
    if (s.i >= static_cast<int>(s.program->opcodes.size())) {
      FinishTopFrame();  // Return 已把返回值备好；弹栈不消耗步数
      continue;
    }
    if (s.Step() != Stope::Result::Success) {
      FinishTopFrame();  // 运行期错误：只中止当前函数，调用方继续
      continue;
    }
    --maxSteps;
  }
  return !frames.empty();
}

// Runtime.cpp —— 帧收尾（弹栈时）
void Runtime::FinishFrame(Frame& f) {
  for (const auto& e : f.state.errors) { cout << "  vm: " << e << "\n"; }
  if (f.method == nullptr) return;  // 入口帧
  for (auto& [slotIdx, fieldIdx] : f.method->selfProps) {
    BasicVM::Value& dst = f.self->fields[fieldIdx];   // self:<属性> 槽位写回
    dst.Clear2(basicAlloc);                           // 字段——selfProps 只含
    BasicVM::Value::Copy(basicAlloc,                  // 方法体实际引用的属性
                         f.state.variables[slotIdx], dst);
  }
  // 回填调用方栈顶：Call 开口当时返回的占位 Null 就在那里，覆盖即可
  if (f.wantsReturn && !frames.empty() && !f.state.returns.empty()) {
    BasicVM::Value& slot = frames.back()->state.stack.back();
    slot.Clear2(basicAlloc);
    BasicVM::Value::Copy(basicAlloc, f.state.returns[0], slot);
  }
}
```

**self 绑定与链接遍**：`self:` 前缀的两类引用走同一条隐式导出编译路径，链接
遍按成员种类分流——属性配对字段、方法记入 `selfMethodBinds`。链接在
`VisitDoc` 全部类访问完之后跑（方法可以引用文档里后定义的成员）；`SetupMethodState`
据 `selfMethodBinds` 往槽位绑 `objMgr.Bind(memberId, self)` 的绑定描述符——
**创建时即绑定 self**，所以 `self:Greet()` 无需 `[对象]`，Call 直接走绑定
分支；每次 Bind 新建一个绑定描述符（不去重），由 descPool 的回收复用兜底。

链接遍同时做校验：`self:` 前缀的隐式导出若既没链接到属性、也没链接到任何
本类方法（典型如拼写错误 `self:Gret`），装配期就抛错拦下——否则要等运行时
槽位是 Null 才炸。

**调用栈在哪**：Runtime 持有一个**显式帧栈**（`std::vector<std::unique_ptr<Frame>>`），
一个 Frame = 一个 State + 收尾元数据。入口 main 调 `PushEntryFrame` 压入第一帧，
方法调用压帧（`PushMethodFrame`）、方法返回弹帧（`FinishTopFrame`）——
**调用栈从 C++ 递归栈搬到了 Runtime 的成员里**。这样做换来的能力是
`RunSteps(maxSteps)`：驱动循环每次只跑栈顶帧、至多 maxSteps 条指令，方法
调用与返回都不消耗步数——游戏里「每帧给脚本 N 条指令的预算」就是一行
`while (runtime.RunSteps(20)) {}`；单步调试就是把 20 改成 1，嵌套方法体的
每一条指令都会停下来。

展开说，**压栈帧的点全部在宿主侧**，`PushMethodFrame` 是唯一的压帧函数：

| 时机 | 压帧点 | 说明 |
| --- | --- | --- |
| 入口 | 宿主 main | `PushEntryFrame(*mainFunc)` |
| 运行期·构造 | `ObjectManager::Call` 构造分支 | `wantsReturn=false`：返回值是新对象本身 |
| 运行期·方法 | `ObjectManager::Call` 方法分支 | `wantsReturn=true`：弹栈时回填调用方栈顶 |
| 运行期·析构 | `ObjectManager::Delete` | **不走帧栈**：`InvokeMethod` 同步跑完（见下） |

每层 Stope 方法调用是一个 Frame——`Frame::state` 持有这一帧的 VM 值栈（形参、
`self:` 槽位、表达式中间值）；方法体里再调 `obj:X[q]()` 就是
`Step → opCall → HandleCall → Call → PushMethodFrame` 压新帧。Call 开口
返回占位 Null，`opCall` 把它 Move 到调用方栈顶后，调用方停在 `Call` 的下一
条指令——驱动循环只跑栈顶帧，它自然被压住；被调帧弹栈时 `FinishFrame` 把
真正的返回值覆盖到调用方栈顶。宿主函数（`println`）例外：`opCall` 直接在
**同一个** State 上调 C++ 函数，不压新帧。

**唯一的例外是析构**：`<delete>` 在 `Delete` 的清理序列中间被调用（之后还要
移出存活表、`delete` 对象），必须一口气跑完——`InvokeMethod`（同步版：装配 +
`Run` + 收尾）专供这条路。析构里再调方法也走这条同步路：压进帧栈的帧没有
驱动循环去跑（此刻正停在 Step 中间），返回值会永远是占位 Null。

两个值得点透的事实：

- **BasicVM 没有 call/return 帧指令**——一个 Program 配一个 State，语言层是
  平的。「调用栈」是 demo 侧的概念：显式帧栈 + 每帧一个 State。
- **帧是 `unique_ptr`**（`RunSteps` 执行中 `frames` 可能因嵌套调用扩容）；
  弹栈收尾先摘出再 `FinishFrame`，回写 `selfProps` 期间即使触发嵌套动作，
  也不影响回填目标（调用方栈顶）的稳定性。

一个已知性质：方法递归的嵌套深度 = 帧数，demo 未设限（解析期有 256 层嵌套
上限，**运行期**没有）——深度递归会耗尽内存/栈，demo 规模无碍。

## 7. 第七步：手动生命周期

```cpp
// ObjectManager.cpp
BasicVM::Value ObjectManager::NewObject(int clsId) {
  Object* obj = new Object{};  // 手动管理：obj:delete 释放
  obj->classId = clsId;
  obj->fields.resize(runtime->classes[clsId].properties.size());
  live.insert(obj);
  return ObjectToHandle(obj);
}

// 跑 <delete>（可读写字段）-> 移出存活表 -> delete。双重 delete 在这里拦下。
void ObjectManager::Delete(BasicVM::State& s, Object& obj) {
  if (live.erase(&obj) == 0) {
    s.Error("double delete. ");
    return;
  }
  Class& cls = runtime->classes[obj.classId];
  if (cls.deconstructorId >= 0) {
    runtime->InvokeMethod(cls.methods[cls.deconstructorId], obj, {}, nullptr);
  }
  delete &obj;
}
```

三件配套：

- **`live` 表**：`ReportLive()` 在程序结束打印存活对象——忘了 `obj:delete`
  的在这里现形；`maxObjects`（默认 0 = 不限，对齐 Parser / STML `maxDepth`
  的约定）给存活数封顶，顶到上限的构造器报 `too many objects.` 走正常错误
  通道（demo 设 4096 作配置演示）；
- **双重 delete** 在 `Delete` 里拦下（`live.erase` 返回 0 即报错）；
- **悬空 Handle 是程序错误**：`obj:delete(p)` 之后 `p` 还留着旧指针，再用是
  未定义行为。demo 5 不设防——这正是「手动管理」的教学点，demo 6 的 GC 把
  它变成不存在的问题。

**描述符的账**：对象之外还有一类隐式分配要管——`obj:Greet[p]()` 每次执行的
At 都会 `Bind` 出一个绑定描述符，文档程序员拿不到它，没法手动删。demo 5 的做法：

描述符也是 `Object`（classId 为负哨兵），统一塞进 `RefCountedPool<Object>`
（vector 底，Handle 存**池下标**而非裸指针，下标天然稳定、无需 `deque`），
**不去重**——每次 `Bind` 都新建一个、返回其下标 Handle，池子按回收槽位复用：

- **`New` 即建**：`NewMemberDesc` / `NewCtorDesc` / `Bind` 都走 `descPool.New()`，
  引用计数置 1，返回稳定指针；
- **`obj:delete` 整组驱逐**：绑定描述符登记进 `descByObject`（对象地址 ->
  其绑定描述符的池句柄，仅用于驱逐、不做去重），`Delete` 时按地址 O(log A)
  定位、O(k) 逐个 `RefDec` 回收（k ≤ 成员数，是驱逐的固有工作量）。`RefDec`
  归零即回收槽位，下次 `New` 优先复用最小句柄；
- **账只随活跃绑定走**：`descPool` 内存 ≈ 峰值并发绑定数；`descByObject`
  条目数 ≈ 活跃对象数 × 其绑定描述符数。

   | 量 | 上界 |
   | --- | --- |
   | `descByObject` 条目 | 活跃对象数 × 其绑定描述符数 |
   | `descPool` 内存 | 峰值并发绑定数 |

   实测：`ReportLive` 打印的 `[descs]` 一行（allocated / pooled）随 churn
   循环增长到峰值后即靠回收复用，不再单调涨。

一个如实记录的语义变化：描述符槽位被回收复用后，悬空绑定 Handle 若再用会
**别名到复用后的新绑定**——错乱方式从「指向已释放内存」变为「操作错误的
绑定」，本质同属「悬空 Handle 是程序错误」的纪律，不变。demo 6 的 GC 接手
后，`obj:delete` 与 `descByObject` 退场，绑定描述符随可达性自动回收，这笔账
按构造消失。

## 8. 装配与运行

入口文件 `demo/05-object.cpp` 的装配顺序就是第 2–7 步的串联，四段：

```cpp
// ---------- 1. STML 解析（stateFunc 放行代码段标签）
// ---------- 2. DocVisitor 访问文档：构建类、编译函数（第 3 步）
// ---------- 3. runtime.PushEntryFrame(*mainFunc)（第 5 步：装配 + 绑定 + 压帧）
// ---------- 4. RunSteps / RunAll + ReportLive()（第 7 步）
```

主 State 的装配收进 `PushEntryFrame`（`SetAPI` / `SetAllocator` /
`SetProgramConstants` / `SetProgram` / `variables.resize` / `BindEntry`），
唯一的区别是 `SetAPI(runtime.api)` 传入了覆写过三个虚函数的 API——这一行
接通第 4 步。驱动有两种，**随时可切**：

* **限步**：`while (runtime.RunSteps(20)) {}`——每帧最多 20 条指令，帧间
  就是宿主的逻辑帧（游戏「每帧给 N 条预算」就这一行；单步调试把 20 改 1）；
* **直接**：`runtime.RunAll()`——一口气跑到帧栈清空。

demo 先限步 1 帧再 `RunAll` 跑完，输出带一行统计。

**错误通道：demo 5 包含 throw 隐藏控制流。** 全部 5 个抛出点是：`DocVisitor`
四处（方法/函数解析、编译失败）加 `Bind` 一处（描述符契约检查）；唯一的
`catch` 在入口。`throw` 会跳过 `VisitDoc → VisitClass → VisitMethod` 中间
所有栈帧直达入口——这条跳转不体现在任何函数签名的返回值里，读代码时容易
漏掉，故在此明示。栈展开本身是安全的：中间各层不持手工资源（对象在堆上由
`live` 表管、描述符在 `descPool`（vector 底、池下标 Handle）里按回收复用兜底），
你扩展时若在某个栈帧里拿了需要释放
的资源，请改用 RAII 或就地捕获。

两套错误通道的分界要分清：**Stope 程序的运行期错误不抛**——`not
assignable` / `no method` / `double delete` 等走 `s.Error()` 进
`state.errors`，那是 Stope 程序的正常错误路径，由 VM 记账；`throw` 只用于
宿主装配期「没有合理继续方式」的失败与宿主内部契约违反。移植到没有异常的
语言实现时，把装配期的 `throw` 换成错误返回值（逐层上传到 `main`）即可，
语义不变。

```sh
cmake -B build -G "MinGW Makefiles"   # MSVC 下用默认生成器
cmake --build build --target demo05
./build/demo05.exe
```

输出：

```
-- introducing --
i am James, 18 years old.
age via self:Age() = 18
[Person] deleted!
-- 1 stepped slice(s), 20 steps each, then RunAll --
[objects] all freed
```

五行分别对应：`self:Greet()` 调通同对象方法、属性写入生效、`self:Age()`
带回返回值、`<delete>` 真的跑了、限步 1 帧后直接执行跑完（整棵调用树只
用了 40 条指令）、没有泄漏。

## 9. 文件清单

入口 `demo/05-object.cpp` 在目录外（与 nodejs/python/lua 的
`05-object.js/.py/.lua` 同形态），模块文件都在 `demo/05-object/` 内：

| 文件 | 职责 |
| --- | --- |
| `../05-object.cpp` | 入口：STML 文档、装配、运行、清理诊断 |
| `Runtime.hpp/.cpp` | `Runtime`：显式帧栈（`Frame`/`PushEntryFrame`/`PushMethodFrame`/`RunSteps`）+ `BindEntry`（入口绑定）+ `InvokeMethod`（析构专用的同步路径） |
| `ObjectManager.hpp/.cpp` | `obj:*` 域全部行为：描述符创建、三个开口的实现、`live` 表 |
| `API.hpp/.cpp` | BasicVM 三个虚函数的薄转发 |
| `Object.hpp/.cpp` | `Object` 结构 + Handle↔指针 helper |
| `Class.hpp/.cpp` | `Class` / `Method` + 槽位装配 |
| `Function.hpp/.cpp` | `Function` + 形参装配 |
| `DocVisitor.hpp/.cpp` | STML 文档 → 类与函数（含编译、索引预算） |

## 10. 已知局限与未定义行为（有意不修，供参考时注意）

demo 5 / 6 的定位是参考实现：**bug 会修、结构与可读性会持续优化**，但下面
这些问题**有意保留**——要么是「手动管理」立场的自然结果，要么修起来要动
语言或标准层面的语义，超出 demo 的边界。参考或移植本 demo 时请逐条对照。

**未定义行为（手动管理的纪律边界）**

- **悬空 Handle**：`obj:delete(p)` 之后 `p` 仍持有旧地址，再用（读属性、
  调方法、再 delete）是未定义行为。绑定描述符驱逐复用后，悬空的绑定
  Handle 再用会**别名到复用后的新绑定**——错乱方式从「指向已释放内存」
  变为「操作错误的绑定」，纪律相同（见第 7 步）。

**已知局限（行为确定，但语义有缺口）**

- **属性没有 rvalue 读**：`obj:name[p]` 在读取语境下得到的是绑定描述符的
  Handle，不是字段值——Call / At 的宿主回调看不到「结果被读还是被写」，
  无法在同一语法下同时给出值与可写引用。读属性请经方法（如
  `self:Age()` / `obj:Age[p]()`）。
- **构造失败返回半成品对象**：`Person:New(...)` 的 `<new>` 执行中出错时，
  对象已经创建并进入存活表，Handle 照常返回——半成品对象需手动 delete。
- **缺参调用静默**：`Person:New("Tom")` 少传实参时，缺的形参槽位是 Null，
  构造照常完成（编译器也不校验实参个数，与内置函数行为一致）。
- **方法递归无深度限制**：每层 Stope 方法调用压一对「C++ 帧 + 临时 State」
  （见第 6 步），无限递归（如 `self:Greet()` 无条件自调）会耗尽 C++ 栈
  直接崩溃——解析期有 256 层嵌套上限，运行期没有对应防护。
- **`<func>` 中的 `self:` 无校验**：顶层函数里写 `self:xxx` 能编译（隐式
  导出机制），但没有人往该槽位绑值，运行时才报错——函数没有 self 语义，
  文档里不应出现 `self:`。

## 11. 移植提示与衔接 demo 6

**移植到其它语言实现时**，宿主侧结构可以照搬；前提是各实现的库先具备等价的
Handle 缝——值类型加 Handle、equals 同一性分支、三条执行路径转发到该实现的
扩展点（如 GD 侧 `Api` 的对应方法、JS/Py 侧 API 子类）。这些改动属于库本身，
与本文宿主侧的七步互不重叠。

**demo 6** 把 `ObjectManager` 的存储与回收策略换成 GC（引用计数 + 标记清除，
`Handle` 语义不变）：对象不再 `new` / `delete` 配对，`obj:delete` 与 `live`
表退场，`ReportLive` 换成 gc 统计。第 3、5、6 步的产物（类、描述符、槽位
契约）原样保留——这正是把「对象模型」与「生命周期策略」分层的好处。
