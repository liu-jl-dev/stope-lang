-- test_stml.lua —— STML：stml_cases.txt（125 条用例清单）+ golden_stml.txt（126 条含 COUNT）。
-- 用例清单也是数据文件；本文件只有「读清单 -> 打本实现 -> 比字段」这一件事。

local stope = require("stope")
local golden = require("tests.golden")

local stml = stope.stml
local stml_lexer = stope.stml_lexer
local stml_parser = stope.stml_parser
local Result = stope.Result

local function state_of(name)
    local S = stml.LexerState
    if name == "Text" then return S.Text end
    if name == "Nevext" then return S.Nevext end
    if name == "Stope" then return S.Stope end
    return S.Xml
end

--- 元素形状串。字段顺序固定：tag、行号、自闭合、属性（字典序）、文本、子元素。
local function shape(e)
    local out = "Elem(" .. golden.esc16(e.tag) .. ", L" .. string.format("%d", e.line)
    if e.self_closing then
        out = out .. ", /"
    end
    local names = {}
    for k in pairs(e.attrs) do
        names[#names + 1] = k
    end
    table.sort(names)
    for _, name in ipairs(names) do
        out = out .. ", @" .. golden.esc16(name)
        if e.attrs[name] ~= "" then
            out = out .. '="' .. golden.esc16(e.attrs[name]) .. '"'
        end
    end
    if e.text ~= "" then
        out = out .. ", T(L" .. string.format("%d", e.text_line) .. ')="'
            .. golden.esc16(e.text) .. '"'
    end
    if #e.children > 0 then
        local parts = {}
        for _, c in ipairs(e.children) do
            parts[#parts + 1] = shape(c)
        end
        out = out .. ", C=[" .. table.concat(parts, " ") .. "]"
    end
    return out .. ")"
end

local function run_lex(rep, case, want, src)
    local cid = case.ID
    local lx = stml_lexer.new(src, state_of(case.ST or "Xml"))
    local toks = {}
    local lexs = {}
    for i = 0, 9999 do -- 死循环保险丝
        local t = lx:next_token()
        toks[#toks + 1] = stml.type_name(t.type) .. "(" .. string.format("%d", t.line) .. ")"
        if stml_lexer.HAS_LEXEME[t.type] then
            lexs[#lexs + 1] = string.format("%d", i) .. ":" .. golden.esc16(t.lexeme)
        end
        if t.type == stml.TokenType.Eof then
            break
        end
    end
    rep:check(cid, "TOKS", want.TOKS or "", table.concat(toks, " "))
    rep:check(cid, "LEXS", want.LEXS or "", table.concat(lexs, ","))
    rep:check(cid, "ERRN", want.ERRN or "", string.format("%d", #lx.errors))
    rep:check(cid, "ERRS", want.ERRS or "", golden.join_esc16(lx.errors))
end

local function run_parse(rep, case, want, src)
    local cid = case.ID
    local lx = stml_lexer.new(src)
    local ps = stml_parser.Parser.new(lx)
    ps.max_depth = tonumber(case.MD or "256") -- 嵌套深度上限（0 = 不限）
    local root = stml.Element()
    local sf = case.SF or "default"
    local state_func
    if sf == "null" then
        state_func = nil
    elseif sf == "text" then
        state_func = function(_tag, _attrs) return stml.LexerState.Text end
    else
        state_func = stml_parser.default_state_func
    end

    local rc = ps:parse(root, state_func)
    rep:check(cid, "SHAPE", want.SHAPE or "", shape(root))
    rep:check(cid, "RESULT", want.RESULT or "",
        (rc == Result.Success) and "Success" or "Error")
    rep:check(cid, "ERRN", want.ERRN or "", string.format("%d", #ps.errors))
    rep:check(cid, "ERRS", want.ERRS or "", golden.join_esc16(ps.errors))
    rep:check(cid, "LEXERRN", want.LEXERRN or "", string.format("%d", #lx.errors))
    rep:check(cid, "LEXERRS", want.LEXERRS or "", golden.join_esc16(lx.errors))
end

local function run(rep)
    local cases = golden.read_stml_cases()
    if #cases == 0 then
        rep:add_fail("STML", "stml_cases.txt 一条都没读到")
        return
    end
    local want = {}
    for _, r in ipairs(golden.read_golden("golden_stml.txt", false)) do
        want[r.ID] = r
    end

    local seen_lex = 0
    local seen_parse = 0
    rep.case_count = #cases
    for _, case in ipairs(cases) do
        local cid = case.ID
        local rec = want[cid]
        if rec == nil then
            rep:add_fail(cid, "golden_stml.txt 里没有这条")
        else
            local src = string.rep(case.src, case.times)
            if case.KIND == "parse" then
                seen_parse = seen_parse + 1
                run_parse(rep, case, rec, src)
            else
                seen_lex = seen_lex + 1
                run_lex(rep, case, rec, src)
            end
        end
    end

    -- 清单与期望值必须一一对应（少一条就是「用例没跑」而不是「用例通过」）
    local want_count = 0
    for _ in pairs(want) do
        want_count = want_count + 1
    end
    rep:check_int("COUNT", "清单 ↔ golden 条数", #cases, want_count)
    rep:check_int("COUNT", "词法 + 语法", #cases, seen_lex + seen_parse)
end

return { run = run }
