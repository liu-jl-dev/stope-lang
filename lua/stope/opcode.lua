-- opcode.lua —— 指令集与自定义指令登记表。
--
-- 33 条内置指令，编号与 C++ 的 stope::Opcode 逐项相同（0..32）。自定义指令从 33 起。

local common = require("stope.common")

local opcode = {}

local Result = common.Result

opcode.Opcode = {
    Assign = 0, PushNull = 1, PushFalse = 2, PushTrue = 3, PushInt = 4,
    PushFloat = 5, PushString = 6, PushBinArr = 7, PushValue = 8, PushId = 9,
    Call = 10, At = 11, Pop = 12, Minus = 13, Not = 14,
    Pow = 15, Mul = 16, Div = 17, IDiv = 18, Mod = 19,
    Add = 20, Sub = 21, EQ = 22, NE = 23, LT = 24,
    LE = 25, GT = 26, GE = 27, If = 28, GoTo = 29,
    GetArg = 30, ArgNum = 31, Return = 32,
}
local Opcode = opcode.Opcode

--- 第一个可用的自定义指令编号（= Return + 1）。
opcode.kFirstCustomOpcode = Opcode.Return + 1

-- 反汇编用：下标与内置名一一对应，顺序必须跟 Opcode 一致。
opcode.BUILTIN_NAMES = {
    "Assign", "PushNull", "PushFalse", "PushTrue", "PushInt",
    "PushFloat", "PushString", "PushBinArr", "PushValue", "PushId",
    "Call", "At", "Pop", "Minus", "Not",
    "Pow", "Mul", "Div", "IDiv", "Mod",
    "Add", "Sub", "EQ", "NE", "LT",
    "LE", "GT", "GE", "If", "GoTo",
    "GetArg", "ArgNum", "Return",
}
opcode.BUILTIN_COUNT = #opcode.BUILTIN_NAMES

--- 一条自定义指令的登记项。arg_num < 0 表示变长（产物里带参数个数操作数）。
function opcode.CustomOpcode(op, arg_num)
    return { opcode = op, arg_num = arg_num or -1, is_var_arg = (arg_num or -1) < 0 }
end

--- 名字 -> CustomOpcode 的登记表。Lexer / Parser / Compiler 必须共用同一个对象。
function opcode.CustomOpcodeConfig()
    local self = { opcodes = {}, _order = {} }
    --- 登记一条自定义指令；同名重复返回 DuplicateWithBuiltinOpcode 且不插入。
    function self:add_custom_opcode(name, op, arg_num)
        if self.opcodes[name] then
            return Result.DuplicateWithBuiltinOpcode
        end
        self.opcodes[name] = opcode.CustomOpcode(op, arg_num)
        self._order[#self._order + 1] = name
        return Result.Success
    end
    return self
end

return opcode
