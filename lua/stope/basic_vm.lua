-- basic_vm.lua —— 参考执行器。端口 python/stope/basic_vm.py（C++ 的 basic_vm.hpp）。
--
-- **这不是标准。** Stope 只规定语言、STML 与编译器的产物 Program，执行器不属于标准。
--
-- 值的 Lua 表示（对应 C++ 的 Value::Type）：
--   Null          basic_vm.NULL（唯一哨兵 table；Lua 的 nil 不能上栈）
--   Integer       Lua integer（天生 int64 回绕）
--   Float         Lua float
--   String        包装表 str_value()（携带 UTF-16LE 字节串；长度/下标按码元，见 utf.lua）
--   BinArr        Lua string（原始字节）
--   HostFunction  Lua function（fn(argv) -> 值；argv 是 1 起数组）
--   Identifier    basic_vm.Identifier（PushId 压的槽位引用，只有 Assign 认它）
--
-- ⚠ String 必须包装：Lua 的 string 是纯字节串，无法与 BinArr 区分，而两者的 At 语义
--   不同（码元 vs 字节）、跨类型相等恒为假 —— 用一个带元表的 table 标记 String。
-- ⚠ 没有 Bool 值类型：PushTrue/PushFalse 压的是整数 1 / 0；宿主函数返回 true/false
--   时由 normalize 归一成整数。
-- ⚠ 1.0/0 得 inf 不报错（Lua 浮点除法是 IEEE）；math.fmod 对整数 0 会报错 ->
--   浮点模走 common.fmod（x/0 语义与 C++ fmod 对齐：NaN）。

local common = require("stope.common")
local opcode_mod = require("stope.opcode")

local Opcode = opcode_mod.Opcode
local Result = common.Result

local basic_vm = {}

--- Null 哨兵：全库共用这一个 table；判断用 `v == basic_vm.NULL`。
basic_vm.NULL = setmetatable({}, {
    __tostring = function() return "null" end,
    __name = "StopeNull",
})
local NULL = basic_vm.NULL

-- ============================== String 包装 ==============================

local STR_MT = { __name = "StopeString" }

--- 把 UTF-16LE 字节串包成 String 值。
function basic_vm.str_value(bytes)
    return setmetatable({ __stope_string = bytes }, STR_MT)
end

--- 是 Stope String 值？（BinArr 是裸 Lua string，不走这里）
function basic_vm.is_str_value(v)
    return type(v) == "table" and v.__stope_string ~= nil
end

--- 取 String 值的 UTF-16LE 字节串（非 String 返回 nil）。
function basic_vm.str_bytes(v)
    if type(v) == "table" then return v.__stope_string end
    return nil
end

-- ============================== Handle 包装 ==============================
--
-- 宿主引用（对应 C++ 的 Value::Type::Handle）—— 第 7 种可观测值。含义 VM 一概
-- 不解释：At 读 / Assign 写 / Call 调三个动作经 Api 的 handle_at / handle_assign /
-- handle_call 方法转交宿主（默认实现一律报错，宿主覆写后才可用）。与 Identifier
-- （VM 槽位引用）对称——Identifier 是 VM 自己的左值，Handle 是宿主世界的引用。
-- data 装什么由宿主定义；两个 Handle 相等当且仅当同一个包装实例（equals 的
-- 同一性分支；table 的 == 天然按同一性）。

local HANDLE_MT = { __name = "StopeHandle" }

--- 把宿主引用包成 Handle 值。
function basic_vm.handle_new(data)
    return setmetatable({ data = data }, HANDLE_MT) -- 宿主引用，语义由宿主定义
end

--- 是 Handle 值？
function basic_vm.is_handle(v)
    return type(v) == "table" and getmetatable(v) == HANDLE_MT
end

--- 是序列（String / BinArr）？——VM 层面的序列判断。
local function is_seq(v)
    return basic_vm.is_str_value(v) or type(v) == "string"
end

--- 槽位引用。PushId 压它（左值），Assign 靠它取槽位；其余指令当普通值。
function basic_vm.Identifier(index)
    return setmetatable({ index = index, __stope_identifier = true }, {
        __tostring = function(self) return "Identifier(" .. tostring(self.index) .. ")" end,
    })
end

local function is_identifier(v)
    return type(v) == "table" and v.__stope_identifier == true
end

--- 宿主的实参表基类。取不到就自己报错：state:error(...) 之后返回 nil。
basic_vm.Arguments = {}
basic_vm.Arguments.__index = basic_vm.Arguments
function basic_vm.Arguments.at(_self, _state, _index_or_key)
    error("Arguments.at() 必须由宿主实现")
end
function basic_vm.Arguments.num(_self)
    error("Arguments.num() 必须由宿主实现")
end

-- ============================== 类型判定 ==============================
-- Lua 有原生 boolean 类型且与 integer 分离，比 Python 干净：
-- math.type(integer) == "integer"、math.type(float) == "float"、math.type(其它) == nil。

function basic_vm.is_int(v) return math.type(v) == "integer" end
function basic_vm.is_float(v) return math.type(v) == "float" end
function basic_vm.is_number(v) return math.type(v) == "integer" or math.type(v) == "float" end
function basic_vm.is_binarr(v) return type(v) == "string" end -- 裸字节串就是 BinArr
function basic_vm.is_func(v) return type(v) == "function" end
function basic_vm.is_null(v) return v == NULL end

function basic_vm.as_double(v)
    if math.type(v) == "integer" then return v + 0.0 end
    return v
end

--- 宿主可能返回 boolean（宿主语言里有，Stope 没有）：折成整数 1 / 0。
function basic_vm.normalize(v)
    if v == true then return 1 end
    if v == false then return 0 end
    return v
end

-- ============================== 真值 / 相等 ==============================

--- null -> 假；整数 / 宿主函数 -> 非零；浮点 -> 非 0；序列 -> 非空；其余 -> 真。
function basic_vm.truely(val)
    if val == NULL then return false end
    local mt = math.type(val)
    if mt == "integer" then return val ~= 0 end
    if type(val) == "function" then return true end
    if mt == "float" then return val ~= 0.0 end
    if basic_vm.is_str_value(val) then return #val.__stope_string ~= 0 end
    if type(val) == "string" then return #val ~= 0 end -- BinArr
    return true
end

--- 类型不同一律不等。String 按码元（UTF-16LE 字节）相等；BinArr 按字节相等。
function basic_vm.equals(left, right)
    if left == NULL or right == NULL then
        return left == NULL and right == NULL
    end
    local lt, rt = math.type(left), math.type(right)
    if lt == "integer" and rt == "integer" then return left == right end
    if lt == "integer" and rt == "float" then return (left + 0.0) == right end
    if lt == "float" and rt == "integer" then return left == (right + 0.0) end
    if lt == "float" and rt == "float" then return left == right end
    if basic_vm.is_str_value(left) and basic_vm.is_str_value(right) then
        return left.__stope_string == right.__stope_string
    end
    if type(left) == "string" and type(right) == "string" then
        return left == right -- BinArr 逐字节
    end
    if type(left) == "function" and type(right) == "function" then
        return left == right
    end
    if basic_vm.is_handle(left) and basic_vm.is_handle(right) then
        return left == right -- 同一性
    end
    return false
end

local function less_than(s, left, right)
    if basic_vm.is_number(left) and basic_vm.is_number(right) then
        return basic_vm.as_double(left) < basic_vm.as_double(right)
    end
    s:error("only on integer or float can be compared. ")
    return false
end

local function greater_than(s, left, right)
    return less_than(s, right, left)
end

local function check_arith(s, op, left, right)
    if left == NULL or right == NULL then
        s:error(string.format('"%s" cannot operate on null. ', op))
        return false
    end
    if not basic_vm.is_number(left) or not basic_vm.is_number(right) then
        s:error(string.format('"%s" can only operate on integer or float. ', op))
        return false
    end
    return true
end

--- 整数除以 0 -> 报错（不做除法）。只有两侧都是整数才是整数除法；
--- 任一侧是 Float 就走 IEEE，不拦（1.0 / 0 与 1 / 0.0 都得 inf）。
local function check_int_zero(s, op, left, right)
    if basic_vm.is_int(left) and basic_vm.is_int(right) and right == 0 then
        s:error(string.format('"%s" division by zero. ', op))
        return false
    end
    return true
end

-- ============================== State ==============================

local State = {}
State.__index = State
basic_vm.State = State

function basic_vm.State.new()
    return setmetatable({
        api = nil, program = nil, args = nil,
        returns = {}, i = 0, variables = {}, stack = {}, errors = {},
    }, State)
end

function State:set_api(api)
    self.api = api
end

--- 绑定程序：按 variable_num 开好槽位、i 归零、清运行态。
---（C++ 侧那句必写的 state.variables.resize(...) 在这里由 set_program 代做。）
function State:set_program(program)
    self.program = program
    self.returns = {}
    self.i = 0
    self.variables = {}
    for k = 0, program.variable_num - 1 do
        self.variables[k] = NULL -- 0 起的槽位
    end
    self.stack = {}
    self.errors = {}
end

function State:set_arguments(args)
    self.args = args
end

--- 宿主的报错入口："<指令下标>: msg"。
function State:error(msg)
    self.errors[#self.errors + 1] = string.format("%d: %s", self.i, msg)
end

function State:has_error()
    return #self.errors > 0
end

--- 执行【一条】指令。Result.Success = 这条跑完了且没出错，可以接着 step。
--- 返回 Error 有两种情况，靠 errors 区分：非空 = 出错（i 停在出错那条）；
--- 空 = 指令流已经走完（i 越过末尾）。
function State:step()
    if #self.errors > 0 then
        return Result.Error
    end
    local ops = self.program.opcodes
    if self.i >= #ops then
        return Result.Success
    end
    self.api.op_map[ops[self.i + 1] + 1](self) -- op_map 1 起、指令编号 0 起
    if #self.errors > 0 then
        return Result.Error
    end
    self.i = self.i + 1
    return Result.Success
end

--- 一直执行到指令流结束；出错立即停。与 step 是【两份独立实现】（热循环里不套一层
--- 函数调用），由 test_vm 的 V-21 锁两条路径一致。
function State:run()
    local ops = self.program.opcodes -- 执行中不会变长（Return 只是把 i 拨到末尾）
    local n = #ops
    local op_map = self.api.op_map
    local errors = self.errors
    while self.i < n do
        op_map[ops[self.i + 1] + 1](self)
        if #errors > 0 then
            return Result.Error
        end
        self.i = self.i + 1
    end
    return Result.Success
end

-- 栈顶下标一律「从栈顶数、1 起算」：at_top(1) 就是 stack[#stack]
function State:at_top(k)
    return self.stack[#self.stack - k + 1]
end

function State:pop()
    self.stack[#self.stack] = nil
end

function State:pop_n(num)
    for _ = 1, num do
        self.stack[#self.stack] = nil
    end
end

function State:push_int(v)
    self.stack[#self.stack + 1] = v -- Lua 整数天生 int64
end

--- 二元算术统一的收尾：弹出右操作数，结果写回左操作数的位置。
function State:store_binary(result)
    self.stack[#self.stack] = nil
    self.stack[#self.stack] = result
end

-- ⚠ 没有「解引用」helper：编译器保证 PushId 只出现在赋值左端，其余读变量一律
-- PushValue。收到 Identifier 就是产物错了，该让它当场暴露（与 C++ 一致）。

-- ============================== 指令 ==============================

local function op_assign(s)
    if #s.stack < 2 then
        s:error("stack underflow. ")
        return
    end
    local target = s:at_top(2)
    if basic_vm.is_handle(target) then
        -- 宿主引用：写回宿主（栈纪律在此，值计算在覆写里）
        s.api:handle_assign(s, target, s.stack[#s.stack])
        if not s:has_error() then
            s:pop_n(2)
        end
        return
    end
    if not is_identifier(target) then
        s:error("no implement for value type. ")
        return
    end
    s.variables[target.index] = s.stack[#s.stack]
    s:pop_n(2)
end

local function op_push_null(s) s.stack[#s.stack + 1] = NULL end

local function op_push_false(s) s.stack[#s.stack + 1] = 0 end

local function op_push_true(s) s.stack[#s.stack + 1] = 1 end

local function op_push_int(s)
    s.i = s.i + 1
    s.stack[#s.stack + 1] = s.program.int_consts[s.program.opcodes[s.i + 1] + 1]
end

local function op_push_float(s)
    s.i = s.i + 1
    s.stack[#s.stack + 1] = s.program.float_consts[s.program.opcodes[s.i + 1] + 1]
end

local function op_push_string(s)
    s.i = s.i + 1
    s.stack[#s.stack + 1] = basic_vm.str_value(s.program.string_consts[s.program.opcodes[s.i + 1] + 1])
end

local function op_push_binarr(s)
    s.i = s.i + 1
    s.stack[#s.stack + 1] = s.program.binarr_consts[s.program.opcodes[s.i + 1] + 1]
end

local function op_push_value(s)
    s.i = s.i + 1
    s.stack[#s.stack + 1] = s.variables[s.program.opcodes[s.i + 1]] -- 压【值】
end

local function op_push_id(s)
    s.i = s.i + 1
    s.stack[#s.stack + 1] = basic_vm.Identifier(s.program.opcodes[s.i + 1]) -- 不能是值
end

local function op_call(s)
    -- 不检查栈下溢：参数个数在编译期就定了
    s.i = s.i + 1
    local arg_num = s.program.opcodes[s.i + 1]
    local callee = s:at_top(arg_num + 1)
    if basic_vm.is_handle(callee) then
        -- 宿主引用：调用经宿主（方法 / 构造器描述符）
        local argv_h = {}
        for k = arg_num, 1, -1 do
            argv_h[#argv_h + 1] = s:at_top(k)
        end
        local out_h = s.api:handle_call(s, callee, argv_h)
        if s:has_error() then
            return
        end
        s:pop_n(arg_num)
        s.stack[#s.stack] = out_h
        return
    end
    if not basic_vm.is_func(callee) then
        s:error('"Call" can only call a function. ')
        return
    end
    local argv = {}
    for k = arg_num, 1, -1 do
        argv[#argv + 1] = s:at_top(k)
    end
    local out = basic_vm.normalize(callee(argv)) -- 参数整包进来，由宿主自己拆
    s:pop_n(arg_num)
    s.stack[#s.stack] = out
end

local function op_at(s)
    -- 不检查栈下溢：key 个数在编译期就定了
    s.i = s.i + 1
    local key_num = s.program.opcodes[s.i + 1]
    if key_num ~= 1 then
        s:error("no implement for key num != 1. ")
        return
    end
    local container = s:at_top(2)
    local key = s:at_top(1)
    if basic_vm.is_handle(container) then
        -- 宿主引用：读经宿主，key 不限于整数
        local out = s.api:handle_at(s, container, key)
        if s:has_error() then
            return
        end
        s:pop_n(key_num + 1)
        s.stack[#s.stack + 1] = out
        return
    end
    if not basic_vm.is_int(key) then
        s:error("index must be integer. ")
        return
    end
    local index = key
    local result
    if basic_vm.is_str_value(container) then
        -- String：取的是码元（UTF-16），不是单字符 —— 与 C++ / C# 一致
        local units = container.__stope_string
        if index < 0 or index * 2 + 2 > #units then
            s:error("index out of range. ")
            return
        end
        local lo, hi = string.byte(units, index * 2 + 1, index * 2 + 2)
        result = lo | (hi << 8)
    elseif type(container) == "string" then
        -- BinArr：取字节
        if index < 0 or index >= #container then
            s:error("index out of range. ")
            return
        end
        result = string.byte(container, index + 1)
    else
        s:error("no implement for container type. ")
        return
    end
    s:pop_n(key_num + 1)
    s.stack[#s.stack + 1] = result
end

local function op_pop(s) s:pop() end

local function op_minus(s)
    local val = s.stack[#s.stack]
    if basic_vm.is_int(val) then
        s.stack[#s.stack] = -val -- 回绕，不检查溢出
    elseif basic_vm.is_float(val) then
        s.stack[#s.stack] = -val
    else
        s:error('"Minus" can only operate on integer or float. ')
    end
end

local function op_not(s)
    local val = s.stack[#s.stack]
    if val == NULL then
        s.stack[#s.stack] = 1
    elseif basic_vm.is_int(val) then
        s.stack[#s.stack] = (val == 0) and 1 or 0
    elseif basic_vm.is_float(val) then
        s.stack[#s.stack] = (val == 0.0) and 1 or 0
    else
        s:error('"Not" can only operate on integer or float. ')
    end
end

local function op_pow(s)
    local left = s:at_top(2)
    local right = s:at_top(1)
    if not check_arith(s, "Pow", left, right) then return end
    -- 两个整数且指数 >= 0 -> 整数结果；负指数（2 ^ -1）-> Float(0.5)。与常量折叠一致。
    if basic_vm.is_int(left) and basic_vm.is_int(right) and right >= 0 then
        s:store_binary(common.int_pow(left, right))
    else
        s:store_binary(common.fpow(basic_vm.as_double(left), basic_vm.as_double(right)))
    end
end

local function op_mul(s)
    local left = s:at_top(2)
    local right = s:at_top(1)
    if left == NULL or right == NULL then
        s:error('"Mul" cannot operate on null. ')
        return
    end
    if basic_vm.is_number(left) and basic_vm.is_number(right) then
        if basic_vm.is_int(left) and basic_vm.is_int(right) then
            s:store_binary(left * right) -- 回绕
        else
            s:store_binary(basic_vm.as_double(left) * basic_vm.as_double(right))
        end
        return
    end
    if (is_seq(left) and basic_vm.is_int(right)) or (basic_vm.is_int(left) and is_seq(right)) then
        -- 序列重复：2 * "ab" 与 "ab" * 2 都要成立 —— 取序列那一侧
        local seq, times
        if is_seq(left) then
            seq = left
            times = right
        else
            seq = right
            times = left
        end
        if times < 0 then
            -- 宿主原生 repeat 对负数会静默给空串，不判就是错的
            s:error('"Mul" cannot repeat a sequence by a negative number. ')
            return
        end
        if basic_vm.is_str_value(seq) then
            s:store_binary(basic_vm.str_value(seq.__stope_string:rep(times)))
        else
            s:store_binary(seq:rep(times)) -- BinArr 字节重复
        end
        return
    end
    s:error('"Mul" can only operate on numbers, or repeat a string / bin array by an integer. ')
end

local function op_div(s)
    local left = s:at_top(2)
    local right = s:at_top(1)
    if not check_arith(s, "Div", left, right) then return end
    if not check_int_zero(s, "Div", left, right) then return end
    if basic_vm.is_int(left) and basic_vm.is_int(right) then
        -- 除不尽 -> 浮点数（7 / 2 是 Float(3.5)）；整除要用 idiv。与常量折叠一致。
        if common.int_mod(left, right) == 0 then
            s:store_binary(common.int_div(left, right))
        else
            s:store_binary(common.fdiv(left + 0.0, right + 0.0))
        end
    else
        s:store_binary(common.fdiv(basic_vm.as_double(left), basic_vm.as_double(right)))
    end
end

local function op_idiv(s)
    local left = s:at_top(2)
    local right = s:at_top(1)
    if not check_arith(s, "IDiv", left, right) then return end
    if not check_int_zero(s, "IDiv", left, right) then return end
    if basic_vm.is_int(left) and basic_vm.is_int(right) then
        s:store_binary(common.int_div(left, right)) -- 向零取整
    else
        -- 含浮点：仍按数值整除（向零取整），结果保持浮点，不做 float->int 收窄
        s:store_binary(common.trunc(common.fdiv(
            basic_vm.as_double(left), basic_vm.as_double(right))))
    end
end

local function op_mod(s)
    local left = s:at_top(2)
    local right = s:at_top(1)
    if not check_arith(s, "Mod", left, right) then return end
    if not check_int_zero(s, "Mod", left, right) then return end
    if basic_vm.is_int(left) and basic_vm.is_int(right) then
        s:store_binary(common.int_mod(left, right)) -- 余数符号跟被除数
    else
        -- 用 fmod：余数符号跟被除数，与 C++/JS/C# 一致
        s:store_binary(common.fmod(basic_vm.as_double(left), basic_vm.as_double(right)))
    end
end

local function op_add(s)
    local left = s:at_top(2)
    local right = s:at_top(1)
    -- null 不是「加法单位元」，也不与任何值做算术 —— 一律报错
    if left == NULL or right == NULL then
        s:error('"Add" cannot operate on null. ')
        return
    end
    if basic_vm.is_int(left) then
        if basic_vm.is_int(right) then
            s:store_binary(left + right) -- 回绕
        elseif basic_vm.is_float(right) then
            s:store_binary((left + 0.0) + right)
        else
            s:error("integer can only add integer or float. ")
        end
    elseif basic_vm.is_float(left) then
        if basic_vm.is_number(right) then
            s:store_binary(left + basic_vm.as_double(right))
        else
            s:error("float can only add integer or float. ")
        end
    elseif basic_vm.is_str_value(left) and basic_vm.is_str_value(right) then
        s:store_binary(basic_vm.str_value(
            left.__stope_string .. right.__stope_string))
    elseif basic_vm.is_binarr(left) and basic_vm.is_binarr(right) then
        s:store_binary(left .. right)
    else
        s:error('"Add" can only operate on numbers, strings or bin arrays. ')
    end
end

local function op_sub(s)
    local left = s:at_top(2)
    local right = s:at_top(1)
    if not check_arith(s, "Sub", left, right) then return end
    if basic_vm.is_int(left) then
        if basic_vm.is_int(right) then
            s:store_binary(left - right) -- 回绕
        elseif basic_vm.is_float(right) then
            s:store_binary((left + 0.0) - right)
        else
            s:error("integer can only subtract integer or float. ")
        end
    elseif basic_vm.is_float(left) then
        if basic_vm.is_number(right) then
            s:store_binary(left - basic_vm.as_double(right))
        else
            s:error("float can only subtract integer or float. ")
        end
    else
        s:error('"Sub" can only operate on integer or float. ')
    end
end

local function op_eq(s)
    s:store_binary(basic_vm.equals(s:at_top(2), s:at_top(1)) and 1 or 0)
end

local function op_ne(s)
    s:store_binary(basic_vm.equals(s:at_top(2), s:at_top(1)) and 0 or 1)
end

local function op_lt(s)
    s:store_binary(less_than(s, s:at_top(2), s:at_top(1)) and 1 or 0)
end

local function op_le(s)
    s:store_binary((not greater_than(s, s:at_top(2), s:at_top(1))) and 1 or 0)
end

local function op_gt(s)
    s:store_binary(greater_than(s, s:at_top(2), s:at_top(1)) and 1 or 0)
end

local function op_ge(s)
    s:store_binary((not less_than(s, s:at_top(2), s:at_top(1))) and 1 or 0)
end

local function op_if(s)
    local yes = basic_vm.truely(s.stack[#s.stack])
    s:pop() -- 条件用完即弹，不再留在栈上
    s.i = s.i + 1 -- 跳过操作数；条件成立时 step/run 的 +1 正好落到下一句
    local target = s.program.opcodes[s.i + 1]
    if not yes then
        s.i = target - 1
    end
end

local function op_goto(s)
    s.i = s.program.opcodes[s.i + 2] - 1 -- 操作数在 i+1
end

local function op_get_arg(s)
    if s.args == nil then
        s:error("no args. ")
        return
    end
    -- 先弹 key 再取参：实参表可能拿 key 做准备
    local key = s.stack[#s.stack]
    s.stack[#s.stack] = nil
    s.stack[#s.stack + 1] = basic_vm.normalize(s.args:at(s, key))
end

local function op_arg_num(s)
    if s.args == nil then
        s:error("no args. ")
        return
    end
    s.stack[#s.stack + 1] = s.args:num()
end

local function op_return(s)
    s.i = s.i + 1
    local num = s.program.opcodes[s.i + 1]
    local rets = {}
    for k = num, 1, -1 do
        rets[#rets + 1] = s:at_top(k)
    end
    s.returns = rets
    s.i = #s.program.opcodes
end

--- 占位处理函数：指令表被 set_opcode 撑出来但那一格没注册。
local function op_unimplemented(s)
    s:error(string.format("no implement for opcode %d. ", s.program.opcodes[s.i + 1]))
end

--- 指令分派表。op_map 的下标 = 指令编号 + 1（Lua 数组 1 起）。
local Api = {}
Api.__index = Api
basic_vm.Api = Api

function basic_vm.Api.new()
    local self = setmetatable({}, Api)
    self.op_map = {
        op_assign, op_push_null, op_push_false, op_push_true, op_push_int,
        op_push_float, op_push_string, op_push_binarr, op_push_value, op_push_id,
        op_call, op_at, op_pop, op_minus, op_not,
        op_pow, op_mul, op_div, op_idiv, op_mod,
        op_add, op_sub, op_eq, op_ne, op_lt,
        op_le, op_gt, op_ge, op_if, op_goto,
        op_get_arg, op_arg_num, op_return,
    }
    return self
end

--- 装一条自定义指令的处理函数：fn(state) -> None。会把中间补齐。
function Api:set_opcode(opcode, fn)
    while #self.op_map <= opcode do
        self.op_map[#self.op_map + 1] = op_unimplemented
    end
    self.op_map[opcode + 1] = fn
end

-- ---------------- Handle（宿主引用）的三个开口 ----------------
-- 默认实现一律报错（与 C++ API 的同名虚函数语义一致）。宿主覆写后，At / Assign /
-- Call 遇到 Handle 才会走进宿主的实现。注意 op_map 里的指令是模块级函数，Handle
-- 分支经 **s.api**（State 挂着的 Api 实例）转发——Lua 没有 class 继承语法，惯用
-- 法是在实例上覆写这三个字段（或用元表链做子类）。栈纪律（弹参、压返回值）由
-- 上面的指令负责，覆写者只管算值、出错时 s:error(...)。

--- Handle 的 At：读经宿主。默认报错。
function Api:handle_at(_s, _handle, _key)
    _s:error("no implement for container type. ")
    return NULL
end

--- Handle 的 Assign：写回宿主。默认报错。
function Api:handle_assign(_s, _handle, _value)
    _s:error("no implement for value type. ")
end

--- Handle 的 Call：调用经宿主。默认报错。
function Api:handle_call(_s, _handle, _args)
    _s:error('"Call" can only call a function. ')
    return NULL
end

return basic_vm
