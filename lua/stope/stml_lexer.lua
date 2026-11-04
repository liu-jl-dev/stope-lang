-- stml_lexer.lua —— STML 词法器。四态状态机（Xml / Text / Nevext / Stope）。
-- 端口 python/stope/stml_lexer.cpp（实为 stml_lexer.py，C++ 为权威）。
--
-- 三条最容易写错的规则：
-- 1. Text / Nevext / Stope 扫完一段后必须把 state 交还 Xml；
-- 2. 输入耗尽后永远返回 Eof，与当前状态无关 —— 而且此时不改 state；
-- 3. 任何异常路径都要消费字符，否则调用方的 while 会死循环。
--
-- ⚠ NextToken 必须【先跳空白再定 token.line】—— textLine 的精确性依赖这个顺序。
-- ⚠ 在字节上扫（UTF-8）；Word 是 ASCII，字符串与文本段按字节透传。

local stml = require("stope.stml")

local Lexer = {}
local MT = { __index = Lexer }

local T = stml.TokenType
local S = stml.LexerState

--- 只有这几类 token 的 lexeme 是「双方实现都提供」的。
--- 与 python 的 stml_lexer.HAS_LEXEME 同名导出（本模块返回的就是 Lexer 表）。
Lexer.HAS_LEXEME = {
    [T.Word] = true, [T.String] = true, [T.Text] = true,
    [T.NevextSrc] = true, [T.StopeSrc] = true,
}
local HAS_LEXEME = Lexer.HAS_LEXEME

local WHITE = { [32] = true, [9] = true, [11] = true, [12] = true, [13] = true, [10] = true }

local function is_white(c) return WHITE[c] == true end

local function is_alpha(c)
    return (c >= 97 and c <= 122) or (c >= 65 and c <= 90)
end

local function is_digit(c) return c >= 48 and c <= 57 end

local function is_word_begin(c)
    return is_alpha(c) or c == 95 or c == 58 -- _ :
end

local function is_word_char(c)
    return is_word_begin(c) or is_digit(c) or c == 45 -- -
end

--- 去掉尾部空白（B-8：内容段尾部的空白不计入 lexeme）。
function stml.trim_trailing_ws(s)
    local n = #s
    while n > 0 and is_white(string.byte(s, n)) do
        n = n - 1
    end
    return string.sub(s, 1, n)
end

function Lexer.new(source, state)
    local self = setmetatable({}, MT)
    self.state = state or S.Xml
    self.src = source or "" -- 未消费的剩余输入
    self.line = 1
    self.errors = {}
    return self
end

function Lexer:next_token()
    local token = stml.new_token()
    self:skip_ws()
    token.line = self.line -- ⚠ 先跳空白再定 token.line
    if self.src == "" then
        token.type = T.Eof
    elseif self.state == S.Xml then
        local c = string.byte(self.src, 1)
        if string.sub(self.src, 1, 2) == "</" then
            token.type = T.CLAngle
            token.lexeme = "</"
            self.src = string.sub(self.src, 3)
        elseif string.sub(self.src, 1, 2) == "/>" then
            token.type = T.CRAngle
            token.lexeme = "/>"
            self.src = string.sub(self.src, 3)
        elseif c == 60 then -- <
            token.type = T.LAngle
            token.lexeme = "<"
            self.src = string.sub(self.src, 2)
        elseif c == 62 then -- >
            token.type = T.RAngle
            token.lexeme = ">"
            self.src = string.sub(self.src, 2)
        elseif c == 61 then -- =
            token.type = T.EQ
            token.lexeme = "="
            self.src = string.sub(self.src, 2)
        elseif c == 34 or c == 39 then -- " '
            self:scan_string(token)
        elseif is_word_begin(c) then
            token.type = T.Word
            token.lexeme = self:scan_word()
        else
            self:error("unexpected character. ")
            token.type = T.Invalid
            token.lexeme = ""
            self.src = string.sub(self.src, 2) -- 必须消费，否则死循环
        end
    elseif self.state == S.Text then
        token.type = T.Text
        token.lexeme = self:scan_content("text")
        self.state = S.Xml
    elseif self.state == S.Nevext then
        token.type = T.NevextSrc
        token.lexeme = self:scan_content("nevext")
        self.state = S.Xml
    else -- S.Stope
        token.type = T.StopeSrc
        token.lexeme = self:scan_content("stope")
        self.state = S.Xml
    end
    return token
end

-- ============================ Xml 状态 ============================

--- Xml 属性串：不转义（\" 里的引号就是结束引号，TD-9）。
--- 未闭合时报错（文案比代码段那条少一个句号，TD-8）并吃掉剩余全部输入。
function Lexer:scan_string(token)
    token.type = T.String
    local quote = string.byte(self.src, 1)
    self.src = string.sub(self.src, 2) -- 跳过开头的引号
    local n = #self.src
    local i = 1
    while true do
        if i > n then
            self:error("unclosed string literal")
            self.src = ""
            token.type = T.Invalid
            return
        end
        local c = string.byte(self.src, i)
        if c == quote then
            token.lexeme = string.sub(self.src, 1, i - 1)
            self.src = string.sub(self.src, i + 1)
            return
        end
        if c == 10 then -- \n
            self.line = self.line + 1
        end
        i = i + 1
    end
end

function Lexer:scan_word()
    local n = #self.src
    local e = 2
    while e <= n and is_word_char(string.byte(self.src, e)) do
        e = e + 1
    end
    local s = string.sub(self.src, 1, e - 1)
    self.src = string.sub(self.src, e)
    return s
end

-- ============================ 内容三态 ============================

--- Text / Nevext / Stope 同构：从当前位置一路吃到 </ 或输入耗尽，
--- 尾部空白不计入 lexeme（B-8）。text 只认 </（<b/> 会被整段当文本吃掉，B-2）；
--- 两个代码段还把引号串与注释整段跳过，其中的 </ 不算结束标签（B-3）。
function Lexer:scan_content(mode)
    local begin = self.src
    while self.src ~= "" do
        if string.sub(self.src, 1, 2) == "</" then
            break
        end
        if mode ~= "text" then
            local c = string.byte(self.src, 1)
            if c == 39 or c == 34 then -- ' "
                -- Nevext：两种引号都转义；Stope：双引号转义、单引号（BinArr）不转义
                self:scan_code_str(c, (mode == "nevext") or (c == 34))
                goto continue
            end
            if string.sub(self.src, 1, 2) == "//" then
                self:skip_singleline_comment()
                goto continue
            end
            if string.sub(self.src, 1, 2) == "/*" then
                self:skip_multiline_comment()
                goto continue
            end
        end
        if string.byte(self.src, 1) == 10 then
            self.line = self.line + 1
        end
        self.src = string.sub(self.src, 2)
        ::continue::
    end
    return stml.trim_trailing_ws(string.sub(begin, 1, #begin - #self.src))
end

--- 代码段里的引号串，含两侧引号。到输入末尾仍未闭合时报错并吃掉剩余全部输入；
--- 报的是起始行，不是当前行。
function Lexer:scan_code_str(quote, escapes)
    local begin_line = self.line
    self.src = string.sub(self.src, 2) -- 跳过开头的引号
    while true do
        if self.src == "" then
            self:error_at(begin_line, "unclosed string literal. ")
            return
        end
        local c = string.byte(self.src, 1)
        self.src = string.sub(self.src, 2)
        if escapes and c == 92 then -- \：连同紧跟的一个字符一起吃掉
            if self.src == "" then
                self:error_at(begin_line, "unclosed string literal. ")
                return
            end
            if string.byte(self.src, 1) == 10 then
                self.line = self.line + 1
            end
            self.src = string.sub(self.src, 2)
        elseif c == quote then
            return
        elseif c == 10 then
            self.line = self.line + 1
        end
    end
end

--- // 到行尾；换行符一并消费并推进行号。
function Lexer:skip_singleline_comment()
    self.src = string.sub(self.src, 3)
    while self.src ~= "" do
        local c = string.byte(self.src, 1)
        self.src = string.sub(self.src, 2)
        if c == 10 then
            self.line = self.line + 1
            return
        end
    end
end

--- /* 到 */。未闭合不是错误，一直吃到输入末尾。
function Lexer:skip_multiline_comment()
    self.src = string.sub(self.src, 3)
    while self.src ~= "" do
        if string.sub(self.src, 1, 2) == "*/" then
            self.src = string.sub(self.src, 3)
            return
        end
        if string.byte(self.src, 1) == 10 then
            self.line = self.line + 1
        end
        self.src = string.sub(self.src, 2)
    end
end

-- ============================ 空白与注释 ============================

function Lexer:skip_ws()
    while self.src ~= "" do
        local c = string.byte(self.src, 1)
        if is_white(c) then
            if c == 10 then
                self.line = self.line + 1
            end
            self.src = string.sub(self.src, 2)
        elseif self.state == S.Xml and string.sub(self.src, 1, 4) == "<!--" then
            -- <!-- 只在 Xml 状态是注释；Nevext / Stope 里的 < 是小于号
            self:skip_xml_comment()
        else
            break
        end
    end
end

function Lexer:skip_xml_comment()
    self.src = string.sub(self.src, 5)
    while self.src ~= "" do
        if string.sub(self.src, 1, 3) == "-->" then
            self.src = string.sub(self.src, 4)
            return
        end
        if string.byte(self.src, 1) == 10 then
            self.line = self.line + 1
        end
        self.src = string.sub(self.src, 2)
    end
end

-- ============================ 报错 ============================

function Lexer:error(msg)
    self.errors[#self.errors + 1] = string.format("line %d: %s", self.line, msg)
end

--- 指定行号报错：跨行的字面量 / 注释报的是起始行，不是当前行。
function Lexer:error_at(line, msg)
    self.errors[#self.errors + 1] = string.format("line %d: %s", line, msg)
end

return Lexer
