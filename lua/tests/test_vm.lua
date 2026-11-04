-- test_vm.lua —— 参考执行器：值语义 + 两条驱动路径。没有 golden 数据。
--
-- 1. run 与 step 一致 —— 两条独立实现（热循环不套函数调用），连走的条数都一样；
-- 2. 与另外五份实现同一种答案 —— 算术 / 序列 / 真值 / 除零 / 回绕 / 相等。

local stope = require("stope")
local common = stope.common
local utf = stope.utf
local golden = require("tests.golden")

local Result = stope.Result
local Opcode = stope.opcode.Opcode
local disasm_mod = require("stope.disasm")

-- ============================== 夹具 ==============================

--- 这组用例都不用 args / argc；真被取到就报错，立刻暴露「用例写错了」。
local NoArgs = setmetatable({}, { __index = stope.Arguments })
NoArgs.__index = NoArgs
function NoArgs.new()
    return setmetatable({}, NoArgs)
end
function NoArgs:at(state, _index_or_key)
    state:error("args not provided in this test. ")
    return nil
end
function NoArgs:num()
    return 0
end

local ArrayArgs = setmetatable({}, { __index = stope.Arguments })
ArrayArgs.__index = ArrayArgs
function ArrayArgs.new(data)
    return setmetatable({ _data = data }, ArrayArgs)
end
function ArrayArgs:at(state, index_or_key)
    if math.type(index_or_key) ~= "integer" or index_or_key < 0
        or index_or_key >= #self._data then
        state:error("argument out of range. ")
        return nil
    end
    return self._data[index_or_key + 1]
end
function ArrayArgs:num()
    return #self._data
end

local function compile(src, custom)
    -- 编译；成功返回 (Program, nil)，失败返回 (nil, 错误列表)
    local ps = stope.Parser.new(stope.Lexer.new(src), custom)
    local tree = stope.AST.Prog()
    ps:parse_program(tree)
    local out = stope.Program.new()
    local c = stope.Compiler.new(custom)
    c:compile(tree, out)
    local errs = {}
    for _, e in ipairs(ps.errors) do errs[#errs + 1] = e end
    for _, e in ipairs(c.errors) do errs[#errs + 1] = e end
    if #errs > 0 then
        return nil, errs
    end
    return out, nil
end

local function state_new(prog, args)
    -- 装配 State 但不执行 —— 宿主函数要先往 variables 里塞值
    local s = stope.State.new()
    s:set_api(stope.Api.new())
    s:set_program(prog)
    s:set_arguments(args)
    return s
end

local function build(src, args, custom)
    local prog, errs = compile(src, custom)
    if prog == nil then
        return nil, errs
    end
    local s = state_new(prog, args)
    s:run()
    return s, nil
end

local function fmt(v)
    -- 紧凑写法：null / 整数 / 浮点（无小数点时补 .0）/ 字符串原样 / 字节数组 [1,2]
    if v == stope.NULL then
        return "null"
    end
    local mt = math.type(v)
    if mt == "integer" then
        return string.format("%d", v)
    end
    if mt == "float" then
        if v ~= v then return "nan" end
        if v == math.huge then return "inf" end
        if v == -math.huge then return "-inf" end
        local t = common.fmt_g(v)
        if not string.find(t, ".", 1, true) and not string.find(t, "e", 1, true) then
            t = t .. ".0"
        end
        return t
    end
    if stope.is_str_value(v) then
        return utf.utf16_to_utf8(stope.str_bytes(v))
    end
    if type(v) == "string" then
        local parts = {}
        for i = 1, #v do
            parts[#parts + 1] = string.format("%d", string.byte(v, i))
        end
        return "[" .. table.concat(parts, ",") .. "]"
    end
    return "<other>"
end

local function fmt_returns(s)
    local parts = {}
    for _, v in ipairs(s.returns) do
        parts[#parts + 1] = fmt(v)
    end
    return "[" .. table.concat(parts, ",") .. "]"
end

local function msg_only(e)
    -- "3 Div: msg" -> "msg"：前缀（下标 + 指令名）由实现决定，跨实现只比消息
    local i = string.find(e, ": ", 1, true)
    if i == nil then return e end
    return string.sub(e, i + 2)
end

local function inst_count(p)
    -- 产物里有几条指令（跳过操作数格）—— 与「走了几步」对照用
    local n = 0
    local i = 1 -- 1 起数组
    local ops = p.opcodes
    while i <= #ops do
        n = n + 1
        if disasm_mod.opcode_has_arg(ops[i]) then
            i = i + 2
        else
            i = i + 1
        end
    end
    return n
end

local function returns(rep, cid, src, want)
    local s, errs = build(src)
    if s == nil then
        rep:add_fail(cid, "编译失败：" .. src .. " | " .. table.concat(errs))
        return
    end
    rep:check(cid, "returns", want, fmt_returns(s))
    rep:check(cid, "errors", "", table.concat(s.errors, "|"))
end

local function errs(rep, cid, src, want_msg)
    -- 断言报错：只比 ": " 之后的正文（前缀由实现自定）
    local s, build_errs = build(src)
    if s == nil then
        rep:add_fail(cid, "编译失败：" .. src .. " | " .. table.concat(build_errs))
        return
    end
    rep:check_int(cid, "错误条数", 1, #s.errors)
    rep:check(cid, "错误消息", want_msg,
        (#s.errors > 0) and msg_only(s.errors[1]) or "<无错误>")
end

-- ============================== 用例 ==============================

local function host_functions(rep)
    -- 宿主函数：一个值，直接放变量槽（对应 C++ 的 Value::Type::HostFunction）
    local prog, errs = compile("return f(1, 2);")
    if prog == nil then
        rep:add_fail("V-14", "编译失败：" .. table.concat(errs))
    else
        local s = state_new(prog)
        -- 未声明就被调用 -> 编译器隐式登记进 exports；槽位号由编译器分配，不能写死
        s.variables[prog.exports["f"]] = function(argv) return argv[1] + argv[2] end
        local rc = s:run()
        rep:check("V-14", "run 返回", "Success",
            (rc == Result.Success) and "Success" or "Error")
        rep:check("V-14", "returns", "[3]", fmt_returns(s))
    end

    -- 宿主函数返回 bool：归一成整数（Stope 没有布尔值类型）
    local prog2, errs2 = compile("return g();")
    if prog2 == nil then
        rep:add_fail("V-14b", "编译失败：" .. table.concat(errs2))
    else
        local s2 = state_new(prog2)
        s2.variables[prog2.exports["g"]] = function(_argv) return true end
        s2:run()
        rep:check("V-14b", "returns", "[1]", fmt_returns(s2))
        rep:check("V-14b", "returns[0] 类型", "integer", math.type(s2.returns[1]) or "nil")
    end

    -- Call 到非函数
    local s3 = build("let x = 1; return x(2);")
    if s3 == nil then
        rep:add_fail("V-17", "编译失败")
    else
        rep:check_int("V-17", "错误条数", 1, #s3.errors)
        rep:check("V-17", "错误消息", '"Call" can only call a function. ',
            (#s3.errors > 0) and msg_only(s3.errors[1]) or "<无错误>")
    end
end

local function arguments(rep)
    -- argc + args[i]
    local s = build("return argc + args[0];", ArrayArgs.new({ 2 }))
    if s == nil then
        rep:add_fail("V-18", "编译失败")
    else
        rep:check("V-18", "returns", "[3]", fmt_returns(s)) -- argc(1) + args[0](2)
    end

    -- 没给实参表
    local s2 = build("return argc;", nil)
    if s2 == nil then
        rep:add_fail("V-19", "编译失败")
    else
        rep:check_int("V-19", "错误条数", 1, #s2.errors)
        rep:check("V-19", "错误消息", "no args. ",
            (#s2.errors > 0) and msg_only(s2.errors[1]) or "<无错误>")
    end

    -- 实参表越界由宿主自己报错
    local s3 = build("return args[5];", ArrayArgs.new({ 1 }))
    if s3 == nil then
        rep:add_fail("V-20", "编译失败")
    else
        rep:check_int("V-20", "错误条数", 1, #s3.errors)
        rep:check("V-20", "错误消息", "argument out of range. ",
            (#s3.errors > 0) and msg_only(s3.errors[1]) or "<无错误>")
    end

    -- 宿主 at() 里报错之后执行器必须停：错误进同一个 errors，且定位到 GetArg 那条
    local prog = compile("return args[0];")
    local opts
    if prog == nil then
        rep:add_fail("V-04", "编译失败")
        return
    end
    opts = state_new(prog, NoArgs.new())
    local rc = opts:run()
    rep:check("V-04", "run 返回", "Error", (rc == Result.Success) and "Success" or "Error")
    rep:check_int("V-04", "错误条数", 1, #opts.errors)
    rep:check("V-04", "错误消息", "args not provided in this test. ",
        (#opts.errors > 0) and msg_only(opts.errors[1]) or "<无错误>")
    rep:check_true("V-04", "停机在 GetArg 上",
        opts.i < #prog.opcodes and prog.opcodes[opts.i + 1] == Opcode.GetArg)
end

local function error_index(rep)
    -- 错误串前缀是 "<指令下标>: " —— 下标就是出错那条指令在产物里的位置
    local s = build("return 1 / 0;")
    if s == nil or #s.errors ~= 1 then
        rep:add_fail("V-16", "`return 1 / 0;` 应当恰好报一条错")
        return
    end
    -- 产物是 PushInt(0) PushInt(1) Div Return(1) —— Div 在下标 4（操作数各占一格）
    rep:check_true("V-16", '错误串形如 "4: ..."：' .. s.errors[1],
        string.sub(s.errors[1], 1, #"4: \"Div\" division by zero. ")
            == '4: "Div" division by zero. ')
end

local function custom_opcode(rep)
    -- 自定义指令（编号 >= 33）能跑、能报错，且 set_opcode 会把中间补齐
    local cfg = stope.opcode.CustomOpcodeConfig()
    cfg:add_custom_opcode("my:boom", stope.opcode.kFirstCustomOpcode, 0)
    local prog, errs = compile("my:boom();", cfg)
    if prog == nil then
        rep:add_fail("V-05", "编译失败：" .. table.concat(errs))
        return
    end

    local function boom(s)
        s:error("boom. ")
    end

    local api = stope.Api.new()
    api:set_opcode(stope.opcode.kFirstCustomOpcode, boom)
    local s = stope.State.new()
    s:set_api(api)
    s:set_program(prog)
    s:set_arguments(NoArgs.new())
    local rc = s:run()
    rep:check("V-05", "run 返回", "Error", (rc == Result.Success) and "Success" or "Error")
    rep:check_int("V-05", "错误条数", 1, #s.errors)
    rep:check("V-05", "错误全文", "0: boom. ", table.concat(s.errors, "|"))

    -- 跳号注册：33 是刚注册的，34/35 必须补成占位函数而不是留空
    local api2 = stope.Api.new()
    rep:check_int("V-05b", "内置表长度", stope.opcode.kFirstCustomOpcode, #api2.op_map)
    api2:set_opcode(stope.opcode.kFirstCustomOpcode + 2, boom)
    rep:check_int("V-05b", "补齐后长度", stope.opcode.kFirstCustomOpcode + 3, #api2.op_map)
end

local function run_step_equivalence(rep)
    -- run 与 step 是两份独立实现（热循环不套函数调用）。同一批程序跑两遍：
    -- 返回值必须一致，顺序执行时指令条数也必须一致。
    local cases = {
        { "return 1 + 2 * 3;", true },
        { "let a = 1; while a < 5 { a = a + 1; } return a;", false },
        { "let s = 0; let i = 0; while i < 10 { if i % 2 == 0 { s = s + i; } i = i + 1; } return s;",
          false },
        { "let a = 1; let b = 2; return a < b and b < 3;", false },
        { "if 1 { return 10; } else { return 20; }", false },
        { "let x = 0; while { x = x + 1; if x > 3 { break; } } return x;", false },
    }

    for _, case in ipairs(cases) do
        local src, linear = case[1], case[2]
        local cid = "V-21 " .. src
        local prog, errs = compile(src)
        if prog == nil then
            rep:add_fail("V-21", "编译失败：" .. src .. " | " .. table.concat(errs))
        else
            local s1 = state_new(prog)
            s1:run()

            local s2 = state_new(prog)
            local steps = 0
            while s2.i < #prog.opcodes and s2:step() == Result.Success do
                steps = steps + 1
                if steps > 100000 then
                    break
                end
            end

            rep:check(cid, "returns", fmt_returns(s1), fmt_returns(s2))
            rep:check(cid, "errors", table.concat(s1.errors, "|"),
                table.concat(s2.errors, "|"))
            rep:check_true(cid, "step 应把指令流走完", s2.i >= #prog.opcodes)
            rep:check_int(cid, "停机时 i", s1.i, s2.i)
            if linear then
                rep:check_int(cid, "步数应等于指令条数", inst_count(prog), steps)
            end

            -- 停机后再驱动一次：不执行指令、不追加错误
            local err_before = #s2.errors
            local i_before = s2.i
            local again = s2:step()
            rep:check_true(cid, "停机后 step 返回 Success（什么都不做）",
                again == Result.Success)
            rep:check_int(cid, "停机后 i 不变", i_before, s2.i)
            rep:check_int(cid, "停机后 errors 不变", err_before, #s2.errors)
        end
    end
end

local function run(rep)
    -- ==================== 布尔就是整数 1 / 0 ====================
    returns(rep, "V-06", "return true;", "[1]")
    returns(rep, "V-06b", "return false;", "[0]")
    returns(rep, "V-06c", "let t = true; let f = false; return t + f + (1 == 1);", "[2]")
    returns(rep, "V-06d", "let a = 1; let b = 2; return a < b;", "[1]")

    -- ==================== 整数幂：回绕 / 负指数转浮点 ====================
    returns(rep, "V-07", "let a = 2; let b = 64; return a ^ b;", "[0]")
    returns(rep, "V-07b", "let a = 2; return a ^ -1;", "[0.5]")
    -- 负底数 + 分数指数：C++ 是 nan（Lua 的 ^ 就是 C pow，直接一致）
    returns(rep, "V-07c", "let a = -8.0; let b = 0.5; return a ^ b;", "[nan]")

    -- ==================== 序列重复与拼接 ====================
    returns(rep, "V-08", 'let s = "ab"; return s * 2;', "[abab]")
    returns(rep, "V-08b", 'let s = "ab"; return 2 * s;', "[abab]")
    returns(rep, "V-08c", "let b = 'd 1 2'; return b * 2;", "[[1,2,1,2]]")
    errs(rep, "V-08d", 'let s = "ab"; let n = -1; return s * n;',
        '"Mul" cannot repeat a sequence by a negative number. ')
    returns(rep, "V-08e", 'let a = "x"; let b = "y"; return a + b;', "[xy]")
    returns(rep, "V-08f", "let a = 'd 1'; let b = 'd 2'; return a + b;", "[[1,2]]")
    errs(rep, "V-08g", "let b = 'd 1'; let n = -2; return b * n;",
        '"Mul" cannot repeat a sequence by a negative number. ')

    -- ==================== 真值 ====================
    returns(rep, "V-09", 'let s = ""; if s { return 1; } return 2;', "[2]")
    returns(rep, "V-09b", 'let s = "x"; if s { return 1; } return 2;', "[1]")
    returns(rep, "V-09c", "let b = 'd'; if b { return 1; } return 2;", "[2]")

    -- ==================== 除零 ====================
    errs(rep, "V-10", "let a = 1; let b = 0; return a / b;", '"Div" division by zero. ')
    errs(rep, "V-10b", "let a = 1; let b = 0; return a idiv b;", '"IDiv" division by zero. ')
    errs(rep, "V-10c", "let a = 1; let b = 0; return a % b;", '"Mod" division by zero. ')
    -- 浮点除零走 IEEE，不报错（1.0 / 0 得 inf）
    returns(rep, "V-10d", "let a = 1.0; let b = 0; return a / b;", "[inf]")
    returns(rep, "V-10e", "let a = 0.0; let b = 0; return a / b;", "[nan]")
    -- 浮点取模同理
    returns(rep, "V-10f", "let a = 1.5; let b = 0; return a % b;", "[nan]")
    returns(rep, "V-10g", "let a = -7.0; let b = 2.0; return a % b;", "[-1.0]")

    -- ==================== `!` 只接受 null / 整数 / 浮点 ====================
    errs(rep, "V-11", 'let s = "abc"; return !s;',
        '"Not" can only operate on integer or float. ')

    -- ==================== INT64_MIN 的三个角落 ====================
    returns(rep, "V-12", "let m = 0 - 9223372036854775807 - 1; return -m;",
        "[-9223372036854775808]")
    returns(rep, "V-12b", "let m = 0 - 9223372036854775807 - 1; return m idiv -1;",
        "[-9223372036854775808]")
    returns(rep, "V-12c", "let m = 0 - 9223372036854775807 - 1; return m % -1;", "[0]")

    -- ==================== idiv：含浮点仍向零取整，但保持浮点 ====================
    returns(rep, "V-13", "let a = 7; let b = 2; return a idiv b;", "[3]")
    returns(rep, "V-13b", "let a = 7.5; let b = 2; return a idiv b;", "[3.0]")
    -- trunc(inf)：C++ 是 inf
    returns(rep, "V-13c", "let a = 1.0; let b = 0; return a idiv b;", "[inf]")

    -- ==================== 相等：类型不同一律不等 ====================
    returns(rep, "V-15", 'let a = "1"; let b = 1; return a == b;', "[0]")
    returns(rep, "V-15b", "let a = null; let b = 0; return a == b;", "[0]")
    returns(rep, "V-15c", "let a = 'd 1 2'; let b = 'd 1 2'; return a == b;", "[1]")
    returns(rep, "V-15d", "let a = 'd 1'; let b = 'd 2'; return a == b;", "[0]")
    returns(rep, "V-15e", 'let a = "ab"; let n = 0; return a * n;', "[]")

    -- ==================== 下标取码元 ====================
    returns(rep, "V-15f", "let b = 'd 1 2'; return b[1];", "[2]")
    -- 取的是 UTF-16 码元：非 BMP 字符（U+1F600）在 C++ / C# / Lua 侧给出高位代理 55357
    returns(rep, "V-15g", 'let s = "\240\159\152\128"; return s[0];', "[55357]")
    errs(rep, "V-15h", "let b = 'd 1'; return b[5];", "index out of range. ")

    -- ==================== 宿主函数 / 实参表 ====================
    host_functions(rep)
    arguments(rep)

    -- ==================== 错误串带指令下标 ====================
    error_index(rep)

    -- ==================== 自定义指令 ====================
    custom_opcode(rep)

    -- ==================== run 与 step 等价 ====================
    run_step_equivalence(rep)
end

return { run = run }
