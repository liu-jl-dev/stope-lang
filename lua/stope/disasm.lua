-- disasm.lua —— Program 反汇编（调试用）。端口 python/stope/debug.py（== disasm.py）。
--
-- 输出与 C++ / GDScript / Node.js / C# 逐字节一致：编号列宽 8、名字列宽
-- max(10, 最长名字)（按 UTF-8 字节数）、int/float 常量同列连排、字符串常量一行一个
-- （转回 UTF-8 显示）、二进制数组只印字节数、最后是 warning 段。

local opcode_mod = require("stope.opcode")
local common = require("stope.common")
local utf = require("stope.utf")

local Opcode = opcode_mod.Opcode
local BUILTIN_NAMES = opcode_mod.BUILTIN_NAMES
local BUILTIN_COUNT = opcode_mod.BUILTIN_COUNT

local disasm_mod = {}

--- 名字列的对齐宽度下限 = 内置名里最长的两个（PushString / PushBinArr，10 字节）。
local MIN_NAME_WIDTH = 10

local function utf8_len(s)
    local n = 0
    for i = 1, #s do
        local b = string.byte(s, i)
        if b < 0x80 or b >= 0xC0 then
            n = n + 1 -- 非 UTF-8 续字节都算一个字符
        end
    end
    return n
end

--- 按 UTF-8 字节数右填充空格（非 ASCII 名会少填几个空格，与 C++ 一致）。
local function pad_right(s, width)
    local n = utf8_len(s)
    if n >= width then return s end
    return s .. string.rep(" ", width - n)
end

--- 内置指令是否带一个操作数。自定义指令不走这里（由 config 决定）。
function disasm_mod.opcode_has_arg(op)
    if Opcode.PushInt <= op and op <= Opcode.At then
        return true
    end
    return op == Opcode.If or op == Opcode.GoTo or op == Opcode.Return
end

--- 自定义指令只有在变长参数时才带操作数（那个操作数是本次调用的参数个数）。
function disasm_mod.custom_opcode_has_arg(raw, config)
    if config == nil then return false end
    for _, info in pairs(config.opcodes) do
        if info.opcode == raw and info.is_var_arg then
            return true
        end
    end
    return false
end

--- 把 Program 反汇编成可读文本。config 可空：产物里没有自定义指令时传 nil。
function disasm_mod.disasm(prog, config)
    -- ---------- 编号 -> (名字, 注册项) 的反查表 ----------
    local custom_by_opcode = {}
    local warnings = {}
    local name_width = MIN_NAME_WIDTH
    if config ~= nil then
        -- C++ 的 CustomOpcodeConfig 是 std::map（按名字字典序）：先按名字排序建表
        local names = {}
        for name in pairs(config.opcodes) do
            names[#names + 1] = name
        end
        table.sort(names)
        for _, name in ipairs(names) do
            local info = config.opcodes[name]
            if info.opcode < opcode_mod.kFirstCustomOpcode then
                local what
                if info.opcode >= 0 and info.opcode < BUILTIN_COUNT then
                    what = BUILTIN_NAMES[info.opcode + 1]
                else
                    what = "(not an opcode)"
                end
                warnings[#warnings + 1] = string.format(
                    'custom opcode "%s" uses #%d, which collides with %s; builtin decoding wins.',
                    name, info.opcode, what)
            else
                local prev = custom_by_opcode[info.opcode]
                if prev ~= nil then
                    warnings[#warnings + 1] = string.format(
                        'custom opcodes "%s" and "%s" share #%d; the former wins.',
                        prev[1], name, info.opcode)
                else
                    custom_by_opcode[info.opcode] = { name, info }
                    local w = utf8_len(name)
                    if w > name_width then name_width = w end
                end
            end
        end
    end

    -- ---------- 指令流 ----------
    local parts = {}
    local unknown = {} -- 不认识的编号，最后统一提示（保持首次出现顺序）
    local seen_unknown = {}
    local ops = prog.opcodes
    local n = #ops
    local i = 1 -- 数组 1 起；i-1 是 0 起的逻辑下标
    while i <= n do
        local raw = ops[i]
        local has_arg = false
        local name
        if raw >= 0 and raw < BUILTIN_COUNT then
            name = BUILTIN_NAMES[raw + 1]
            has_arg = disasm_mod.opcode_has_arg(raw)
        else
            local it = custom_by_opcode[raw]
            if it ~= nil then
                name = it[1]
                has_arg = it[2].is_var_arg
            else
                -- 编号不认识就只能印数字。绝不能猜「有没有操作数」
                if raw > Opcode.Return then
                    name = "Custom" .. raw
                else
                    name = "Op#" .. raw
                end
                if not seen_unknown[raw] then
                    seen_unknown[raw] = true
                    unknown[#unknown + 1] = raw
                end
            end
        end
        parts[#parts + 1] = pad_right(string.format("[%d]", i - 1), 8)
            .. pad_right(name, name_width) .. " "
        i = i + 1
        if has_arg then
            if i <= n then
                parts[#parts + 1] = tostring(ops[i])
                i = i + 1
            else
                parts[#parts + 1] = "<missing operand>"
                warnings[#warnings + 1] = string.format(
                    "opcode at [%d] expects an operand but the stream ends there.", i - 2)
            end
        end
        parts[#parts + 1] = "\n"
    end
    local ss = table.concat(parts)

    -- ---------- 自定义指令表（名字、编号、参数形态一次交代清楚） ----------
    if next(custom_by_opcode) ~= nil then
        ss = ss .. "custom opcodes:\n"
        -- 必须按【编号】排序打印（C++ 的 customByOpcode 是 map<short, ...>）
        local nums = {}
        for num in pairs(custom_by_opcode) do
            nums[#nums + 1] = num
        end
        table.sort(nums)
        for _, num in ipairs(nums) do
            local name, info = custom_by_opcode[num][1], custom_by_opcode[num][2]
            ss = ss .. "  " .. pad_right(name, name_width) .. " -> " .. tostring(info.opcode)
            if info.is_var_arg then
                ss = ss .. " (vararg)"
            else
                ss = ss .. string.format(" (%d args)", info.arg_num)
            end
            ss = ss .. "\n"
        end
    end

    -- ---------- 变量表与常量池 ----------
    ss = ss .. "variables:\n  "
    local variables = {}
    for k = 0, prog.variable_num - 1 do
        variables[k] = ""
    end
    for name, idx in pairs(prog.exports) do
        if idx >= 0 and idx < prog.variable_num then
            variables[idx] = name
        end
    end
    for k = 0, prog.variable_num - 1 do
        ss = ss .. '"' .. variables[k] .. '"'
        if k < prog.variable_num - 1 then
            ss = ss .. " "
        end
    end
    ss = ss .. "\nint consts:\n"
    for _, v in ipairs(prog.int_consts) do
        ss = ss .. "  " .. string.format("%d", v)
    end
    ss = ss .. "\nfloat consts:\n"
    for _, v in ipairs(prog.float_consts) do
        ss = ss .. "  " .. common.fmt_g(v)
    end
    ss = ss .. "\nstring consts:\n"
    for _, v in ipairs(prog.string_consts) do
        ss = ss .. '  "' .. utf.utf16_to_utf8(v) .. '"\n'
    end
    ss = ss .. "binary array consts:\n"
    for _, v in ipairs(prog.binarr_consts) do
        ss = ss .. "  " .. tostring(#v) .. " bytes\n"
    end
    ss = ss .. "max return num: " .. tostring(prog.max_return_num) .. "\n"
    ss = ss .. "required stack size: " .. tostring(prog.required_stack_size) .. "\n"

    for _, raw in ipairs(unknown) do
        if raw > Opcode.Return then
            warnings[#warnings + 1] = string.format(
                "opcode #%d is not a builtin; pass the CustomOpcodeConfig to Disasm() to decode it.",
                raw)
        else
            warnings[#warnings + 1] = string.format(
                "opcode #%d is not a valid instruction (unpatched placeholder?).", raw)
        end
    end
    for _, w in ipairs(warnings) do
        ss = ss .. "warning: " .. w .. "\n"
    end
    return ss
end

--- 产物里确定没有自定义指令时的简写。
function disasm_mod.disasm_no_custom(prog)
    return disasm_mod.disasm(prog, nil)
end

return disasm_mod
