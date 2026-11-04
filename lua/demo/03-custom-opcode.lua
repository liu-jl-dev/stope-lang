-- demo 03-custom-opcode.lua：自定义指令 —— 登记几条自己的指令，编译并反汇编。
--
-- 项目只规定 33 条内置指令和 Program 的编码契约；再往上加是宿主自己的事，三步：
--
--   1. 用 CustomOpcodeConfig 登记「名字 -> (编号, 参数个数)」；
--   2. 【同一份 config 同时交给 Parser 和 Compiler】—— Parser 靠它把名字识别成
--      Custom token（查不到就只是个普通标识符），Compiler 靠它查编号与参数个数；
--   3. 产物里就只是一串 number —— 编号什么含义、谁来执行，全由宿主决定。
--
-- 本 demo 不运行程序：自定义指令在 stope.basic_vm 里默认没有实现 —— 那是内置的
-- 基础虚拟机（会一直维护，但不是标准的一部分），默认只有那 33 项；要跑自定义指令
-- 用 Api:set_opcode 装处理函数。
--
-- 运行：lua demo/03-custom-opcode.lua

-- 定位本文件，把 lua/ 挂进 package.path（任何 cwd 都能跑）
local src = debug.getinfo(1, "S").source
if string.sub(src, 1, 1) == "@" then src = string.sub(src, 2) end
src = src:gsub("\\", "/")
local demo_dir = src:match("^(.*)/[^/]+$") or "."
local root = demo_dir:match("^(.*)/demo$") or demo_dir
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local stope = require("stope")

local SRC = [[
let x = 3;

my:add(x, 4);        // 定长 2 参
my:log("x =", x);    // 变长 2 参
my:log();            // 变长 0 参
my:halt();           // 定长 0 参

return x;
]]

--- 编译一份源码，返回 (program, 错误列表)。config 可空。
local function compile_src(src_code, config)
    local lexer = stope.Lexer.new(src_code)
    local parser = stope.Parser.new(lexer, config)
    local tree = stope.AST.Prog()
    parser:parse_program(tree)

    local program = stope.Program.new()
    local compiler = stope.Compiler.new(config) -- 配置只在构造时注入一次
    compiler:compile(tree, program)
    local errs = {}
    for _, e in ipairs(lexer.errors) do errs[#errs + 1] = e end
    for _, e in ipairs(parser.errors) do errs[#errs + 1] = e end
    for _, e in ipairs(compiler.errors) do errs[#errs + 1] = e end
    return program, errs
end

local function main()
    -- ---------------- 1. 登记 ----------------
    -- arg_num >= 0 定长；< 0（默认 -1）变长，产物里会多写一个「本次调用的参数个数」。
    local config = stope.opcode.CustomOpcodeConfig()
    print("[1] 登记自定义指令：")
    config:add_custom_opcode("my:add", stope.opcode.kFirstCustomOpcode + 0, 2)
    config:add_custom_opcode("my:log", stope.opcode.kFirstCustomOpcode + 1, -1)
    config:add_custom_opcode("my:halt", stope.opcode.kFirstCustomOpcode + 2, 0)
    for _, name in ipairs(config._order) do -- 按登记顺序（dict 是插入序）
        local info = config.opcodes[name]
        local kind = info.is_var_arg and "变长" or string.format("定长 %d 参", info.arg_num)
        print(string.format("  %s -> #%d（%s）", name, info.opcode, kind))
    end

    -- ---------------- 2. 编译 + 反汇编 ----------------
    -- 反汇编要认出这些指令，必须拿到同一份 config（否则只能印 Custom#编号）。
    local program, errors = compile_src(SRC, config)
    print("\n[2] 编译结果：")
    if #errors > 0 then
        error(table.concat(errors, "\n"))
    end
    print(stope.disasm(program, config))

    -- ---------------- 3. 对照：名字没登记就只是普通调用 ----------------
    -- 词法器只有在 config 里查得到名字时才吐 Custom token，否则 "my:add" 就是个普通
    -- 标识符 —— 编译成 Call，即「调用一个名叫 my:add 的宿主函数」。
    local plain = compile_src("my:add(1, 2);", nil)
    print("\n[3] 同样的调用，不传 config：")
    print(stope.disasm(plain))

    -- ---------------- 4. 参数个数不符 ----------------
    -- 定长指令的参数量在编译期校验；报错后 compile() 会把 program 复原为空。
    local bad, bad_errors = compile_src("my:add(1);", config)
    print("\n[4] 定长 2 参却只给 1 个：")
    for _, e in ipairs(bad_errors) do
        print("  " .. e)
    end
    print(string.format("  -> 编译失败，Program 已清空（opcodes 剩 %d 个 number）",
        #bad.opcodes))

    -- ---------------- 5. 陷阱：编号撞到内置指令 ----------------
    -- 编号必须 >= kFirstCustomOpcode，否则与内置指令无法区分：编译器写出的仍是同一个
    -- number，disasm() 只能按内置指令解码，并把它报成 warning。
    local collide = stope.opcode.CustomOpcodeConfig()
    collide:add_custom_opcode("my:steal", stope.opcode.Opcode.Add, 2)
    local stolen = compile_src("my:steal(1, 2);", collide)
    print("\n[5] 用内置 Add 的编号注册 my:steal：")
    print(stope.disasm(stolen, collide))
    print("  -> 反汇编只认得出 Add：my:steal 这个名字已经丢了。")
end

main()
