-- utf.lua —— UTF-8 <-> UTF-16 转换与码元工具（零依赖，自写编解码）。
--
-- Stope 字符串值的内部表示是 **UTF-16LE 字节串**（每码元 2 字节）：长度 / 下标 /
-- 重复 / 相等都按码元（= 2 字节单位）进行，与 C++ 的 u16string、C# 的 char 一致。
-- 源码输入是 UTF-8 文本：词法器在字节上扫（引号、空白等 ASCII 字符不受影响），
-- 只在把字符串字面量内容转成内部表示、以及显示输出时才转换。
--
-- 说明：没有用官方 utf8 库，编解码全部手写 —— 对非法序列与 lone surrogate 的
-- 处理要跟 Python 的 "surrogatepass" / C++ 的 u16string 对齐，手写最可控。

local utf = {}

local function utf8_decode_one(s, i)
    -- 返回 cp, next_i；非法字节按 latin-1 兜底（占 1 字节）。
    local b = string.byte(s, i)
    if b < 0x80 then
        return b, i + 1
    elseif b < 0xC2 then
        return b, i + 1 -- 续字节或过长的 2 字节序列头
    elseif b < 0xE0 then
        local b2 = string.byte(s, i + 1) or 0
        if b2 < 0x80 or b2 >= 0xC0 then return b, i + 1 end
        return (b - 0xC0) * 64 + (b2 - 0x80), i + 2
    elseif b < 0xF0 then
        local b2 = string.byte(s, i + 1) or 0
        local b3 = string.byte(s, i + 2) or 0
        if b2 < 0x80 or b2 >= 0xC0 or b3 < 0x80 or b3 >= 0xC0 then return b, i + 1 end
        local cp = (b - 0xE0) * 4096 + (b2 - 0x80) * 64 + (b3 - 0x80)
        if cp < 0x800 then return b, i + 1 end -- 过长序列
        return cp, i + 3
    elseif b < 0xF5 then
        local b2 = string.byte(s, i + 1) or 0
        local b3 = string.byte(s, i + 2) or 0
        local b4 = string.byte(s, i + 3) or 0
        if b2 < 0x80 or b2 >= 0xC0 or b3 < 0x80 or b3 >= 0xC0
            or b4 < 0x80 or b4 >= 0xC0 then return b, i + 1 end
        local cp = (b - 0xF0) * 262144 + (b2 - 0x80) * 4096 + (b3 - 0x80) * 64 + (b4 - 0x80)
        if cp < 0x10000 or cp > 0x10FFFF then return b, i + 1 end
        return cp, i + 4
    else
        return b, i + 1
    end
end

local function utf8_encode_one(cp)
    if cp < 0x80 then
        return string.char(cp)
    elseif cp < 0x800 then
        return string.char(0xC0 + (cp // 64), 0x80 + (cp % 64))
    elseif cp < 0x10000 then
        return string.char(0xE0 + (cp // 4096), 0x80 + ((cp // 64) % 64), 0x80 + (cp % 64))
    else
        return string.char(0xF0 + (cp // 262144), 0x80 + ((cp // 4096) % 64),
                           0x80 + ((cp // 64) % 64), 0x80 + (cp % 64))
    end
end

--- UTF-8 字节串 -> UTF-16LE 字节串。非法字节按 latin-1 兜底；lone surrogate 原样编码
--- （对应 Python encode("utf-16-le", "surrogatepass") 的往返行为）。
function utf.utf8_to_utf16(s)
    local parts = {}
    local i = 1
    local n = #s
    while i <= n do
        local cp, j = utf8_decode_one(s, i)
        if cp < 0x10000 then
            parts[#parts + 1] = string.char(cp % 256, cp // 256)
        else
            local v = cp - 0x10000
            local hi = 0xD800 + (v // 1024)
            local lo = 0xDC00 + (v % 1024)
            parts[#parts + 1] = string.char(hi % 256, hi // 256, lo % 256, lo // 256)
        end
        i = j
    end
    return table.concat(parts)
end

--- UTF-16LE 字节串 -> UTF-8 字节串。代理对合并；lone surrogate 按 WTF-8 编码
--- （对应 Python decode("utf-16-le", "surrogatepass")）。
function utf.utf16_to_utf8(s)
    local parts = {}
    local n = #s
    local i = 1
    while i + 1 <= n do
        local lo1, hi1 = string.byte(s, i, i + 1)
        local u = lo1 | (hi1 << 8)
        if u >= 0xD800 and u <= 0xDBFF and i + 3 <= n then
            local lo2, hi2 = string.byte(s, i + 2, i + 3)
            local u2 = lo2 | (hi2 << 8)
            if u2 >= 0xDC00 and u2 <= 0xDFFF then
                parts[#parts + 1] = utf8_encode_one(0x10000 + (u - 0xD800) * 1024 + (u2 - 0xDC00))
                i = i + 4
                goto continue
            end
        end
        parts[#parts + 1] = utf8_encode_one(u)
        i = i + 2
        ::continue::
    end
    return table.concat(parts)
end

--- 按码元取字符（返回 UTF-8）：越界返回 nil。
function utf.utf16_at(s, index) -- index 0 起
    if index < 0 or index * 2 + 2 > #s then return nil end
    local lo, hi = string.byte(s, index * 2 + 1, index * 2 + 2)
    return utf8_encode_one(lo | (hi << 8))
end

--- 码元个数（UTF-16 字节串的一半）。
function utf.utf16_len(s)
    return #s // 2
end

--- 遍历 UTF-8 串的码点（供 STML 侧 esc 用）：fn(cp)，非法字节按 latin-1。
function utf.utf8_for_each(s, fn)
    local i = 1
    local n = #s
    while i <= n do
        local cp, j = utf8_decode_one(s, i)
        fn(cp)
        i = j
    end
end

return utf
