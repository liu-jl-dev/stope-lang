-- demo 05-object.lua：宿主侧的面向对象 —— 对应 cpp/demo/05-object/。
--
-- 多文件拆分与 C++ 参考实现同构（demo/05-object/ 目录）：
--   object_manager.lua（obj:* 域行为）、runtime.lua（装配与调用）、
--   doc_visitor.lua（STML -> 类与函数）；本文件只留文档、装配与入口。
--   设计推导见 cpp/docs/object-oriented.md，Lua 侧差异见 docs/object-oriented.md。
--
-- Stope 的值世界里没有对象：类、属性、方法、构造、析构全部长在宿主侧。
-- 语言/编译器零改动，BasicVM 只认 Handle（宿主引用）——At 读 / Assign 写 /
-- Call 调三个动作经 Api 的 handle_at / handle_assign / handle_call 方法转交
-- ObjectManager。
--
-- 语法（与 cpp demo 逐字一致）：
--   Person:New("Tom", 18)     构造（<Class>:<构造名> 绑定构造描述符）
--   obj:name[p] = "James"     写属性（At 绑定 + Assign 写穿）
--   obj:Introduce[p]()        调方法
--   self:Greet()              方法体内调同对象方法（self 绑定描述符）
--   obj:delete(p)             手动删除：先跑 <delete>，再回收
--
-- ★ Lua 侧的内存管理（与 C++ demo 的差异，详见 docs/object-oriented.md）：
--   · Lua 是**自动内存管理**：5.4 支持增量与分代两种模式的**标记清除 GC**，
--     没有手动 free；__gc 元方法时机由 GC 决定、不保证及时；
--   · 「手动管理」模拟为：删除标记（deleted）+ 使用检测（用后即报
--     use after free，而不是 C++ 的悬空 UB）；
--   · **析构函数的有效性不受影响**：<delete> 只在显式 obj:delete 时运行，
--     时机确定；对象内存的真正回收交由 GC——不可达之后由收集器决定；
--   · 描述符同样交给 GC：驱逐缓存后不可达即回收，不需要 C++ 的 freeDescs
--     复用池；bindCache 用两级表（对象 -> { [成员 id] = 描述符 }），键是
--     table（按同一性哈希），驱逐是整组置 nil，O(1)。

-- 定位本文件，把 lua/ 与 demo/05-object/ 挂进 package.path（任何 cwd 都能跑）
local src = debug.getinfo(1, "S").source
if string.sub(src, 1, 1) == "@" then src = string.sub(src, 2) end
src = src:gsub("\\", "/")
local demo_dir = src:match("^(.*)/[^/]+$") or "."
local root = demo_dir:match("^(.*)/demo$") or demo_dir
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;"
    .. demo_dir .. "/05-object/?.lua;" .. package.path

local stope = require("stope")
local utf = stope.utf
local Runtime = require("runtime")
local DocVisitor = require("doc_visitor")

local DOC = [[
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
]]

-- ==================== 入口 ====================

-- 宿主函数：与 C++ demo 一致——只格式化 Integer / Float / String，其余忽略。
-- Lua 宿主函数就是栈上的一个值，签名 fn(argv)（参数整包传入）。
local function host_println(argv)
    local parts = {}
    for _, a in ipairs(argv) do
        if stope.is_str_value(a) then
            parts[#parts + 1] = utf.utf16_to_utf8(stope.str_bytes(a))
        elseif math.type(a) == "integer" then
            parts[#parts + 1] = string.format("%d", a)
        elseif math.type(a) == "float" then
            parts[#parts + 1] = stope.fmt_g(a)
        end
    end
    print(table.concat(parts))
    return stope.NULL
end

-- 带 stope 属性的元素，内容按 Stope 代码扫；其余按子元素列表（Xml）解析。
local function content_kind(tag, _attrs)
    if tag == "method" or tag == "new" or tag == "delete" or tag == "func" then
        return stope.StmlState.Stope
    end
    return stope.StmlState.Xml
end

local function main()
    local runtime = Runtime.new()
    runtime.obj_mgr.max_objects = 4096 -- 存活对象上限：忘了 obj:delete 顶到上限时构造器直接报错
    runtime:add_host_function("println", host_println)

    -- ---------- 1. STML 解析：代码段标签按 Stope 代码扫 ----------
    local lexer = stope.StmlLexer.new(DOC)
    local parser = stope.StmlParser.new(lexer)
    local root = stope.StmlElement()
    if parser:parse(root, content_kind) ~= stope.Result.Success then
        for _, e in ipairs(parser.errors) do
            print(e)
        end
        os.exit(1)
    end

    -- ---------- 2. 访问文档：构建类、编译函数 ----------
    local visitor = DocVisitor.new()
    local ok, err = pcall(visitor.visit_doc, visitor, root, runtime)
    if not ok then
        print(err)
        os.exit(1)
    end
    local main_func = runtime:find_function("main")
    if main_func == nil then
        print("no main function")
        os.exit(1)
    end

    -- ---------- 3. 装配入口帧：绑定归 Runtime.push_entry_frame ----------
    runtime:push_entry_frame(main_func)

    -- ---------- 4. 运行：两种驱动，随时可切 + 手动清理诊断 ----------
    -- 限步：run_steps(20) 每帧最多 20 条指令，帧间就是宿主的逻辑帧——方法
    --   调用压帧、返回弹帧，预算跨调用共享。单步调试就把 20 改成 1。
    -- 直接：run_all() 一口气跑到帧栈清空。demo 先限步 1 帧（点出「每帧
    --   限步」是驱动方式而非程序属性），再直接执行跑完剩下的。
    local slices = 0
    while slices < 1 and runtime:run_steps(20) do
        slices = slices + 1
    end
    runtime:run_all()
    print("-- " .. slices .. " stepped slice(s), 20 steps each, then RunAll --")
    runtime.obj_mgr:report_live() -- 忘了 obj:delete 的对象在这里现形
    if runtime.had_errors then
        os.exit(1)
    end
end

main()
