-- token.lua —— 词法单元类型与 Token。
--
-- 编号与 C++ 的 stope::TokenType 逐项相同（0..46），不要重排。

local token = {}

token.TokenType = {
    Invalid = 0, Eof = 1, Ident = 2, Integer = 3, Float = 4, String = 5, BinArr = 6,
    Comma = 7, Semi = 8, LParen = 9, RParen = 10, LBrack = 11, RBrack = 12, LBrace = 13,
    RBrace = 14, Assign = 15, Add = 16, Sub = 17, Mul = 18, Div = 19, IDiv = 20,
    Mod = 21, Pow = 22, EQ = 23, NE = 24, LT = 25, LE = 26, GT = 27, GE = 28,
    Not = 29, And = 30, Or = 31, If = 32, Elif = 33, Else = 34, Let = 35,
    Return = 36, While = 37, Break = 38, Continue = 39, Null = 40, False_ = 41,
    True_ = 42, Args = 43, Argc = 44, Export = 45, Custom = 46,
}
local T = token.TokenType

-- 下标即编号（0 起），打印类型名用。
token.TOKEN_TYPE_NAMES = {
    "Invalid", "Eof", "Ident", "Integer", "Float", "String", "BinArr",
    "Comma", "Semi", "LParen", "RParen", "LBrack", "RBrack", "LBrace",
    "RBrace", "Assign", "Add", "Sub", "Mul", "Div", "IDiv", "Mod", "Pow",
    "EQ", "NE", "LT", "LE", "GT", "GE", "Not", "And", "Or", "If", "Elif",
    "Else", "Let", "Return", "While", "Break", "Continue", "Null", "False",
    "True", "Args", "Argc", "Export", "Custom",
}

function token.type_name(t)
    local names = token.TOKEN_TYPE_NAMES
    if t >= 0 and t < #names then
        return names[t + 1]
    end
    return "?" .. tostring(t)
end

--- 一个词法单元。字段与 python/stope/token.py 的 Token 一致：
---   line / type / lexeme（原文）/ parsed（语义形态）/ value（数字的值）
--- 字符串的 parsed 是 **UTF-16LE 字节串**（内部表示，见 utf.lua）。
function token.new(line, t)
    return { line = line or 0, type = t or T.Invalid, lexeme = "", parsed = "", value = nil }
end

return token
