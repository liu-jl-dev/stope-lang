-- stml.lua —— STML 的公共类型：元素与 Token。端口 python/stope/stml.py。
--
-- 元素模型只有 6 个字段（line / text_line / tag / attrs / self_closing / children+text），
-- 不要加字段：形状串与跨实现比对都按这 6 项来。

local stml = {}

stml.TokenType = {
    Invalid = 0, Eof = 1, LAngle = 2, RAngle = 3, CLAngle = 4, CRAngle = 5,
    EQ = 6, Word = 7, String = 8, Text = 9, NevextSrc = 10, StopeSrc = 11,
}
local TokenType = stml.TokenType

-- 下标即编号（0 起），与枚举逐项对应。
stml.TOKEN_TYPE_NAMES = {
    "Invalid", "Eof", "LAngle", "RAngle", "CLAngle", "CRAngle",
    "EQ", "Word", "String", "Text", "NevextSrc", "StopeSrc",
}

function stml.type_name(t)
    if t >= 0 and t < #stml.TOKEN_TYPE_NAMES then
        return stml.TOKEN_TYPE_NAMES[t + 1]
    end
    return "?"
end

--- 词法四态。扫完一段 Text / Nevext / Stope 后必须交还 Xml。
stml.LexerState = { Xml = 0, Text = 1, Nevext = 2, Stope = 3 }

--- 一个词法单元。lexeme 是输入的子串（UTF-8 字节串，STML 侧不做码元转换）。
function stml.new_token(t, line, lexeme)
    return { type = t or TokenType.Invalid, line = line or -1, lexeme = lexeme or "" }
end

--- 一个元素。children 与 text 互斥；text 只有一段，不拼接。
function stml.Element()
    return {
        line = -1,
        -- text / 代码段第一个字符的物理行号；元素没有内容时为 -1。词法器切内容前
        -- 已跳过前导空白（含换行），所以这是内容的首行而不是标签行。
        text_line = -1,
        tag = "",
        attrs = {}, -- 属性；无值属性的值是空串；顺序不保证
        self_closing = false,
        children = {},
        text = "",
    }
end

return stml
