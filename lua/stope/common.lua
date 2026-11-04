-- common.lua —— 返回码 + 数值助手（整数 int64 语义 / 浮点 IEEE 语义）+ 格式化工具。
--
-- 移植 python/stope/common.py 与 format.py。Lua 5.4 的整数**天然是 int64 补码回绕**
-- （加 / 减 / 乘 / 位运算 / 一元负号都回绕，不报错），所以 wrap64 大多不需要 —— 但
-- Lua 的 `//` 与 `%` 是 **floor 语义**，Stope 要**向零取整**，必须走 int_div / int_mod。
-- 浮点：Lua 的 `^` 与 math.fmod 都走 C 库（与 std::pow / std::fmod 一致），但
-- `math.fmod(x, 整数 0)` 会报错、`math.floor(2^63)` 会报"没有整数表示"，都要自己兜。

local utf = require("stope.utf")

local common = {}

common.INT64_MIN = math.mininteger
common.INT64_MAX = math.maxinteger

-- Result 与 C++ 的 stope::Result 逐值对应。
common.Result = { Success = 0, Error = 1, UnknownError = 2, DuplicateWithBuiltinOpcode = 3 }
local Result = common.Result

-- ==================== 整数（Lua 整数自带回绕，只有除/模要自写） ====================

--- 向零取整的整除（C++ 的 `/` 语义），结果天然按 64 位回绕。b 不能为 0。
function common.int_div(a, b)
    if a == math.mininteger and b == -1 then
        return math.mininteger -- MIN / -1 回绕；Lua 的 // 对这组会给 mininteger，但显式写出更稳
    end
    local q = a // b -- floor
    -- floor = trunc - 1 当且仅当「除不尽且商为负」。q*b 溢出会回绕，但回绕后仍等于 a
    -- 当且仅当余数为 0（可证），所以判断可靠。
    if q < 0 and q * b ~= a then
        q = q + 1
    end
    return q
end

--- 向零取整的余数（C++ 的 `%` 语义）：余数符号跟被除数。b 不能为 0。
function common.int_mod(a, b)
    return a - common.int_div(a, b) * b -- 乘减都回绕
end

--- 整数快速幂，exp >= 0；溢出不检查、按 64 位回绕（Lua 乘法自带回绕）。
function common.int_pow(base, exp)
    local result = 1
    local b = base
    local e = exp
    while e > 0 do
        if (e & 1) == 1 then
            result = result * b
        end
        e = e >> 1
        if e > 0 then
            b = b * b
        end
    end
    return result
end

-- ==================== 浮点（C++ 走 IEEE，Lua 与 C 库一致但仍要兜边界） ====================

function common.is_special(v)
    return v ~= v or v == math.huge or v == -math.huge
end

--- IEEE 除法：x / 0 得 ±inf、0 / 0 得 nan（Lua 对浮点本来就是 IEEE，这里只兜 0）。
function common.fdiv(a, b)
    if b ~= 0.0 then
        return a / b
    end
    if a == 0.0 or a ~= a then
        return 0.0 / 0.0 -- nan
    end
    -- 符号：a 的符号 XOR b 的符号（b 是 ±0，用 1/b 取符号）
    if (a < 0.0) ~= (1.0 / b < 0.0) then
        return -math.huge
    end
    return math.huge
end

--- std::fmod：余数符号跟被除数；b == 0 得 nan 而不是报错。
function common.fmod(a, b)
    if b == 0.0 or a ~= a or b ~= b then
        return 0.0 / 0.0 -- nan
    end
    return math.fmod(a, b)
end

--- std::trunc：向零取整但保持浮点。Lua 的 math.floor/ceil 对 |v| >= 2^63 会报错
--- （浮点数没有整数表示），要自己拦。
function common.trunc(v)
    if v ~= v or v == math.huge or v == -math.huge then
        return v
    end
    if v >= 9223372036854775808.0 or v <= -9223372036854775808.0 then
        return v -- 已经是整数值（2^63 以上浮点必然是 2^k 的倍数）
    end
    local t
    if v >= 0.0 then
        t = math.floor(v) + 0.0
    else
        t = math.ceil(v) + 0.0
    end
    -- 保持 -0.0 的符号（C 的 trunc(-0.3) 是 -0.0）
    if t == 0.0 and 1.0 / v < 0.0 then
        return -0.0
    end
    return t
end

--- std::pow：Lua 的 `^` 对浮点就是 C 的 pow（负底数 + 非整数指数得 nan、溢出得 ±inf、
--- 0 ^ 负数得 inf），与 C++ 完全一致，直接转发。
function common.fpow(a, b)
    return a ^ b
end

-- ==================== 格式化（凡进 golden 的串都用这里） ====================

--- printf("%g") 的忠实实现；nan / inf / -inf 与 C 一样小写。
function common.fmt_g(v)
    if v ~= v then
        return "nan"
    end
    if v == math.huge then
        return "inf"
    end
    if v == -math.huge then
        return "-inf"
    end
    return string.format("%g", v)
end

--- 二进制数组 -> "01,0a,ff"（小写两位十六进制，逗号分隔）。
function common.fmt_bytes(b)
    local parts = {}
    for i = 1, #b do
        parts[#parts + 1] = string.format("%02x", string.byte(b, i))
    end
    return table.concat(parts, ",")
end

--- escUtf8（**码元版**）：Stope 字符串值（UTF-16LE）用 —— 与 C++ 的 escUtf8 一致，
--- 非 ASCII 码元一律变 "?"（非 BMP 字符是两个码元 -> 两个 "?"）。
--- opts.quote 再转义 `"`（dump 串用）。非 ASCII 透传的模式不走这里：
--- 透传必须按**码点**（与 Python / GDScript 一致），用 esc_lex_u16。
function common.esc_u16(s, opts)
    opts = opts or {}
    local out = {}
    local n = #s
    local i = 1
    while i + 1 <= n do
        local lo, hi = string.byte(s, i, i + 1)
        local c = lo | (hi << 8)
        i = i + 2
        if c == 0x5C then
            out[#out + 1] = "\\\\"
        elseif c == 0x22 and opts.quote then
            out[#out + 1] = '\\"'
        elseif c == 0x0A then
            out[#out + 1] = "\\n"
        elseif c == 0x0D then
            out[#out + 1] = "\\r"
        elseif c == 0x09 then
            out[#out + 1] = "\\t"
        elseif c < 128 then
            out[#out + 1] = string.char(c)
        else
            out[#out + 1] = "?"
        end
    end
    return table.concat(out)
end

--- esc_lex 的**值版**：先转回 UTF-8 再逐字节扫 —— 透传按码点（Python / GDScript
--- 同口径），转义表多认 \v \f、不转义引号。词法的 parsed 值用这个。
function common.esc_lex_u16(s)
    local utf = require("stope.utf")
    return common.esc_u8(utf.utf16_to_utf8(s), { vf = true, pass_nonascii = true })
end

--- escUtf8（**字节版**）：名字 / 错误串这类 UTF-8 文本用 —— 逐字节扫（这些串都是
--- ASCII，行为与逐码点一致）。
function common.esc_u8(s, opts)
    opts = opts or {}
    local out = {}
    for i = 1, #s do
        local c = string.byte(s, i)
        if c == 0x5C then
            out[#out + 1] = "\\\\"
        elseif c == 0x22 and opts.quote then
            out[#out + 1] = '\\"'
        elseif c == 0x0A then
            out[#out + 1] = "\\n"
        elseif c == 0x0D then
            out[#out + 1] = "\\r"
        elseif c == 0x09 then
            out[#out + 1] = "\\t"
        elseif c == 0x0B and opts.vf then
            out[#out + 1] = "\\v"
        elseif c == 0x0C and opts.vf then
            out[#out + 1] = "\\f"
        elseif c < 128 then
            out[#out + 1] = string.char(c)
        elseif opts.pass_nonascii then
            out[#out + 1] = string.char(c)
        else
            out[#out + 1] = "?"
        end
    end
    return table.concat(out)
end

return common
