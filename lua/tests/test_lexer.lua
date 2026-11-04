-- test_lexer.lua —— 词法：全部由 golden_lex.txt（147 条，C++ 探针 dump）驱动。
-- 每条用例断言四件事：TOKS / LEXEMES / ERRN / ERRS。

local stope = require("stope")
local common = stope.common
local golden = require("tests.golden")

local T = stope.TokenType

--- golden 里所有用例都带着这两条自定义指令（与 cpp/tools/golden.cpp 的 g_cfg 一致）
local CFG = stope.opcode.CustomOpcodeConfig()
CFG:add_custom_opcode("myop", 100, 2)
CFG:add_custom_opcode("vop", 101, -1)

local LEXEME_TYPES = {
    [T.Integer] = true, [T.Float] = true, [T.String] = true, [T.BinArr] = true,
}

--- 扫到底，返回 (TOKS, LEXEMES, ERR_N, ERRS) 四个字段的实际值。
local function one(src)
    local lx = stope.Lexer.new(src)
    local toks = {}
    local lexemes = {}
    for i = 0, 9999 do
        local t = lx:next_token(CFG)
        local s = stope.type_name(t.type) .. "(" .. string.format("%d", t.line) .. ")"
        if t.parsed ~= "" then
            if t.type == T.String then
                s = s .. "[" .. common.esc_lex_u16(t.parsed) .. "]"
            else
                s = s .. "[" .. common.esc_u8(t.parsed, { vf = true, pass_nonascii = true }) .. "]"
            end
        end
        if t.type == T.Integer then
            s = s .. "=" .. string.format("%d", t.value)
        elseif t.type == T.Float then
            s = s .. "=" .. common.fmt_g(t.value)
        end
        toks[#toks + 1] = s
        if LEXEME_TYPES[t.type] then
            lexemes[#lexemes + 1] = string.format("%d", i) .. ":"
                .. common.esc_u8(t.lexeme, { vf = true, pass_nonascii = true })
        end
        if t.type == T.Eof then
            break
        end
    end
    return table.concat(toks, " "), table.concat(lexemes, ","),
        #lx.errors, golden.join_esc(lx.errors)
end

local function run(rep)
    -- ⚠ 这个文件的 TOKS / LEXEMES / ERRS 不做二次转义：直接就是 esc_lex 形态，
    -- 只有 SRC 是转义过的（且转义表里多 \v \f）。
    local cases = golden.read_golden("golden_lex.txt", false)
    if #cases == 0 then
        rep:add_fail("词法", "golden_lex.txt 一条都没读到")
        return
    end
    rep.case_count = #cases
    for _, c in ipairs(cases) do
        local cid = c.ID or ""
        local src = golden.unescape_lex(c.SRC or "")
        local toks, lexemes, errn, errs = one(src)
        rep:check(cid, "TOKS", c.TOKS or "", toks)
        rep:check(cid, "LEXEMES", c.LEXEMES or "", lexemes)
        rep:check(cid, "ERRN", c.ERRN or "", string.format("%d", errn))
        rep:check(cid, "ERRS", c.ERRS or "", errs)
    end
end

return { run = run }
