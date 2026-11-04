-- stml_parser.lua —— STML 语法分析器。端口 python/stope/stml_parser.py。
--
-- STML 比 XML 更严格：没有字符实体；属性可以没有值（<a flag> 等价 flag = ""）；
-- 子元素与元素内文本互斥；元素内文本只有一段，由词法器一次性给出，不做多段拼接。
--
-- 宿主回调 state_func(tag, attrs) -> LexerState 决定元素内容怎么扫（<sto> 走 Stope、
-- <nev> 走 Nevext、<p> 走 Text、其余按 Xml 递归子元素）。传 nil 表示「一律 Xml」。

local common = require("stope.common")
local stml = require("stope.stml")
local stml_lexer = require("stope.stml_lexer")

local Parser = {}
local MT = { __index = Parser }

local T = stml.TokenType
local S = stml.LexerState
local Result = common.Result

--- 默认回调：<sto> -> Stope、<nev> -> Nevext、<p> -> Text，其余 Xml。
function stml_parser_default_state_func(tag, _attrs)
    if tag == "sto" then return S.Stope end
    if tag == "nev" then return S.Nevext end
    if tag == "p" then return S.Text end
    return S.Xml
end

function Parser.new(lexer)
    local self = setmetatable({}, MT)
    self.lexer = lexer
    self.state_func = nil
    self.errors = {}
    self.token = stml.new_token()
    -- 元素嵌套深度上限（根元素算第 1 层），0 = 不限。
    self.max_depth = 256
    self.aborted = false
    return self
end

function Parser:parse(root, state_func)
    self.state_func = state_func
    self.aborted = false
    self:next_token()
    self:parse_element(root, 1) -- 根元素算第 1 层
    if #self.errors == 0 then return Result.Success end
    return Result.Error
end

function Parser:parse_element(e, depth)
    -- 深度检查：唯一递归点在子元素分支。aborted 之后逐层提前 return，
    -- 不再消费任何 token —— 与 Stope 解析器「中止但不逐层传染」同款
    if self.aborted then return end
    if self.max_depth > 0 and depth > self.max_depth then
        self:abort_too_deep()
        return
    end
    -- 进入元素一律先回到 Xml 状态
    self.lexer.state = S.Xml
    e.line = self.token.line
    if self.token.type ~= T.LAngle then
        self:error('expected "<". ')
        return
    end
    self:next_token()
    if self.token.type ~= T.Word then
        self:error("expected tag name. ")
        return
    end
    e.tag = self.token.lexeme
    self:next_token() -- 第一个属性名，或 > 或 />
    -- 每个分支自己负责推进到下一个待判断的 token。
    -- 不能写成「循环开头 next_token」，否则无值属性的向前看会多吞一个 token。
    while true do -- (word ("=" string)?)*
        if self.token.type == T.RAngle then
            break
        elseif self.token.type == T.CRAngle then
            e.self_closing = true
            return
        elseif self.token.type == T.Word then
            local name = self.token.lexeme
            self:next_token()
            if self.token.type == T.EQ then
                self:next_token()
                if self.token.type ~= T.String then
                    self:error("expected string. ")
                    return
                end
                -- C++ 用 std::map::emplace：同名属性保留先出现的那个
                if e.attrs[name] == nil then
                    e.attrs[name] = self.token.lexeme
                end
                self:next_token()
            else
                -- 无值属性：<a flag> 等价于 attrs["flag"] = ""
                -- 此时 token 已经是下一个属性名 / > 或 />，不能再推进
                if e.attrs[name] == nil then
                    e.attrs[name] = ""
                end
            end
        else
            self:error('expected ">" or "/>" or attribute. ')
            return
        end
    end
    -- 此时 e.self_closing 为 False，且停在 ">"
    if self.state_func ~= nil then
        self.lexer.state = self.state_func(e.tag, e.attrs)
    else
        self.lexer.state = S.Xml
    end

    if self.lexer.state == S.Xml then -- 递归解析子元素
        while true do
            self:next_token()
            if self.token.type == T.CLAngle then -- </>
                break
            elseif self.token.type == T.LAngle then -- < 子元素
                local child = stml.Element()
                e.children[#e.children + 1] = child
                self:parse_element(child, depth + 1)
                if self.aborted then
                    return -- 超限的那层已报过错，逐层直接返回，不级联
                end
            else
                self:error('expected "<" or "</". ')
                return
            end
        end
    else -- Text / Nevext / Stope：整段内容由词法器一次性给出
        self:next_token() -- 词法器保证只会结束在 </ ，不会结束在 <
        if self.token.type ~= T.Text and self.token.type ~= T.NevextSrc
            and self.token.type ~= T.StopeSrc then
            self:error("expected element content. ")
            return
        end
        e.text = self.token.lexeme -- 只有一段，不拼接
        e.text_line = self.token.line -- 词法器已跳过前导空白，这是内容的首行（PL-05）
        self:next_token() -- 停在 CLAngle，与上面 Xml 分支的 break 处汇合
    end

    self:next_token() -- 结束标签名
    if self.token.type ~= T.Word then
        self:error("expected tag name. ")
        return
    end
    if self.token.lexeme ~= e.tag then
        self:error("tag name mismatch. ")
        return
    end
    self:next_token()
    if self.token.type ~= T.RAngle then
        self:error('expected ">". ')
        return
    end
end

function Parser:next_token()
    self.token = self.lexer:next_token()
end

function Parser:abort_too_deep()
    self:error(string.format("nesting too deep (max %d). ", self.max_depth)) -- 必须在置位之前记账
    self.aborted = true
end

function Parser:error(msg)
    -- 超限中止之后的错误都是连锁反应，不再记账 —— 与 Stope 的 Parser 同款
    if self.aborted then
        return
    end
    self.errors[#self.errors + 1] = string.format("line %d: %s", self.token.line, msg)
end

local mod = { Parser = Parser, default_state_func = stml_parser_default_state_func }
Parser.default_state_func = stml_parser_default_state_func
return mod
