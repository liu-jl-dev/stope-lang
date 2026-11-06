# Demo 05: 宿主侧的面向对象 —— 对应 cpp/demo/05-object/。
#
# 多文件拆分与 C++ 参考实现同构（demo/05-object/ 目录）：
#   object_model.py（对象模型）、classes.py（类/方法/函数）、object_manager.py
#   （obj:* 域行为）、runtime.py（装配与调用）、doc_visitor.py（STML -> 类与
#   函数）、api.py（Handle 三开口转发）；本文件只留文档、装配与入口。
#   设计推导见 cpp/docs/object-oriented.md，Python 侧差异见 docs/object-oriented.md。
#
# 运行：python demo/05-object.py（仓库根目录）
#
# Stope 的值世界里没有对象：类、属性、方法、构造、析构全部长在宿主侧。
# 语言/编译器零改动，BasicVM 只认 Handle（宿主引用）——At 读 / Assign 写 /
# Call 调三个动作经 Api 的 handle_at / handle_assign / handle_call 虚方法
# 转交 ObjectManager。
#
# ★ Python 侧的内存管理（与 C++ demo 的差异，详见 docs/object-oriented.md）：
#   · CPython 是**引用计数即时回收 + gc 模块分代兜环**：最后一个引用一断，
#     对象当场销毁；但**没有手动 free**——del 只断引用，杀不掉仍被引用的对象；
#   · 「手动管理」模拟为：删除标记（deleted）+ 使用检测（用后即报
#     use after free，而不是 C++ 的悬空 UB）；
#   · **析构函数的有效性不受影响**：<delete> 只在显式 obj:delete 时运行，
#     时机确定；对象内存的真正回收交由引用计数/GC——不可达之后立即（计数）
#     或稍后（兜环）发生；
#   · 描述符同样交给回收机制：驱逐缓存后不可达即回收，不需要 C++ 的
#     freeDescs 复用池；bindCache 用两级 dict（对象 -> (成员 id -> 描述符)），
#     键是对象（可哈希、按同一性），驱逐是 O(1) 整组摘除。

import os
import sys

_here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(_here, "05-object"))  # demo 侧模块
sys.path.insert(0, os.path.dirname(_here))            # stope 包（python/）

from stope import (Result, StmlElement, StmlLexer, StmlParser, StmlState, State)  # noqa: E402

from doc_visitor import DocVisitor  # noqa: E402
from runtime import Runtime  # noqa: E402

sys.stdout.reconfigure(encoding="utf-8")

DOC = """
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
"""


def main():
    runtime = Runtime()
    runtime.obj_mgr.max_objects = 4096  # 存活对象上限：忘了 obj:delete 顶到上限时构造器直接报错
    runtime.add_host_function("println", host_println)

    # ---------- 1. STML 解析：代码段标签按 Stope 代码扫 ----------
    lexer = StmlLexer(DOC)
    parser = StmlParser(lexer)
    root = StmlElement()
    if parser.parse(root, content_kind) != Result.Success:
        for e in parser.errors:
            print(e)
        raise SystemExit(1)

    # ---------- 2. 访问文档：构建类、编译函数 ----------
    visitor = DocVisitor()
    try:
        visitor.visit_doc(root, runtime)
        main_func = runtime.find_function("main")
    except RuntimeError as ex:
        print(ex)
        raise SystemExit(1)
    if main_func is None:
        print("no main function")
        raise SystemExit(1)

    # ---------- 3. 装配入口帧：绑定归 Runtime.push_entry_frame ----------
    runtime.push_entry_frame(main_func)

    # ---------- 4. 运行：两种驱动，随时可切 + 手动清理诊断 ----------
    # 限步：run_steps(20) 每帧最多 20 条指令，帧间就是宿主的逻辑帧；方法
    #   调用压帧、返回弹帧，预算跨调用共享——单步调试就把 20 改成 1。
    # 直接：run_all() 一口气跑到帧栈清空。demo 先限步 1 帧，再直接跑完。
    slices = 0
    while slices < 1 and runtime.run_steps(20):
        slices += 1
    runtime.run_all()
    print(f"-- {slices} stepped slice(s), 20 steps each, then RunAll --")
    runtime.obj_mgr.report_live()  # 忘了 obj:delete 的对象在这里现形
    if runtime.had_errors:
        raise SystemExit(1)


# 宿主函数：与 C++ demo 一致——只格式化 Integer / Float / String，其余忽略。
# Python 宿主函数就是栈上的一个值，签名 fn(argv)（参数整包传入）。
def host_println(args):
    parts = []
    for a in args:
        if isinstance(a, str):
            parts.append(a)
        elif isinstance(a, int):
            parts.append(str(a))
        elif isinstance(a, float):
            parts.append(_fmt_float(a))
    print("".join(parts))
    return None


def _fmt_float(v):
    # 浮点按 C++ iostream 默认精度（6 位有效数字）的样子打，读起来对得上
    if v == int(v) and abs(v) < 1e15:
        return str(int(v))
    return f"{v:.6g}"


def content_kind(tag, _attrs):
    """带 stope 属性的元素按 Stope 代码扫；method/new/delete/func 都要放行。"""
    return StmlState.Stope if tag in ("method", "new", "delete", "func") \
        else StmlState.Xml


if __name__ == "__main__":
    main()
