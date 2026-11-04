-- golden.lua —— golden 数据的读取、转义与「单行产物格式」。
-- 移植 python/tests/golden.py。数据在 gdscript/test/data/（只读真源，绝不复制）。
--
-- ⚠ 转义约定每个文件都不一样：
--   golden.txt / golden_disasm.txt : 值解一层，SRC 解两层
--   golden_lex.txt                 : 值不解，SRC 用 unescape_lex（多认 \v \f）
--   golden_stml.txt                : 一律不解
--   stml_cases.txt                 : 清单本身，SRC 用 unescape_lex

local common = require("stope.common")
local opcode_mod = require("stope.opcode")
local utf = require("stope.utf")

local golden = {}

local Opcode = opcode_mod.Opcode

-- ==================== 数据目录定位 ====================

local DATA_DIR = nil

--- 当前工作目录。Windows 下 io.popen("cd") 走 cmd 内建；POSIX 回退 pwd。
function golden.current_dir()
    local f = io.popen("cd 2>NUL")
    local d = f and f:read("*l") or ""
    if f then f:close() end
    if d == nil or d == "" then
        f = io.popen("pwd")
        d = f and f:read("*l") or ""
        if f then f:close() end
    end
    return string.gsub(d or "", "\\", "/")
end

--- 从本文件位置向上找 gdscript/test/data（任何 cwd 都能跑）。
function golden.locate_data_dir()
    if DATA_DIR ~= nil then
        return DATA_DIR
    end
    local d = golden.script_dir()
    while d and d ~= "" do
        local cand = d .. "/gdscript/test/data"
        local f = io.open(cand .. "/golden.txt", "rb")
        if f then
            f:close()
            DATA_DIR = cand
            return cand
        end
        local parent = string.match(d, "^(.*)[/\\][^/\\]+$")
        if parent == d or parent == nil then break end
        d = parent
    end
    error("找不到 gdscript/test/data —— 请在仓库里运行（测试数据不入库 lua/）。")
end

function golden.data_path(name)
    return golden.locate_data_dir() .. "/" .. name
end

--- 读一份数据文件，统一剥掉 \r（Windows 上探针输出 CRLF）。
function golden.read_text(name)
    local f = io.open(golden.data_path(name), "rb")
    if f == nil then
        error("读不到数据文件：" .. golden.data_path(name))
    end
    local data = f:read("*a")
    f:close()
    return string.gsub(data, "\r", "")
end

-- ==================== 转义 ====================

--- 反转义：与探针的 E_() 对称（\\ \n \r \t，其余原样保留）。
function golden.unescape(s)
    local out = {}
    local i = 1
    local n = #s
    while i <= n do
        local c = string.sub(s, i, i)
        if c ~= "\\" then
            out[#out + 1] = c
            i = i + 1
        else
            i = i + 1
            local c2 = (i <= n) and string.sub(s, i, i) or "\0"
            i = i + 1
            if c2 == "\\" then
                out[#out + 1] = "\\"
            elseif c2 == "n" then
                out[#out + 1] = "\n"
            elseif c2 == "r" then
                out[#out + 1] = "\r"
            elseif c2 == "t" then
                out[#out + 1] = "\t"
            else
                out[#out + 1] = "\\" .. c2
            end
        end
    end
    return table.concat(out)
end

--- 与 unescape 相同，但多认 \v 与 \f —— 词法与 STML 的 SRC 用这套。
function golden.unescape_lex(s)
    local out = {}
    local i = 1
    local n = #s
    while i <= n do
        local c = string.sub(s, i, i)
        if c == "\\" and i + 1 <= n then
            local c2 = string.sub(s, i + 1, i + 1)
            if c2 == "\\" then
                out[#out + 1] = "\\"
                i = i + 2
            elseif c2 == "n" then
                out[#out + 1] = "\n"
                i = i + 2
            elseif c2 == "r" then
                out[#out + 1] = "\r"
                i = i + 2
            elseif c2 == "t" then
                out[#out + 1] = "\t"
                i = i + 2
            elseif c2 == "v" then
                out[#out + 1] = "\v"
                i = i + 2
            elseif c2 == "f" then
                out[#out + 1] = "\f"
                i = i + 2
            else
                out[#out + 1] = c
                i = i + 1
            end
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
    return table.concat(out)
end

--- E_() 那一套：把 \ 与 " 双写（golden_stml.txt 的 ERRS 用）。
function golden.esc_quote(s)
    s = string.gsub(s, "\\", "\\\\")
    s = string.gsub(s, '"', '\\"')
    return s
end

--- 词法错误串连接（esc_lex：多认 \v \f、不转义引号、非 ASCII 透传）。
function golden.join_esc(errs)
    local parts = {}
    for _, e in ipairs(errs) do
        parts[#parts + 1] = common.esc_u8(e, { vf = true, pass_nonascii = true })
    end
    return table.concat(parts, "|")
end

--- STML 侧的 esc16：按 UTF-8 码点遍历，非 BMP（> 0xFFFF）给两个 "?"（代理对两码元）。
function golden.esc16(text)
    local out = {}
    utf.utf8_for_each(text, function(cp)
        if cp == 0x5C then
            out[#out + 1] = "\\\\"
        elseif cp == 0x22 then
            out[#out + 1] = '\\"'
        elseif cp == 0x0A then
            out[#out + 1] = "\\n"
        elseif cp == 0x0D then
            out[#out + 1] = "\\r"
        elseif cp == 0x09 then
            out[#out + 1] = "\\t"
        elseif cp < 128 then
            out[#out + 1] = string.char(cp)
        else
            out[#out + 1] = "?"
        end
    end)
    return table.concat(out)
end

--- UTF-16 码元版（C++ 的 u16string 口径）：非 BMP 给两个 "?"。
function golden.esc16_strict(text)
    -- 与 esc16 的差别仅在非 BMP：按码元数给 "?"。UTF-8 侧无法有 lone surrogate，
    -- 所以这里与 esc16 等价 —— 保留名字以便对照 python 版的 _esc16。
    return golden.esc16(text)
end

function golden.join_esc16(errs)
    local parts = {}
    for _, e in ipairs(errs) do
        parts[#parts + 1] = golden.esc16(e)
    end
    return table.concat(parts, "|")
end

-- ==================== 记录读取 ====================

--- 读一份 golden 文件 -> 若干 KEY=VALUE 字典（按出现顺序），行首 # 是注释。
--- unescape_values 默认 true（golden.txt 与 golden_disasm.txt 的字段要解一层）。
function golden.read_golden(name, unescape_values)
    if unescape_values == nil then
        unescape_values = true
    end
    local out = {}
    for line in string.gmatch(golden.read_text(name) .. "\n", "([^\n]*)\n") do
        if line ~= "" and string.sub(line, 1, 1) ~= "#" then
            local rec = {}
            for field in string.gmatch(line, "([^\t]*)\t?") do
                local eq = string.find(field, "=", 1, true)
                if eq ~= nil then
                    local k = string.sub(field, 1, eq - 1)
                    local v = string.sub(field, eq + 1)
                    rec[k] = unescape_values and golden.unescape(v) or v
                end
            end
            if next(rec) ~= nil then
                out[#out + 1] = rec
            end
        end
    end
    return out
end

--- golden_binarr.txt 有两类记录，按 TAB 位置切。
function golden.read_binarr_golden()
    local out = {}
    for line in string.gmatch(golden.read_text("golden_binarr.txt") .. "\n", "([^\n]*)\n") do
        if line ~= "" and string.sub(line, 1, 1) ~= "#" then
            local head = string.sub(line, 1, 3)
            if head == "BA\t" then
                local parts = {}
                for p in string.gmatch(string.sub(line, 4), "([^\t]*)\t?") do
                    parts[#parts + 1] = p
                end
                local status = parts[#parts - 1]
                local content = table.concat(parts, "\t", 1, #parts - 2)
                out[#out + 1] = { kind = "BA", content = content,
                                  ok = (status == "ok"), bytes = parts[#parts] }
            elseif head == "FB\t" or head == "FU\t" then
                local parts = {}
                for p in string.gmatch(line, "([^\t]*)\t?") do
                    parts[#parts + 1] = p
                end
                out[#out + 1] = { kind = (head == "FB\t") and "FB" or "FU",
                                  op = parts[2], left = parts[3], result = parts[4] }
            end
        end
    end
    return out
end

--- stml_cases.txt：STML 的用例清单（四方共用），加删用例只改它。
function golden.read_stml_cases()
    local out = {}
    for line in string.gmatch(golden.read_text("stml_cases.txt") .. "\n", "([^\n]*)\n") do
        if line ~= "" and string.sub(line, 1, 1) ~= "#" then
            local rec = {}
            for part in string.gmatch(line, "([^\t]*)\t?") do
                local eq = string.find(part, "=", 1, true)
                if eq ~= nil then
                    rec[string.sub(part, 1, eq - 1)] = string.sub(part, eq + 1)
                end
            end
            if rec.ID ~= nil then
                rec.src = golden.unescape_lex(rec.SRC or "")
                rec.times = tonumber(rec.TIMES or "1")
                out[#out + 1] = rec
            end
        end
    end
    return out
end

-- ==================== 单行产物格式 ====================

local function has_arg(op, custom)
    if op > Opcode.Return then
        if custom == nil then return false end
        for _, info in pairs(custom.opcodes) do
            if info.opcode == op then return info.is_var_arg end
        end
        return false
    end
    if op <= Opcode.PushTrue then return false end
    if op <= Opcode.At then return true end
    if op <= Opcode.GE then return false end
    if op <= Opcode.GoTo then return true end
    if op <= Opcode.ArgNum then return false end
    return true
end

--- 「单行产物格式」（compiler-test-plan §2.3）。四份都不进库，只在测试里用。
function golden.dump_program(prog, custom)
    local parts = { "code[" }
    local local_parts = {}
    local ops = prog.opcodes
    local i = 1 -- 1 起数组；i-1 是 0 起逻辑下标
    while i <= #ops do
        if i > 1 then
            local_parts[#local_parts + 1] = " "
        end
        local op = ops[i]
        i = i + 1
        if op > Opcode.Return then
            local_parts[#local_parts + 1] = string.format("Opcode(%d)", op)
        else
            local_parts[#local_parts + 1] = opcode_mod.BUILTIN_NAMES[op + 1]
        end
        if has_arg(op, custom) and i <= #ops then
            local_parts[#local_parts + 1] = string.format("(%d)", ops[i])
            i = i + 1
        end
    end
    parts[#parts + 1] = table.concat(local_parts)
    parts[#parts + 1] = "]"

    local out = table.concat(parts)
    out = out .. " vars=" .. string.format("%d", prog.variable_num)
    out = out .. " stack=" .. string.format("%d", prog.required_stack_size)
    out = out .. " maxRet=" .. string.format("%d", prog.max_return_num)
    local ints = {}
    for _, v in ipairs(prog.int_consts) do
        ints[#ints + 1] = string.format("%d", v)
    end
    out = out .. " ints=[" .. table.concat(ints, ",") .. "]"
    local floats = {}
    for _, v in ipairs(prog.float_consts) do
        floats[#floats + 1] = common.fmt_g(v)
    end
    out = out .. " floats=[" .. table.concat(floats, ",") .. "]"
    local strs = {}
    for _, v in ipairs(prog.string_consts) do
        strs[#strs + 1] = common.esc_u16(v, { quote = true })
    end
    out = out .. " strs=[" .. table.concat(strs, ",") .. "]"
    local binarrs = {}
    for _, v in ipairs(prog.binarr_consts) do
        binarrs[#binarrs + 1] = "[" .. common.fmt_bytes(v) .. "]"
    end
    out = out .. " binarrs=[" .. table.concat(binarrs, " ") .. "]"
    -- C++ 的 exports 是 std::map：按名字排序打印（不是插入序）
    local names = {}
    for k in pairs(prog.exports) do
        names[#names + 1] = k
    end
    table.sort(names)
    local exports = {}
    for _, k in ipairs(names) do
        exports[#exports + 1] = common.esc_u8(k, { quote = true }) .. ":"
            .. string.format("%d", prog.exports[k])
    end
    out = out .. " exports=[" .. table.concat(exports, ",") .. "]"
    return out
end

--- 脚本自身所在目录（run_tests.lua 用 debug.getinfo 定位后传进来也行，
--- 这里独立实现：向上找 tests 目录的父级）。
function golden.script_dir()
    if golden._script_dir then
        return golden._script_dir
    end
    local src = debug.getinfo(2, "S").source
    if string.sub(src, 1, 1) == "@" then
        src = string.sub(src, 2)
    end
    src = string.gsub(src, "\\", "/")
    -- debug.getinfo 给的是启动时的原始路径：相对路径向上爬永远到不了仓库根
    --（相对路径没有根），先拼上 cwd 变绝对。
    if not string.match(src, "^/") and not string.match(src, "^%a:") then
        src = golden.current_dir() .. "/" .. src
    end
    local dir = string.match(src, "^(.*)/[^/]+$") or "."
    golden._script_dir = dir
    return dir
end

return golden
