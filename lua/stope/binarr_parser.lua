-- binarr_parser.lua —— 二进制数组字面量【内容】的解析。端口 python/stope/binarr_parser.py。
--
-- * b/B o/O d/D x/X 前缀选进制；没有前缀按 16（首字符就是数据本身，不能被吃掉）；
-- * 每段数字产生一个字节，段内可含 _，段之间用空白分隔；
-- * 超一字节的值静默截断到低 8 位且不报错：'d 300' -> 0x2C；
-- * 出现该进制不允许的字符 -> Result.Error（上层报 invalid binary array. ）；
-- * 空内容合法；只有前缀没有数据同样是零长数组。
-- * 'b 0100 0001' 是两个字节 04 01（二进制前缀下要写满 8 位）。

local common = require("stope.common")
local Result = common.Result

local BinaryArrayParser = {}
local MT = { __index = BinaryArrayParser }

local INT_MAX = 2147483647

local WS = { [32] = true, [9] = true, [10] = true, [13] = true, [11] = true, [12] = true }

local function is_ws(c)
    return WS[c] == true
end

local function digit_of(c, base)
    local d
    if c >= 48 and c <= 57 then
        d = c - 48
    elseif c >= 97 and c <= 102 then
        d = c - 97 + 10
    elseif c >= 65 and c <= 70 then
        d = c - 65 + 10
    else
        return -1
    end
    if d >= 0 and d < base then return d end
    return -1
end

function BinaryArrayParser.new()
    return setmetatable({ input = "", pos = 1 }, MT)
end

--- 解析 '...' 里的内容（不含单引号），字节按顺序 append 进 output（Lua string 逐段拼）。
--- 返回 Result。
function BinaryArrayParser:parse_binary_array(input_src, output)
    self.input = input_src
    self.pos = 1
    self:skip_ws()
    if self:eof() then
        return Result.Success
    end
    local c = string.byte(self.input, self.pos)
    local base = 16
    if c == 98 or c == 66 then -- b / B
        self.pos = self.pos + 1
        base = 2
    elseif c == 111 or c == 79 then -- o / O
        self.pos = self.pos + 1
        base = 8
    elseif c == 100 or c == 68 then -- d / D
        self.pos = self.pos + 1
        base = 10
    elseif c == 120 or c == 88 then -- x / X
        self.pos = self.pos + 1
        base = 16
    end
    return self:parse_by_base(output, base)
end

function BinaryArrayParser:parse_by_base(output, base)
    self:skip_ws()
    while not self:eof() do
        local ok, value = self:parse_integer(base)
        if not ok then
            return Result.Error
        end
        output[#output + 1] = value & 0xFF -- 超 0xFF 静默截断
        self:skip_ws()
    end
    return Result.Success
end

--- 空段（只有下划线）与超出 int 范围的段都判失败（等价 std::stoi 抛异常）。
function BinaryArrayParser:parse_integer(base)
    local n = 0
    local any_digit = false
    while not self:eof() do
        local c = string.byte(self.input, self.pos)
        if is_ws(c) then
            break
        end
        local d = digit_of(c, base)
        if d >= 0 then
            if n > (INT_MAX - d) // base then
                return false, 0
            end
            n = n * base + d
            self.pos = self.pos + 1
            any_digit = true
        elseif c == 95 then -- _
            self.pos = self.pos + 1
        else
            self.pos = self.pos + 1
            return false, 0
        end
    end
    if not any_digit then
        return false, 0
    end
    return true, n
end

function BinaryArrayParser:eof()
    return self.pos > #self.input
end

function BinaryArrayParser:skip_ws()
    while not self:eof() and is_ws(string.byte(self.input, self.pos)) do
        self.pos = self.pos + 1
    end
end

return BinaryArrayParser
