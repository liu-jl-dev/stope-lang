-- demo 04-pre-export.lua：预导出（preExports）—— 宿主先把形参塞进作用域，再编译函数体。
--
-- 场景：STML 文档里定义函数，参数表写在标签属性上（params="a b"），函数体是
-- Stope 源码。编译函数体时把 params 里的名字当 preExports 传进去，它们就先占好槽位、
-- 进 Program.exports；宿主在 run() 之前把实参写进这些槽位，函数体里的 a、b
-- 直接就能读到。
--
-- 为什么不靠「未声明标识符自动导出」？那条路也行，但导出的是【函数体里用到的名字】，
-- 顺序取决于出现位置、没用到的形参根本不会存在。预导出让「参数表」只有一份、且顺序
-- 固定为标签里写的顺序，宿主可以照参数表直接写槽位。
--
-- 运行：lua demo/04-pre-export.lua

-- 定位本文件，把 lua/ 挂进 package.path（任何 cwd 都能跑）
local src = debug.getinfo(1, "S").source
if string.sub(src, 1, 1) == "@" then src = string.sub(src, 2) end
src = src:gsub("\\", "/")
local demo_dir = src:match("^(.*)/[^/]+$") or "."
local root = demo_dir:match("^(.*)/demo$") or demo_dir
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local stope = require("stope")

local DOC = [[
<stml>
<func name="add" params="a b" stope>
    return a + b;
</func>
</stml>
]]

--- 带 stope 属性的元素，内容按 Stope 代码扫；切出来的 text 就是原样源码。
local function content_kind(_tag, attrs)
    if attrs["stope"] ~= nil then
        return stope.StmlState.Stope
    end
    return stope.StmlState.Xml
end

--- 按名字找子元素。
local function child(ele, tag)
    for _, c in ipairs(ele.children) do
        if c.tag == tag then return c end
    end
    return nil
end

--- 编译一段源码，pre_exports 原样交给 Compiler。失败时打印错误并返回 false。
--- start_line 是 src 首行的物理行号 —— 从 STML 切出来的代码段不是从 1 开始，设给
--- lexer 之后报错行号才和文档对得上（这里直接从 fn.text_line 取）。
local function compile_src(src_code, start_line, pre_exports, out)
    local lexer = stope.Lexer.new(src_code)
    lexer.line = start_line
    local parser = stope.Parser.new(lexer)
    local tree = stope.AST.Prog()
    parser:parse_program(tree)
    for _, e in ipairs(lexer.errors) do
        print("  lexer: " .. e)
    end
    for _, e in ipairs(parser.errors) do
        print("  parser: " .. e)
    end

    local compiler = stope.Compiler.new()
    local rc = compiler:compile(tree, out, pre_exports)
    for _, e in ipairs(compiler.errors) do
        print("  compiler: " .. e)
    end
    return rc == stope.Result.Success and #lexer.errors == 0 and #parser.errors == 0
end

--- exports 按槽位号排序打印（与插入序一致，因为 new_unique_var 递增编号）。
local function exports_text(program)
    local names = {}
    for k in pairs(program.exports) do
        names[#names + 1] = k
    end
    table.sort(names, function(a, b)
        return program.exports[a] < program.exports[b]
    end)
    local parts = {}
    for _, k in ipairs(names) do
        parts[#parts + 1] = k .. "=" .. string.format("%d", program.exports[k])
    end
    return table.concat(parts, " ")
end

local function main()
    -- ---------------- 1. 从 STML 里取出函数定义 ----------------
    local lexer = stope.StmlLexer.new(DOC)
    local parser = stope.StmlParser.new(lexer)
    local root = stope.StmlElement()
    if parser:parse(root, content_kind) ~= stope.Result.Success then
        local errs = {}
        for _, e in ipairs(lexer.errors) do errs[#errs + 1] = e end
        for _, e in ipairs(parser.errors) do errs[#errs + 1] = e end
        error(table.concat(errs, "\n"))
    end

    local fn = child(root, "func")
    local name = fn.attrs["name"]
    local params = {}
    for p in fn.attrs["params"]:gmatch("%S+") do -- "a b" -> {"a", "b"}
        params[#params + 1] = p
    end
    print("[1] 从 <func> 取出：" .. name .. "(" .. table.concat(params, ", ") .. ")")

    -- ---------------- 2. 用参数表当 preExports 编译 ----------------
    -- 形参先占槽位（a=0、b=1），函数体里的 a、b 于是解析到文件作用域 ——
    -- 反汇编里是 PushValue(0) / PushValue(1)。
    local program = stope.Program.new()
    print("\n[2] 编译函数体（preExports = 形参表）：")
    if not compile_src(fn.text, fn.text_line, params, program) then
        os.exit(1)
    end
    print(stope.disasm(program))
    print("  exports: " .. exports_text(program))

    -- ---------------- 3. 塞实参、运行 ----------------
    -- 编译期就知道槽位，所以 run() 之前就能把值写进去 —— 这才是预导出的用处：
    -- 宿主的「调用」就是写变量 + 跑一遍，不需要额外的参数传递机制。
    local state = stope.State.new()
    state:reset(stope.Api.new(), program)
    state.variables[program.exports["a"]] = 3
    state.variables[program.exports["b"]] = 4

    state:run()
    print(string.format("\n[3] add(3, 4) = %d", state.returns[1]))

    -- ---------------- 4. 陷阱：预导出的名字不能再声明 ----------------
    -- 名字已经进了文件作用域，源码里再 export 同名、或顶层 let 同名，都是 duplicate。
    -- 预导出的变量只能赋值（a = 1;），不能重新声明。
    print("\n[4] 函数体里又写 export a;：")
    compile_src("export a; return a;", 1, params, stope.Program.new())
end

main()
