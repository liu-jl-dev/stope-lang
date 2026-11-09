# 待定夺与决定记录（Open Questions）

> 收**跨实现的语言 / 编译器层**问题：还没定夺的设计取舍、已定夺但未落地的改动、
> 以及已落地决定的索引。单实现内部的小事（缺陷修法、重构）仍留在各自文档
> （如 [syntax-impl.md §10](syntax-impl.md) 的 PD-x 清单），这里不重复。
>
> 状态三档：**待定夺** → **已定夺未落地** → **已落地**（落地后条目转入对应
> 主题文档，本表只留索引行）。每条定夺记日期与一句话理由；定夺被推翻时
> 不删历史，改状态并追加新决定（defer 出口次序两度反转即此例）。

## 1. 待定夺

| 编号 | 问题 | 背景与候选 | 倾向 |
| --- | --- | --- | --- |
| OQ-1 | **条件真值表升格为语言契约** | 表（Null 假；整数/浮点非零真；字符串/二进制数组非空真）现仅成文于 [vm-guide.md §8.2](vm-guide.md)（VM 侧）。**常量折叠已经在消费这张表**：expr_optim 的 `truthy()`（与 BasicVM `truely()` 逐条相同）支撑 `!` 对 Null/数值的折叠与 `&&`/`||` 对字面量的折叠（含序列真值，golden_binarr 的 FB/FU 矩阵锁定）；字面量条件折叠（OQ-2）若落地会消费更多。折叠正确性 = 编译期真值 ≡ 运行期真值，需要权威出处。候选落点：syntax-reference（语言权威）+ constant-folding.md（折叠依据）+ vm-guide 互指 | 推荐写；表已被 golden 的 VM 用例与折叠矩阵锁成事实契约，只差语言文档认领 |
| OQ-2 | **if / elif / else / while 字面量条件折叠** | 条件为字面量时按真值表（OQ-1）静态判定：常量真只发该分支，常量假整支（while 则整环）消除；`while true` 折叠为无条件循环、不再豁免（C-67 归入此项）。候选代价：C-67 / golden 同步、八实现移植 | 2026-11-07 倾向：做；`while true` 不豁免。**整体未定夺** |
| OQ-3 | **`-2 ^ 2` 的一元负号优先级**（PD-18） | 现状 `(-2)^2`（一元高于 `^`）；Python 是 `-(2^2)`，Excel 是 `(-2)^2` | 参考实现与本实现一致，倾向记录为现状 |
| OQ-4 | **parser 不校验赋值左值**（PD-10，`1 = 2;` 0 errors） | 交给语义分析，或 parser 报错 | 待定 |
| OQ-5 | **跨类型 `==` / `null` 比较是否折叠**（[expr-optim.md §10](../../cpp/docs/expr-optim.md)） | 需先定夺类型强制规则：`true == 1`、`null == 0`、`null` 参与比较的语义 | 折叠必须与运行期一致，规则未定前不动 |

## 2. 已定夺未落地

（空）

## 3. 已否决

| 编号 | 问题 | 否决理由（日期） |
| --- | --- | --- |
| OQ-9 | **局部常量省略 Assign（let 常量的常量传播）** | **否决（2026-11-08，用户拍板）**。`Assign` 常量还有另一层含义：**将常量从常量表加载到 State 的局部槽**——槽位必须真正持有该值，后续 `PushValue` 读槽位才有意义。省略 Assign 意味着槽位从未持有值，uniform 槽位模型（槽位 = 值的唯一事实来源）被打破；此前为 sound 推演的两态机 + while 入口 flush + if 链尾同步块等复杂机制，全部是在为打破这一层含义买单。性能上同样不占优：`PushValue(槽)` 与 `PushInt(池)` 同为一次下标读 + 入栈（basic_vm.hpp 的 opPushValue / opPushInt），整数常量路径甚至更省（跳过 `Value::Copy` 的类型分派），物化进槽位是纯语义动作而非缓存优化。问题就此关闭 |

## 4. 已落地（索引）

| 决定（日期） | 详情在哪 |
| --- | --- |
| **OQ-8 defer 绑定语句及其符号**（2026-11-08，八份落地）：前向引用不报错、不被捕获，按隐式导出宿主变量处理；FileScope 同名报 `duplicate export`。C-58 重写、C-68 新增、DF-06 更新、DF-15 新增、golden 重生成 216 条 | [syntax-reference.md defer 小节](syntax-reference.md)、[compiler-test-plan.md §4.10](compiler-test-plan.md) |
| **defer 移植到全部八份实现**（2026-11-07，OQ-7）：golden 加 DF-01…DF-14，七份实现全部逐字节通过 | [compiler-test-plan.md §4.10](compiler-test-plan.md) |
| **死代码消除移植到全部八份实现**（2026-11-07，OQ-6）：golden 重生成（201→215 条），CM-44/51/52/53 分歧消除 | [compiler-test-plan.md §4](compiler-test-plan.md)、[cpp/docs §5.11](../../cpp/docs/compiler-test-plan.md) |
| defer 出口次序终版：**结算 → PushValue → Return**，Return 之后无死代码（2026-11-07，历经两次反转后定稿） | [compiler-test-plan.md §5.10](../../cpp/docs/compiler-test-plan.md) |
| 死代码消除：语句终止标志局部判定，四个消费点（2026-11-07） | [compiler-test-plan.md §5.11](../../cpp/docs/compiler-test-plan.md) |
| `^` 右结合（2026-10-22 定夺，接替同日左结合的初版） | [syntax-impl.md §5.3](syntax-impl.md) |
| 嵌套深度上限 256（Parser 与 STML 同语义，2026-10-30 / 11-02） | [syntax-impl.md §10.1](syntax-impl.md)、[parser-test-plan.md](../../cpp/docs/parser-test-plan.md) |
| demo 定位：教用法、输出不追求逐字节相同（2026-10-30） | 根 [README.md](../../README.md) 各 demo 小节 |
| BasicVM 定位三句话（不属于标准 / 会一直维护 / 基础虚拟机） | [basic-vm.md §1.1](../../cpp/docs/basic-vm.md) |
