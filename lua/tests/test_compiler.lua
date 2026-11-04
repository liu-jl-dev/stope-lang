-- test_compiler.lua —— 编译器：golden.txt 的 CMP / OUT / CERRS 三个字段（201 条）。

local stope = require("stope")
local golden = require("tests.golden")

local test_parser = require("tests.test_parser")
local CFG = test_parser.CFG

local function py_split(s, sep)
    local parts = {}
    local pos = 1
    while true do
        local e = string.find(s, sep, pos, true)
        if e == nil then
            parts[#parts + 1] = string.sub(s, pos)
            return parts
        end
        parts[#parts + 1] = string.sub(s, pos, e - 1)
        pos = e + #sep
    end
end

local function run(rep)
    local cases = golden.read_golden("golden.txt")
    if #cases == 0 then
        rep:add_fail("编译器", "golden.txt 一条都没读到")
        return
    end
    rep.case_count = #cases
    for _, rec in ipairs(cases) do
        local cid = rec.ID or ""
        local got = test_parser.run_case(rec)
        -- PRE：预导出名单，逗号分隔（空元素表示一个空名字）；字段为空 = 不预导出
        local pre = rec.PRE or ""
        local pre_exports = {}
        if pre ~= "" then
            pre_exports = py_split(pre, ",")
        end
        local prog = stope.Program.new()
        local c = stope.Compiler.new(CFG)
        local rc = c:compile(got.tree, prog, pre_exports)
        rep:check(cid, "CMP", rec.CMP or "",
            (rc == stope.Result.Success) and "OK" or "ERR")
        rep:check(cid, "OUT", rec.OUT or "", golden.dump_program(prog, CFG))
        rep:check(cid, "CERRS", rec.CERRS or "", golden.join_esc(c.errors))
    end
end

return { run = run }
