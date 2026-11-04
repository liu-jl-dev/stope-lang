-- demo 01-quick-start.lua：编译一段 Stope 源码，再把它跑起来。
--
-- Stope 只规定三件事：语言、STML、编译产物 Program，不规定虚拟机。所以下面
-- 两个阶段性质不同：
--
--   1. 编译：Lexer / Parser / Compiler / Program —— 编译器接口，
--      Program 有明确的编码契约，宿主可以依赖（也可以照抄）。
--   2. 执行：stope.basic_vm —— 内置的【基础虚拟机】，会一直维护、接口不随意改，
--      但不属于标准；值的表示、栈布局、宿主函数绑定都是它自己的选择。
--
-- 运行：lua demo/01-quick-start.lua

-- 定位本文件，把 lua/ 挂进 package.path（任何 cwd 都能跑）
local src = debug.getinfo(1, "S").source
if string.sub(src, 1, 1) == "@" then src = string.sub(src, 2) end
src = src:gsub("\\", "/")
local demo_dir = src:match("^(.*)/[^/]+$") or "."
local root = demo_dir:match("^(.*)/demo$") or demo_dir
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local stope = require("stope")
local utf = stope.utf

local SRC = [[
// example: sum all arguments

let result = 0.0;
let i = 0;
while i < argc {
  result = result + args[i];
  i = i + 1;
}

fmt:println("结果为: ", result);
return result;
]]

local MyArgs = setmetatable({}, { __index = stope.Arguments })
MyArgs.__index = MyArgs
function MyArgs.new(values)
    return setmetatable({ data = values }, MyArgs)
end
function MyArgs:at(_state, index_or_key)
    return self.data[index_or_key + 1] -- 真取不到时：先 state.error("...") 再返回 nil
end
function MyArgs:num()
    return #self.data
end

--- 浮点按 %g 打印（15.0 -> "15"），与库里的 fmt_g 一致。
local function fmt(v)
    if math.type(v) == "float" then
        return stope.fmt_g(v)
    elseif v == stope.NULL then
        return "null"
    elseif math.type(v) == "integer" then
        return string.format("%d", v)
    elseif stope.is_str_value(v) then
        return utf.utf16_to_utf8(stope.str_bytes(v))
    end
    return tostring(v)
end

--- 宿主函数。签名统一是 fn(argv) -> 值：参数整包进来，自己拆。
--- 函数本身就是值 —— 塞进变量槽，Call 指令就能调到它。
local function println(argv)
    local parts = {}
    for _, a in ipairs(argv) do
        parts[#parts + 1] = fmt(a)
    end
    print("[Host] " .. table.concat(parts))
end

local function main()
    -- ---------------- 1. 编译：源码 -> Program ----------------
    local lexer = stope.Lexer.new(SRC)
    local parser = stope.Parser.new(lexer) -- 第二参是 CustomOpcodeConfig，这里没有自定义指令
    local tree = stope.AST.Prog()
    parser:parse_program(tree)

    local compiler = stope.Compiler.new()
    local program = stope.Program.new()
    if compiler:compile(tree, program) ~= stope.Result.Success then
        -- 三个环节都不抛异常，错误各自攒在 .errors 里；编译失败时 program 已被清空
        local errs = {}
        for _, e in ipairs(lexer.errors) do errs[#errs + 1] = e end
        for _, e in ipairs(parser.errors) do errs[#errs + 1] = e end
        for _, e in ipairs(compiler.errors) do errs[#errs + 1] = e end
        error(table.concat(errs, "\n"))
    end

    print(stope.disasm(program)) -- 看一眼编出来的字节码

    -- ---------------- 2. 执行：Program -> 结果 ----------------
    -- 从这里开始是内置的基础虚拟机，不属于标准；换一个执行器，这段可以整个换掉。
    local state = stope.State.new()
    state:reset(stope.Api.new(), program, MyArgs.new({ 1.0, 2.0, 3.0, 4.0, 5.0 }))

    -- 未声明的 fmt:println 被编译器当作外部变量登记进 exports；
    -- 按名字取到槽位，填上宿主函数即可。
    state.variables[program.exports["fmt:println"]] = println

    if state:run() ~= stope.Result.Success then
        error(table.concat(state.errors, "\n"))
    end
    print("result: " .. fmt(state.returns[1]))
end

main()
