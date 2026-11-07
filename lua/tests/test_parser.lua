-- test_parser.lua —— 语法：golden.txt（216 条）+ 嵌套深度上限。
-- 每条用例断言六件事：AST 形状串、语句行号序列、语法 / 词法错误条数与文案。

local stope = require("stope")
local golden = require("tests.golden")

--- golden 里所有用例都带着这两条自定义指令（与 cpp/tools/golden.cpp 的 g_cfg 一致）
local CFG = stope.opcode.CustomOpcodeConfig()
CFG:add_custom_opcode("myop", 100, 2)
CFG:add_custom_opcode("vop", 101, -1)

local CFG_for_compiler = CFG -- test_compiler 复用

--- 跑一条 golden 用例：词法 -> 语法，把结果摊平成与记录同名的字段。
--- ⚠ SRC 要解【两】层转义：golden 里存的是 E_(escUtf8(源码))。
local function run_case(rec)
    local src = golden.unescape(rec.SRC or "")
    local fold = (rec.FOLD or "") == "1"

    local lx = stope.Lexer.new(src)
    local ps = stope.Parser.new(lx, CFG)
    ps.const_folding = fold
    local tree = stope.AST.Prog()
    ps:parse_program(tree)

    local lines = {}
    for _, s in ipairs(tree.stmts) do
        lines[#lines + 1] = string.format("%d", s.line)
    end
    return {
        SRC = src,
        SHAPE = stope.ast.shape_prog(tree),
        LINES = table.concat(lines, ","),
        PERR = string.format("%d", #ps.errors),
        PERRS = golden.join_esc(ps.errors),
        LEXERR = string.format("%d", #lx.errors),
        LEXERRS = golden.join_esc(lx.errors),
        tree = tree,
    }
end

local function run(rep)
    local cases = golden.read_golden("golden.txt")
    if #cases == 0 then
        rep:add_fail("语法", "golden.txt 一条都没读到")
        return
    end
    rep.case_count = #cases
    rep:check_int("golden.txt", "用例数", 216, #cases)
    for _, rec in ipairs(cases) do
        local cid = rec.ID or ""
        local got = run_case(rec)
        rep:check(cid, "SHAPE", rec.SHAPE or "", got.SHAPE)
        rep:check(cid, "LINES", rec.LINES or "", got.LINES)
        rep:check(cid, "PERR", rec.PERR or "", got.PERR)
        rep:check(cid, "PERRS", rec.PERRS or "", got.PERRS)
        rep:check(cid, "LEXERR", rec.LEXERR or "", got.LEXERR)
        rep:check(cid, "LEXERRS", rec.LEXERRS or "", got.LEXERRS)
    end
end

-- ---------------- 嵌套深度上限 ----------------
-- 期望值不 dump：限额与错误文案是四方约定，所以按约定写死。
local function depth_source(kind, n)
    -- 块里要有语句，否则永远进不到 parse_expr，深度计数根本没机会检查
    if kind == "paren" then
        return string.rep("(", n) .. "a" .. string.rep(")", n) .. ";"
    elseif kind == "block" then
        return string.rep("{", n) .. "a;" .. string.rep("}", n)
    elseif kind == "unary" then
        return string.rep("-", n) .. "a;"
    elseif kind == "at" then
        return string.rep("a[", n) .. "0" .. string.rep("]", n) .. ";"
    end
    error("unknown kind " .. kind)
end

local function parse_depth(kind, n)
    local ps = stope.Parser.new(stope.Lexer.new(depth_source(kind, n)))
    local tree = stope.AST.Prog()
    ps:parse_program(tree)
    return ps.errors, tree
end

local DEPTH_CASES = {
    { "PD-DEPTH-1", "paren", 200, false },
    { "PD-DEPTH-2", "paren", 300, true },
    { "PD-DEPTH-3", "block", 300, true },
    { "PD-DEPTH-4", "unary", 300, true },
    { "PD-DEPTH-5", "at", 300, true },
    { "PD-DEPTH-6", "paren", 12000, true },
    { "PD-DEPTH-7", "block", 200, false },
    { "PD-DEPTH-8", "unary", 200, false },
    { "PD-DEPTH-9", "at", 200, false },
}

local function run_depth(rep)
    for _, case in ipairs(DEPTH_CASES) do
        local cid, kind, n, deep = case[1], case[2], case[3], case[4]
        local errors, tree = parse_depth(kind, n)
        if not deep then
            rep:check_int(string.format("%s %s %d", cid, kind, n), "错误条数", 0, #errors)
            rep:check_true(cid, "应解析出语句", #tree.stmts > 0)
        else
            -- 超限只报一条（不刷连锁噪音），文案逐字固定
            rep:check_int(string.format("%s %s %d", cid, kind, n), "错误条数", 1, #errors)
            rep:check(cid, "错误文案", "line 1: nesting too deep (max 256). ",
                errors[1] or "<无错误>")
        end
    end

    rep:check_int("PD-DEFAULT", "默认 max_depth", 256,
        stope.Parser.new(stope.Lexer.new("")).max_depth)

    -- max_depth = 0 时不检查：600 层（远超 256）仍能解析
    local ps0 = stope.Parser.new(stope.Lexer.new(depth_source("paren", 600)))
    ps0.max_depth = 0
    local tree0 = stope.AST.Prog()
    ps0:parse_program(tree0)
    rep:check_int("PD-NOLIMIT", "错误条数", 0, #ps0.errors)
    rep:check_int("PD-NOLIMIT", "语句数", 1, #tree0.stmts)
end

return { run = run, run_depth = run_depth, run_case = run_case, CFG = CFG }
