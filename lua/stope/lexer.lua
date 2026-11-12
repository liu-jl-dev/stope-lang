-- lexer.lua —— 词法分析器。端口 python/stope/lexer.py（C++ 为权威）。
--
-- 行为契约：同样的错误文案、同样的错误恢复（报错后**继续**产 token，不中断）。
-- 源码在 **字节** 上扫（UTF-8；引号 / 空白 / 标点等结构字符都是 ASCII）。
-- 字符串的 lexeme 保留原始 UTF-8 字节；parsed（反转义后的值）转成 UTF-16LE 内部表示。
-- ⚠ 字符串字面量里的换行**不**推进行号（与 C++ / Python 一致）；BinArr 里的换行要推。

local token_mod = require("stope.token")
local utf = require("stope.utf")

local Lexer = {}
local LexerMT = { __index = Lexer }

local T = token_mod.TokenType
local INT64_MIN = math.mininteger
local INT64_MAX = math.maxinteger

local KEYWORDS = {
    idiv = T.IDiv, ["not"] = T.Not, ["and"] = T.And, ["or"] = T.Or,
    ["if"] = T.If, elif = T.Elif, ["else"] = T.Else, ["let"] = T.Let,
    ["return"] = T.Return, ["while"] = T.While, ["break"] = T.Break,
    ["continue"] = T.Continue, defer = T.Defer, ["null"] = T.Null,
    ["false"] = T.False_, ["true"] = T.True_, args = T.Args, argc = T.Argc,
    export = T.Export,
}

local TWO_CHAR_OPS = {
    ["=="] = T.EQ, ["!="] = T.NE, ["<="] = T.LE, [">="] = T.GE,
    ["&&"] = T.And, ["||"] = T.Or,
}

local ONE_CHAR_OPS = {
    [","] = T.Comma, [";"] = T.Semi, ["("] = T.LParen, [")"] = T.RParen,
    ["["] = T.LBrack, ["]"] = T.RBrack, ["{"] = T.LBrace, ["}"] = T.RBrace,
    ["+"] = T.Add, ["-"] = T.Sub, ["*"] = T.Mul, ["/"] = T.Div,
    ["%"] = T.Mod, ["^"] = T.Pow, ["="] = T.Assign, ["!"] = T.Not,
    ["<"] = T.LT, [">"] = T.GT,
}

local ESCAPE = {
    ["\\"] = "\\", ["'"] = "'", ['"'] = '"',
    b = "\b", r = "\r", t = "\t", v = "\v", n = "\n", f = "\f",
}

local function is_white(c)
    return c == 32 or c == 9 or c == 13 or c == 10 or c == 11 or c == 12
end

local function is_digit(c)
    return c >= 48 and c <= 57
end

local function is_alpha(c)
    return (c >= 97 and c <= 122) or (c >= 65 and c <= 90)
end

local function is_ident_begin(c)
    return is_alpha(c) or c == 95 -- _
end

local function is_ident_char(c)
    return is_ident_begin(c) or is_digit(c)
end

local function sub(s, i, j)
    return string.sub(s, i, j)
end

local function count_char(s, byte)
    local k = 0
    for i = 1, #s do
        if string.byte(s, i) == byte then k = k + 1 end
    end
    return k
end

local function ident_run(s, from)
    local n = #s
    local pos = from
    if pos > n or not is_ident_begin(string.byte(s, pos)) then
        return from
    end
    pos = pos + 1
    while pos <= n and is_ident_char(string.byte(s, pos)) do
        pos = pos + 1
    end
    return pos
end

-- 对齐 _RE_FLOAT：(?:[0-9]+(\.[0-9]*)?|\.[0-9]+)([eE][+-]?[0-9]+)?$
local function float_shape_ok(s)
    local i = 1
    local n = #s
    local int_digits = 0
    while i <= n and string.byte(s, i) >= 48 and string.byte(s, i) <= 57 do
        i = i + 1
        int_digits = int_digits + 1
    end
    if i <= n and string.byte(s, i) == 46 then
        i = i + 1
        if int_digits == 0 then
            -- .[0-9]+：小数点后必须有数字
            local d = 0
            while i <= n and string.byte(s, i) >= 48 and string.byte(s, i) <= 57 do
                i = i + 1
                d = d + 1
            end
            if d == 0 then return false end
        else
            -- [0-9]*：小数点后可以没有数字
            while i <= n and string.byte(s, i) >= 48 and string.byte(s, i) <= 57 do
                i = i + 1
            end
        end
    elseif int_digits == 0 then
        return false
    end
    if i <= n then
        local c = string.byte(s, i)
        if c == 101 or c == 69 then
            i = i + 1
            if i <= n then
                local s2 = string.byte(s, i)
                if s2 == 43 or s2 == 45 then i = i + 1 end
            end
            local d = 0
            while i <= n and string.byte(s, i) >= 48 and string.byte(s, i) <= 57 do
                i = i + 1
                d = d + 1
            end
            if d == 0 then return false end -- "1e"、"." 之类
        end
    end
    return i > n
end

function Lexer.new(input_src)
    local self = setmetatable({}, LexerMT)
    self:reset(input_src or "")
    return self
end

function Lexer:reset(input_src)
    self.input = input_src or ""
    self.line = 1
    self.errors = {}
end

function Lexer:error(msg)
    self.errors[#self.errors + 1] = string.format("line %d: %s", self.line, msg)
end

-- ============================ 主循环 ============================

function Lexer:next_token(custom)
    self:skip_ws()
    local tk = token_mod.new(self.line, T.Eof)
    if self.input == "" then
        return tk
    end
    local c = string.byte(self.input, 1)
    if is_digit(c) or c == 46 then -- 46 = '.'
        self:scan_number(tk)
    elseif is_ident_begin(c) then
        self:scan_ident(tk)
        self:analyze_ident(tk, custom)
    elseif c == 39 then -- '\''
        self:scan_binarr(tk)
    elseif c == 34 then -- '"'
        self:scan_string(tk)
    else
        self:scan_punct(tk, c)
    end
    return tk
end

-- ============================ 数字 ============================

local function consume_while(input, pos, allowed)
    -- allowed: function(byte) -> boolean；返回新 pos。
    local n = #input
    while pos <= n and allowed(string.byte(input, pos)) do
        pos = pos + 1
    end
    return pos
end

local function radix_allowed(base)
    if base == 2 then
        return function(c) return c == 95 or c == 48 or c == 49 end
    elseif base == 8 then
        return function(c) return c == 95 or (c >= 48 and c <= 55) end
    elseif base == 16 then
        return function(c)
            return c == 95 or (c >= 48 and c <= 57) or (c >= 97 and c <= 102) or (c >= 65 and c <= 70)
        end
    end
    return function(c) return c == 95 or (c >= 48 and c <= 57) end
end

local function dec_digit_or_underscore(c)
    return c == 95 or is_digit(c)
end

--- 指数扫描（[eE][+-]?[0-9]*，数字可为空），返回扫完后的位置；**不消费**。
local function scan_exp(input, pos)
    local n = #input
    if pos > n then return pos end
    local c = string.byte(input, pos)
    if c ~= 101 and c ~= 69 then return pos end -- e / E
    pos = pos + 1
    if pos <= n then
        local s = string.byte(input, pos)
        if s == 43 or s == 45 then pos = pos + 1 end -- + / -
    end
    while pos <= n and is_digit(string.byte(input, pos)) do
        pos = pos + 1
    end
    return pos
end

function Lexer:scan_number(tk)
    local input = self.input
    local p2 = sub(input, 1, 2)
    if p2 == "0b" or p2 == "0B" then
        tk.type = T.Integer
        local e = consume_while(input, 3, radix_allowed(2))
        tk.lexeme = self:match_and_consume(1, e - 1)
    elseif p2 == "0o" or p2 == "0O" then
        tk.type = T.Integer
        local e = consume_while(input, 3, radix_allowed(8))
        tk.lexeme = self:match_and_consume(1, e - 1)
    elseif p2 == "0x" or p2 == "0X" then
        tk.type = T.Integer
        local e = consume_while(input, 3, radix_allowed(16))
        tk.lexeme = self:match_and_consume(1, e - 1)
    elseif string.byte(input, 1) == 46 then -- .[_0-9]*([eE][+-]?[0-9]*)?
        tk.type = T.Float
        local e = consume_while(input, 2, dec_digit_or_underscore)
        local e2 = scan_exp(input, e)
        tk.lexeme = self:match_and_consume(1, e2 - 1)
    else -- [_0-9]+(.[_0-9]*)?([eE][+-]?[0-9]*)?
        tk.type = T.Integer
        local e = consume_while(input, 1, dec_digit_or_underscore)
        if string.byte(input, e) == 46 then -- 有小数点就是浮点数
            tk.type = T.Float
            local e2 = consume_while(input, e + 1, dec_digit_or_underscore)
            local e3 = scan_exp(input, e2)
            tk.lexeme = self:match_and_consume(1, e3 - 1)
        else
            local e3 = scan_exp(input, e)
            if e3 > e then -- 有指数就是浮点数
                tk.type = T.Float
            end
            tk.lexeme = self:match_and_consume(1, e3 - 1)
        end
    end
    self:parse_number(tk)
    self:get_number_value(tk)
end

function Lexer:match_and_consume(from, count)
    local text = sub(self.input, from, from + count - 1)
    self.input = sub(self.input, from + count)
    return text
end

function Lexer:parse_number(tk)
    tk.parsed = string.gsub(tk.lexeme, "_", "")
end

--- 按 parsed 求数值；不合法（含超出 int64）则报错并把 token 置为 Invalid。
function Lexer:get_number_value(tk)
    if tk.type == T.Integer then
        local parsed = tk.parsed
        local base, prefix_len = 10, 0
        if #parsed >= 2 and string.byte(parsed, 1) == 48 then
            local c = string.byte(parsed, 2)
            if c == 98 or c == 66 then base, prefix_len = 2, 2
            elseif c == 111 or c == 79 then base, prefix_len = 8, 2
            elseif c == 120 or c == 88 then base, prefix_len = 16, 2 end
        end
        local digits = sub(parsed, prefix_len + 1)
        -- 逐位累计并检查溢出（对齐 C++ stoll 的 out_of_range）；空段（只有前缀）也失败
        local v = 0
        local any_digit = false
        local maxq = INT64_MAX // base
        local maxr = INT64_MAX % base
        for i = 1, #digits do
            local cb = string.byte(digits, i)
            local d = -1
            if cb >= 48 and cb <= 57 then d = cb - 48
            elseif cb >= 97 and cb <= 102 then d = cb - 87
            elseif cb >= 65 and cb <= 70 then d = cb - 55 end
            if d < 0 or d >= base then
                self:error("invalid integer. ")
                tk.type = T.Invalid
                return
            end
            if v > maxq or (v == maxq and d > maxr) then
                self:error("invalid integer. ")
                tk.type = T.Invalid
                return
            end
            v = v * base + d
            any_digit = true
        end
        if not any_digit then
            self:error("invalid integer. ")
            tk.type = T.Invalid
            return
        end
        tk.value = v
    elseif tk.type == T.Float then
        -- 形状校验（对齐 C++ 用 stod 的 pos 判断）：整数部分允许省略、指数数字必须完整
        if not float_shape_ok(tk.parsed) then
            self:error("invalid float. ")
            tk.type = T.Invalid
            return
        end
        local v = tonumber(tk.parsed)
        -- Lua 的 strtod 上溢得 inf、下溢得 0：非有限值（1e999）或有非零数字却算出 0
        -- （1e-999 下溢）都判 invalid
        if v == nil or v == math.huge or v == -math.huge or v ~= v
            or (v == 0.0 and string.find(tk.parsed, "[1-9]")) then
            self:error("invalid float. ")
            tk.type = T.Invalid
            return
        end
        tk.value = v
    end
end

-- 对齐 _RE_FLOAT 的形状校验已挪到文件头部（float_shape_ok）。

-- ============================ 序列 / 字符串 ============================

--- '...' 到下一个 ' 为止，中间可以换行（换行计入 line）。
function Lexer:scan_binarr(tk)
    tk.type = T.BinArr
    self.input = sub(self.input, 2) -- 跳过开头的 '
    local e = string.find(self.input, "'", 1, true)
    if e == nil then
        local body = self.input
        self.line = self.line + count_char(body, 10)
        self:error("unclosed binary array. ")
        tk.type = T.Invalid
        tk.lexeme = body
        self.input = ""
        return
    end
    local body = sub(self.input, 1, e - 1)
    self.line = self.line + count_char(body, 10)
    tk.lexeme = body
    self.input = sub(self.input, e + 1) -- 跳过结尾的 '
end

--- "..." 里的 \ 会转义后一个字符（含 \"），未闭合则报错。
function Lexer:scan_string(tk)
    tk.type = T.String
    self.input = sub(self.input, 2) -- 跳过开头的 "
    -- 主体：普通字符或转义对；末尾孤立的 \ 不属于主体
    local n = #self.input
    local i = 1
    while i <= n do
        local b = string.byte(self.input, i)
        if b == 34 then -- '"'
            break
        elseif b == 92 then -- '\\'
            if i + 1 > n then break end -- 末尾孤立的 \：不属于主体
            i = i + 2
        else
            i = i + 1
        end
    end
    local body = sub(self.input, 1, i - 1)
    if i > n or string.byte(self.input, i) ~= 34 then
        self:error("unclosed string literal. ")
        tk.type = T.Invalid
        tk.lexeme = body
        self.input = ""
        return
    end
    tk.lexeme = body
    self.input = sub(self.input, i + 1) -- 跳过结尾的 "
    self:escape_string(tk)
end

--- 处理转义序列；遇到非法转义就报错并停下（已解析的部分保留）。
--- 结果转成 UTF-16LE 内部表示（先按 UTF-8 逐字节反转义，再一次转换）。
function Lexer:escape_string(tk)
    local parts = {}
    local lexeme = tk.lexeme
    local n = #lexeme
    local i = 1
    while i <= n do
        local b = string.byte(lexeme, i)
        if b == 92 then -- '\\'
            i = i + 1
            if i > n then -- 末尾一个孤立的 \
                self:error("invalid escape character. ")
                break
            end
            local c = string.char(string.byte(lexeme, i))
            if c == "u" then -- \uXXXX：4 位十六进制码点（大小写均可）
                if i + 4 > n then
                    self:error("invalid escape character. ")
                    break
                end
                local hex4 = sub(lexeme, i + 1, i + 4)
                if not hex4:match("^[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]$") then
                    self:error("invalid escape character. ")
                    break
                end
                parts[#parts + 1] = utf.utf8_encode_one(tonumber(hex4, 16))
                i = i + 5
                goto continue
            end
            local mapped = ESCAPE[c]
            if mapped == nil then
                self:error("invalid escape character. ")
                break
            end
            parts[#parts + 1] = mapped
            i = i + 1
        else
            parts[#parts + 1] = string.char(b)
            i = i + 1
        end
        ::continue::
    end
    tk.parsed = utf.utf8_to_utf16(table.concat(parts))
end

-- ============================ 标识符 ============================

--- ^[a-zA-Z_][a-zA-Z0-9_]*(:[a-zA-Z_][a-zA-Z0-9_]*)*，冒号两侧允许空白与注释。
function Lexer:scan_ident(tk)
    tk.type = T.Ident
    local src = {}
    local parsed = self:match_and_consume(1, ident_run(self.input, 1) - 1)
    src[#src + 1] = parsed
    while true do
        src[#src + 1] = self:skip_ws_returning_skipped()
        if self.input == "" or string.byte(self.input, 1) ~= 58 then break end -- ':'
        src[#src + 1] = ":"
        parsed = parsed .. ":"
        self.input = sub(self.input, 2)
        src[#src + 1] = self:skip_ws_returning_skipped()
        local e = ident_run(self.input, 1)
        if e == 1 then -- 冒号后面不是标识符
            self:error("unclosed identifier. ")
            tk.type = T.Invalid
            break
        end
        local text = sub(self.input, 1, e - 1)
        src[#src + 1] = text
        parsed = parsed .. text
        self.input = sub(self.input, e)
    end
    tk.lexeme = table.concat(src)
    tk.parsed = parsed
end

--- 关键字 > 自定义指令 > 标识符。
function Lexer:analyze_ident(tk, custom)
    if tk.type == T.Invalid then return end
    local kw = KEYWORDS[tk.parsed]
    if kw ~= nil then
        tk.type = kw
    elseif custom ~= nil and custom.opcodes[tk.parsed] ~= nil then
        tk.type = T.Custom
    else
        tk.type = T.Ident
    end
end

-- ============================ 标点 / 空白 ============================

--- 先按两字符查表（== != <= >= && ||），再按单字符查表。
function Lexer:scan_punct(tk, c)
    local two = TWO_CHAR_OPS[sub(self.input, 1, 2)]
    if two ~= nil then
        tk.type = two
        tk.lexeme = sub(self.input, 1, 2)
        self.input = sub(self.input, 3)
        return
    end
    local one = ONE_CHAR_OPS[string.char(c)]
    tk.type = (one == nil) and T.Invalid or one
    tk.lexeme = string.char(c)
    self.input = sub(self.input, 2)
    if one == nil then
        self:error("unknown token. ")
    end
end

function Lexer:skip_ws()
    while self.input ~= "" do
        local c = string.byte(self.input, 1)
        if is_white(c) then
            if c == 10 then self.line = self.line + 1 end
            self.input = sub(self.input, 2)
        elseif sub(self.input, 1, 2) == "//" then -- 单行注释
            local pos = string.find(self.input, "\n", 1, true)
            if pos == nil then
                self.input = ""
            else
                self.input = sub(self.input, pos + 1)
                self.line = self.line + 1
            end
        elseif sub(self.input, 1, 2) == "/*" then -- 多行注释
            self:skip_multiline_comment()
        else
            break
        end
    end
end

--- 与 skip_ws 相同，但返回被跳过的原文（标识符的 : 两侧要记进 lexeme）。
function Lexer:skip_ws_returning_skipped()
    local before = self.input
    self:skip_ws()
    return sub(before, 1, #before - #self.input)
end

function Lexer:skip_multiline_comment()
    self.input = sub(self.input, 3) -- 跳过 /*
    while self.input ~= "" do
        if sub(self.input, 1, 2) == "*/" then
            self.input = sub(self.input, 3)
            break
        end
        if string.byte(self.input, 1) == 10 then
            self.line = self.line + 1
        end
        self.input = sub(self.input, 2)
    end
end

return Lexer
