-- test_disasm.lua —— 反汇编：golden_disasm.txt（12 条）。逐字节比 disasm 的完整输出。

local stope = require("stope")
local golden = require("tests.golden")

local Opcode = stope.opcode.Opcode

--- 与探针里的 g_cfg 一致：myop #100（2 个参数）/ vop #101（变长）
local MAIN_CFG = stope.opcode.CustomOpcodeConfig()
MAIN_CFG:add_custom_opcode("myop", 100, 2)
MAIN_CFG:add_custom_opcode("vop", 101, -1)

--- 故意撞内置 Add
local COLLIDE_CFG = stope.opcode.CustomOpcodeConfig()
COLLIDE_CFG:add_custom_opcode("my:steal", Opcode.Add, 2)

local function run(rep)
    local cases = golden.read_golden("golden_disasm.txt")
    if #cases == 0 then
        rep:add_fail("反汇编", "golden_disasm.txt 一条都没读到")
        return
    end
    rep.case_count = #cases
    for _, rec in ipairs(cases) do
        local cid = rec.ID or ""
        local cfg_name = rec.CFG or "none"
        local cfg = ({ main = MAIN_CFG, collide = COLLIDE_CFG })[cfg_name]

        local got
        if (rec.MODE or "") == "src" then
            -- SRC 是 E_(escUtf8(源码))，要解两层
            local src = golden.unescape(rec.SRC or "")
            local tree = stope.AST.Prog()
            stope.Parser.new(stope.Lexer.new(src), cfg):parse_program(tree)
            local prog = stope.Program.new()
            stope.Compiler.new(cfg):compile(tree, prog)
            got = stope.disasm(prog, cfg)
        else
            -- raw：直接给指令流，不经过前端
            local prog = stope.Program.new()
            for s in string.gmatch(rec.OPS or "", "([^,]*)") do
                if s ~= "" then
                    prog.opcodes[#prog.opcodes + 1] = tonumber(s)
                end
            end
            prog.variable_num = tonumber(rec.VARS or "0") or 0
            got = stope.disasm(prog, cfg)
        end
        rep:check(cid, "DIS", rec.DIS or "", got)
    end

    -- ---- 单测：这四条锁的是「golden 恰好看不出差别」的细节 ----
    rep:check_true("DISP-NOCUSTOM", "disasm_no_custom 等价于 disasm(prog, nil)",
        stope.disasm_no_custom(stope.Program.new())
            == stope.disasm(stope.Program.new(), nil))

    -- OpcodeHasArg 的分档：PushInt..At 与 If/GoTo/Return 带操作数
    local want_arg = {}
    for op = Opcode.PushInt, Opcode.At do
        want_arg[op] = true
    end
    want_arg[Opcode.If] = true
    want_arg[Opcode.GoTo] = true
    want_arg[Opcode.Return] = true
    local bad = {}
    for op = 0, 32 do
        if require("stope.disasm").opcode_has_arg(op) ~= (want_arg[op] == true) then
            bad[#bad + 1] = op
        end
    end
    rep:check_true("DISP-ARG", "opcode_has_arg 的分档：" .. table.concat(bad, ","), #bad == 0)

    -- 只有变长自定义指令才带操作数
    local function custom_has_arg(op)
        local cfg = stope.opcode.CustomOpcodeConfig()
        cfg:add_custom_opcode("x", op, (op == 101) and -1 or 2)
        return require("stope.disasm").custom_opcode_has_arg(op, cfg)
    end
    rep:check_true("DISP-CUSTOM-ARG", "定长指令不带操作数", not custom_has_arg(100))
    rep:check_true("DISP-CUSTOM-ARG", "变长指令带操作数", custom_has_arg(101))

    -- custom opcodes 段按【编号】排序，不是名字序
    local cfg = stope.opcode.CustomOpcodeConfig()
    cfg:add_custom_opcode("a_first", 101, -1) -- 名字序在前，编号在后
    cfg:add_custom_opcode("b_second", 100, 2) -- 名字序在后，编号在前
    local prog = stope.Program.new()
    prog.opcodes = { 101, 0, 100, 3 }
    local text = stope.disasm(prog, cfg)
    local table_part = string.sub(text, (string.find(text, "custom opcodes:", 1, true)))
    rep:check_true("DISP-SORT", "custom opcodes 段按编号排序（100 在 101 之前）",
        string.find(table_part, "b_second", 1, true)
            < string.find(table_part, "a_first", 1, true))
end

return { run = run }
