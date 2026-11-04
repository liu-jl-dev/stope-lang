-- program.lua —— 编译产物 Program：指令流 + 常量池 + 变量表。端口 python/stope/program.py。
--
-- opcodes 是「0 起算的逻辑下标 + 1」存进 Lua 数组（opcodes[i+1] 是逻辑第 i 格）；
-- 所有操作数（常量 / 变量 / 跳转目标）的**值**保持 0 起。
-- 整数常量语义是 int64（写进来之前已经过回绕）。
-- 字符串常量是 **UTF-16LE 字节串**（内部表示）。

local Program = {}
local MT = { __index = Program }

function Program.new()
    local self = setmetatable({}, MT)
    self:clear()
    return self
end

function Program:clear()
    self.opcodes = {}            -- 指令与操作数混排，int16 范围内
    self.variable_num = 0        -- 变量数量
    self.exports = {}            -- 导出变量名 -> 槽位
    self.int_consts = {}         -- 1 起数组，操作数值 0 起
    self.float_consts = {}
    self.string_consts = {}
    self.binarr_consts = {}
    self.max_return_num = 0      -- return 语句最大返回值数量
    self.required_stack_size = 0
end

return Program
