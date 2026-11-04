-- test_binarr.lua —— 二进制数组解析 + 常量折叠矩阵：golden_binarr.txt（86 条）。
-- BA 直接打 BinaryArrayParser；FB / FU 直接打常量折叠矩阵（不经过词法/语法）。

local stope = require("stope")
local common = stope.common
local utf = stope.utf
local golden = require("tests.golden")

local A = stope.ast
local T = stope.TokenType
local Result = stope.Result

local INT64_MAX = math.maxinteger
local INT64_MIN = math.mininteger

-- BA 用例表：与 GD test_parser.gd 的 _dump_binarr 逐条一致
local BA_CASES = {
    "", " ", "a", "ab", "b 0100 0001", "b 01000001", "B 1", "o 101", "O 7",
    "d 65", "d 300", "D 255 0", "x 41", "x ff FF", "X 0f", "41", "4_1", "_41",
    "01 02", "  01   02  ", "x zz", "z", "b", "d", "b 2", "o 8", "0 1",
    "9999999999999999999999", "d 2147483647", "d 2147483648", "ff",
}

local function val(x)
    -- 折叠结果的紧凑写法，与 C++ 的 fmtValue / GD 的 _val 一致
    if x == nil then return "null" end
    local t = x.nt
    if t == A.NodeType.NullExpr then return "Null" end
    if t == A.NodeType.BoolExpr then return x.value and "true" or "false" end
    if t == A.NodeType.IntExpr then return string.format("%d", x.value) end
    if t == A.NodeType.FloatExpr then return common.fmt_g(x.value) end
    if t == A.NodeType.BinArrExpr then return "[" .. common.fmt_bytes(x.value) .. "]" end
    if t == A.NodeType.StringExpr then
        return '"' .. utf.utf16_to_utf8(x.value) .. '"'
    end
    return "?"
end

local function int(v) return A.IntExpr(1, v) end
local function float(v) return A.FloatExpr(1, v) end
local function bool(v) return A.BoolExpr(1, v) end
local function null() return A.NullExpr(1) end
local function str(v) return A.StringExpr(1, utf.utf8_to_utf16(v)) end -- 内部表示是 UTF-16LE
local function bin(v) return A.BinArrExpr(1, v) end

local function fb(name, op, l, r)
    local x = A.BinaryOpExpr(1)
    x.op = op
    x.left_expr = l
    x.right_expr = r
    local o = stope.optimize(x)
    local folded = (o.nt == A.NodeType.BinaryOpExpr) and 0 or 1
    return string.format("FB\t%s\t%d\t%s", name, folded, val(o))
end

local function fu(name, op, v)
    local x = A.UnaryOpExpr(1)
    x.op = op
    x.expr = v
    local o = stope.optimize(x)
    local folded = (o.nt == A.NodeType.UnaryOpExpr) and 0 or 1
    return string.format("FU\t%s\t%d\t%s", name, folded, val(o))
end

--- 按 golden 文件的顺序产出一整份文本的行列表。
local function dump_all()
    local out = {}

    -- ---- BA：二进制数组解析 ----
    for _, t in ipairs(BA_CASES) do
        local buf = {}
        local ok = stope.BinaryArrayParser.new():parse_binary_array(t, buf)
        local parts = {}
        for i = 1, #buf do
            parts[i] = string.char(buf[i])
        end
        out[#out + 1] = string.format("BA\t%s\t%s\t[%s]", t,
            (ok == Result.Success) and "ok" or "err",
            common.fmt_bytes(table.concat(parts)))
    end

    -- ---- FB：二元折叠 ----
    out[#out + 1] = fb("+", T.Add, int(1), int(2))
    out[#out + 1] = fb("-", T.Sub, int(5), int(3))
    out[#out + 1] = fb("*", T.Mul, int(2), int(3))
    out[#out + 1] = fb("/", T.Div, int(7), int(2))
    out[#out + 1] = fb("/", T.Div, int(6), int(3))
    out[#out + 1] = fb("/", T.Div, int(1), int(0))
    out[#out + 1] = fb("idiv", T.IDiv, int(7), int(2))
    out[#out + 1] = fb("%", T.Mod, int(7), int(2))
    out[#out + 1] = fb("^", T.Pow, int(2), int(10))
    out[#out + 1] = fb("^", T.Pow, int(2), int(-1))
    out[#out + 1] = fb("+", T.Add, float(1.5), int(1))
    out[#out + 1] = fb("+", T.Add, int(INT64_MAX), int(1))
    out[#out + 1] = fb("*", T.Mul, int(INT64_MAX), int(2))
    out[#out + 1] = fb("+", T.Add, bool(true), bool(true))
    out[#out + 1] = fb("+", T.Add, str("ab"), str("cd"))
    out[#out + 1] = fb("*", T.Mul, str("ab"), int(3))
    out[#out + 1] = fb("*", T.Mul, int(3), str("ab"))
    out[#out + 1] = fb("*", T.Mul, str(""), int(1000000))
    out[#out + 1] = fb("*", T.Mul, str("ab"), int(-1))
    out[#out + 1] = fb("*", T.Mul, float(1.5), str("ab"))
    out[#out + 1] = fb("+", T.Add, bin("\x01"), bin("\x02"))
    out[#out + 1] = fb("*", T.Mul, bin("\x01"), int(3))
    out[#out + 1] = fb("+", T.Add, null(), int(5))
    out[#out + 1] = fb("+", T.Add, int(5), null())
    out[#out + 1] = fb("+", T.Add, null(), null())
    out[#out + 1] = fb("-", T.Sub, null(), int(5))
    out[#out + 1] = fb("-", T.Sub, int(5), null())
    out[#out + 1] = fb("-", T.Sub, null(), null())
    out[#out + 1] = fb("*", T.Mul, null(), int(5))
    out[#out + 1] = fb("^", T.Pow, null(), int(5))
    out[#out + 1] = fb("==", T.EQ, null(), null())
    out[#out + 1] = fb("==", T.EQ, null(), int(1))
    out[#out + 1] = fb("!=", T.NE, null(), int(1))
    out[#out + 1] = fb("<", T.LT, null(), int(1))
    out[#out + 1] = fb("==", T.EQ, bool(true), bool(true))
    out[#out + 1] = fb("==", T.EQ, bool(true), int(1))
    out[#out + 1] = fb("==", T.EQ, int(1), float(1.0))
    out[#out + 1] = fb("==", T.EQ, str("a"), str("a"))
    out[#out + 1] = fb("<", T.LT, int(1), int(2))
    out[#out + 1] = fb("<", T.LT, bool(true), int(2))
    out[#out + 1] = fb("<=", T.LE, float(1.5), float(1.5))
    out[#out + 1] = fb(">", T.GT, int(2), int(1))
    out[#out + 1] = fb(">=", T.GE, int(2), int(2))
    out[#out + 1] = fb("and", T.And, int(1), int(0))
    out[#out + 1] = fb("or", T.Or, int(0), str("a"))

    -- ---- FU：一元折叠 ----
    out[#out + 1] = fu("-", T.Sub, bool(true))
    out[#out + 1] = fu("-", T.Sub, bool(false))
    out[#out + 1] = fu("-", T.Sub, int(5))
    out[#out + 1] = fu("-", T.Sub, float(1.5))
    out[#out + 1] = fu("-", T.Sub, int(INT64_MIN))
    out[#out + 1] = fu("!", T.Not, null())
    out[#out + 1] = fu("!", T.Not, int(0))
    out[#out + 1] = fu("!", T.Not, float(0.0))
    out[#out + 1] = fu("!", T.Not, int(5))
    out[#out + 1] = fu("!", T.Not, str(""))

    return out
end

local function run(rep)
    local want = {}
    for line in string.gmatch(golden.read_text("golden_binarr.txt") .. "\n", "([^\n]*)\n") do
        if line ~= "" then
            want[#want + 1] = line
        end
    end
    local got = dump_all()
    rep.case_count = #want
    rep:check_int("golden_binarr.txt", "行数", #want, #got)
    for i = 1, math.min(#want, #got) do
        rep:check(string.format("#%d", i), "行", want[i], got[i])
    end
end

return { run = run }
