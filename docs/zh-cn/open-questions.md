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
| OQ-1 | **条件真值表升格为语言契约** | 表（Null 假；整数/浮点非零真；字符串/二进制数组非空真）现仅成文于 [vm-guide.md §8.2](vm-guide.md)（VM 侧）。字面量条件折叠（OQ-2）若落地，编译期也按它判定，折叠正确性 = 编译期真值 ≡ 运行期真值，需要权威出处。候选落点：syntax-reference（语言权威）+ constant-folding.md（折叠依据）+ vm-guide 互指 | 推荐写；表已被 golden 的 VM 用例锁成事实契约，只差语言文档认领 |
| OQ-2 | **if / elif / else / while 字面量条件折叠** | 条件为字面量时按真值表（OQ-1）静态判定：常量真只发该分支，常量假整支（while 则整环）消除；`while true` 折叠为无条件循环、不再豁免（C-67 归入此项）。候选代价：C-67 / golden 同步、八实现移植 | 2026-11-07 倾向：做；`while true` 不豁免。**整体未定夺** |
| OQ-3 | **`-2 ^ 2` 的一元负号优先级**（PD-18） | 现状 `(-2)^2`（一元高于 `^`）；Python 是 `-(2^2)`，Excel 是 `(-2)^2` | 参考实现与本实现一致，倾向记录为现状 |
| OQ-4 | **parser 不校验赋值左值**（PD-10，`1 = 2;` 0 errors） | 交给语义分析，或 parser 报错 | 待定 |
| OQ-5 | **跨类型 `==` / `null` 比较是否折叠**（[expr-optim.md §10](../../cpp/docs/expr-optim.md)） | 需先定夺类型强制规则：`true == 1`、`null == 0`、`null` 参与比较的语义 | 折叠必须与运行期一致，规则未定前不动 |
| OQ-8 | **defer 载荷引用后文声明的本地名字：报错 vs 当作外层符号** | 现行：报错 `"X" is declared after the defer statement.`（行号归 defer 语句，golden DF-06 锁定；报错后按当前绑定继续，产物清空）。背景：冻结绑定的承诺是「名字集合在 defer 语句处定格」——后文声明只在其是**遮蔽**时不可见（DF-05，绑外层不报错）；后文**首次**声明才触发此错误。改为：不报错，跳过后文的本声明、按隐式导出宿主变量处理（同 DF-10 路径）。任一候选落地都需改 C-58 / DF-06 并同步八份 + golden | **倾向不报错、当作外层符号处理**（用户 2026-11-08）；候选①还是②待定夺 |

## 2. 已定夺未落地

（空）

## 3. 已落地（索引）

| 决定（日期） | 详情在哪 |
| --- | --- |
| **defer 移植到全部八份实现**（2026-11-07，OQ-7）：golden 加 DF-01…DF-14，七份实现全部逐字节通过 | [compiler-test-plan.md §4.10](compiler-test-plan.md) |
| **死代码消除移植到全部八份实现**（2026-11-07，OQ-6）：golden 重生成（201→215 条），CM-44/51/52/53 分歧消除 | [compiler-test-plan.md §4](compiler-test-plan.md)、[cpp/docs §5.11](../../cpp/docs/compiler-test-plan.md) |
| defer 出口次序终版：**结算 → PushValue → Return**，Return 之后无死代码（2026-11-07，历经两次反转后定稿） | [compiler-test-plan.md §5.10](../../cpp/docs/compiler-test-plan.md) |
| 死代码消除：语句终止标志局部判定，四个消费点（2026-11-07） | [compiler-test-plan.md §5.11](../../cpp/docs/compiler-test-plan.md) |
| `^` 右结合（2026-10-22 定夺，接替同日左结合的初版） | [syntax-impl.md §5.3](syntax-impl.md) |
| 嵌套深度上限 256（Parser 与 STML 同语义，2026-10-30 / 11-02） | [syntax-impl.md §10.1](syntax-impl.md)、[parser-test-plan.md](../../cpp/docs/parser-test-plan.md) |
| demo 定位：教用法、输出不追求逐字节相同（2026-10-30） | 根 [README.md](../../README.md) 各 demo 小节 |
| BasicVM 定位三句话（不属于标准 / 会一直维护 / 基础虚拟机） | [basic-vm.md §1.1](../../cpp/docs/basic-vm.md) |
