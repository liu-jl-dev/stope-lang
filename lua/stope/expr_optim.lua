-- expr_optim.lua —— 常量折叠。端口 python/stope/expr_optim.py（C++ 为权威实现）。
--
-- 契约：
-- * 只做「单节点」变换，不递归；挂在 parser 构造 UnaryOpExpr / BinaryOpExpr 的末尾；
-- * optimize 成功折叠时返回**新**节点，未折叠时返回入参本身；
-- * 拿不准就一律不折叠：除零、含浮点的 idiv、跨类型 ==、null 参与比较、
--   Bool 参与比较 —— 全部保留原节点。折叠后的节点沿用运算符节点的 line；
-- * 整数溢出不检查、按 64 位回绕（Lua 整数自带）。
--
-- 判断顺序（层号同 cpp/docs/expr-optim.md）：
--   L0 两侧必须都是字面量常量 -> L1 and/or -> L2 任一侧 null -> L3 比较 -> L4 算术。

local ast = require("stope.ast")
local common = require("stope.common")
local token_mod = require("stope.token")

local NT = ast.NodeType
local T = token_mod.TokenType

local expr_optim = {}

MAX_REPEAT_ELEM = 1 << 20 -- 串重复的元素数上限：1 M（码元 / 字节）

-- 常量分类
expr_optim.NotConst = 0
expr_optim.Null = 1
expr_optim.Bool = 2
expr_optim.Int = 3
expr_optim.Float = 4
expr_optim.String = 5
expr_optim.BinArr = 6
local NotConst, Null, Bool, Int, Float, String, BinArr =
    0, 1, 2, 3, 4, 5, 6

-- ==================== 入口 ====================

function expr_optim.optimize(x)
    if x == nil then return nil end
    if x.nt == NT.UnaryOpExpr then
        return expr_optim.fold_unary(x)
    elseif x.nt == NT.BinaryOpExpr then
        return expr_optim.fold_binary(x)
    end
    return x
end

-- ==================== 常量分类与取值 ====================

local function kind_of(x)
    if x == nil then return NotConst end
    local t = x.nt
    if t == NT.NullExpr then return Null
    elseif t == NT.BoolExpr then return Bool
    elseif t == NT.IntExpr then return Int
    elseif t == NT.FloatExpr then return Float
    elseif t == NT.StringExpr then return String
    elseif t == NT.BinArrExpr then return BinArr
    end
    return NotConst
end

local function is_const(k) return k ~= NotConst end
local function is_numeric(k) return k == Int or k == Float end
local function both_int(lk, rk) return lk == Int and rk == Int end
local function is_seq(k) return k == String or k == BinArr end
local function is_num_like(k) return k == Bool or is_numeric(k) end
local function both_num_int(lk, rk)
    return is_num_like(lk) and is_num_like(rk) and lk ~= Float and rk ~= Float
end

local function num_as_int(x)
    if x.nt == NT.BoolExpr then return x.value and 1 or 0 end
    return x.value
end

local function as_double(x)
    if x.nt == NT.BoolExpr then return x.value and 1.0 or 0.0 end
    if x.nt == NT.IntExpr then return x.value + 0.0 end
    return x.value
end

local function seq_size(x) return #x.value end

local function seq_equal(a, b) return a.value == b.value end

local function make_seq(line, k)
    if k == String then return ast.StringExpr(line, "") end
    return ast.BinArrExpr(line, "")
end

local function seq_append(dst, src) dst.value = dst.value .. src.value end

local function truthy(x)
    local t = x.nt
    if t == NT.NullExpr then return false
    elseif t == NT.BoolExpr then return x.value
    elseif t == NT.IntExpr then return x.value ~= 0
    elseif t == NT.FloatExpr then return x.value ~= 0.0
    elseif is_seq(kind_of(x)) then return seq_size(x) ~= 0
    end
    return false
end

expr_optim.truthy = truthy

-- ==================== 造节点 / 取负 / 串重复 ====================

local function make_bool(line, v) return ast.BoolExpr(line, v) end
local function make_int(line, v) return ast.IntExpr(line, v) end
local function make_float(line, v) return ast.FloatExpr(line, v) end

local function clone_const(line, x)
    local t = x.nt
    if t == NT.NullExpr then return ast.NullExpr() end
    if t == NT.BoolExpr then return make_bool(line, x.value) end
    if t == NT.IntExpr then return make_int(line, x.value) end
    if t == NT.FloatExpr then return make_float(line, x.value) end
    local k = kind_of(x)
    if not is_seq(k) then return nil end
    local r = make_seq(line, k)
    seq_append(r, x)
    return r
end

local function negate_const(line, x)
    local t = x.nt
    if t == NT.BoolExpr then
        return make_int(line, x.value and -1 or 0)
    elseif t == NT.IntExpr then
        return make_int(line, -x.value) -- Lua 一元负号回绕
    elseif t == NT.FloatExpr then
        return make_float(line, -x.value)
    end
    return nil
end

local function repeat_seq(line, base, times)
    if times < 0 then return nil end
    local unit = seq_size(base)
    if unit == 0 then
        return make_seq(line, kind_of(base))
    end
    if times > MAX_REPEAT_ELEM // unit then return nil end
    local r = make_seq(line, kind_of(base))
    r.value = base.value:rep(times) -- 字节重复 == 码元/字节重复
    return r
end

local function cmp_of(op, a, b)
    if op == T.LT then return a < b
    elseif op == T.LE then return a <= b
    elseif op == T.GT then return a > b
    end
    return a >= b
end

-- ==================== 一元 ====================

function expr_optim.fold_unary(x)
    if x == nil or x.expr == nil then return x end
    local line = x.line
    local inn = x.expr
    local ck = kind_of(inn)
    if not is_const(ck) then return x end
    local ret = nil
    if x.op == T.Not then
        -- `!` 走 truthy；序列与 Bool 之外的非常量已在上面挡掉
        if ck == Null or is_num_like(ck) then
            ret = make_bool(line, not truthy(inn))
        end
    elseif x.op == T.Sub then
        ret = negate_const(line, inn)
    end
    if ret == nil then return x end
    return ret
end

-- ==================== 二元 ====================

function expr_optim.fold_binary(x)
    if x == nil or x.left_expr == nil or x.right_expr == nil then return x end
    local ret = expr_optim.try_fold_binary(x)
    if ret == nil then return x end
    return ret
end

function expr_optim.try_fold_binary(x)
    local line = x.line
    local op = x.op
    local L = x.left_expr
    local R = x.right_expr
    local lk = kind_of(L)
    local rk = kind_of(R)
    -- L0 两侧必须都是字面量常量
    if not is_const(lk) or not is_const(rk) then
        return nil
    end

    -- ---------- L1 and / or：结果与类型无关，恒返回 Bool ----------
    if op == T.And then
        return make_bool(line, truthy(L) and truthy(R))
    elseif op == T.Or then
        return make_bool(line, truthy(L) or truthy(R))
    end

    -- ---------- L2 null 参与 ----------
    if lk == Null or rk == Null then
        local both_null = (lk == Null) and (rk == Null)
        if op == T.EQ then
            return make_bool(line, both_null)
        elseif op == T.NE then
            return make_bool(line, not both_null)
        end
        return nil
    end

    -- ---------- L3 相等与大小比较 ----------
    if op == T.EQ or op == T.NE then
        local decided = false
        local eq = false
        if lk == Bool and rk == Bool then
            decided = true
            eq = L.value == R.value
        elseif is_numeric(lk) and is_numeric(rk) then
            decided = true
            if both_int(lk, rk) then
                eq = num_as_int(L) == num_as_int(R)
            else
                eq = as_double(L) == as_double(R)
            end
        elseif is_seq(lk) and lk == rk then
            decided = true
            eq = seq_equal(L, R)
        end
        if decided then
            return make_bool(line, (op == T.EQ) and eq or (not eq))
        end
        return nil
    end
    if op == T.LT or op == T.LE or op == T.GT or op == T.GE then
        if is_numeric(lk) and is_numeric(rk) then
            if both_int(lk, rk) then
                return make_bool(line, cmp_of(op, num_as_int(L), num_as_int(R)))
            end
            return make_bool(line, cmp_of(op, as_double(L), as_double(R)))
        end
        return nil
    end

    -- ---------- L4 算术 + - * / idiv % ^ ----------
    if is_num_like(lk) then
        -- ===== L4a 左值是 Bool / Int / Float =====
        if op == T.Add or op == T.Sub or op == T.Mul then
            if is_num_like(rk) then
                if both_num_int(lk, rk) then
                    local a = num_as_int(L)
                    local b = num_as_int(R)
                    if op == T.Add then return make_int(line, a + b) end
                    if op == T.Sub then return make_int(line, a - b) end
                    return make_int(line, a * b) -- Lua 整数回绕
                end
                local x = as_double(L)
                local y = as_double(R)
                if op == T.Add then return make_float(line, x + y) end
                if op == T.Sub then return make_float(line, x - y) end
                return make_float(line, x * y)
            elseif op == T.Mul and is_seq(rk) and lk ~= Float then
                return repeat_seq(line, R, num_as_int(L)) -- 数字 * 串 == 串重复
            end
        elseif op == T.Div then
            if is_num_like(rk) then
                if both_num_int(lk, rk) then
                    local a = num_as_int(L)
                    local b = num_as_int(R)
                    if b ~= 0 then -- 除零 -> 不折叠；除不尽 -> 浮点数
                        if common.int_mod(a, b) == 0 then
                            return make_int(line, common.int_div(a, b))
                        end
                        return make_float(line, (a + 0.0) / (b + 0.0))
                    end
                else
                    local bb = as_double(R)
                    if bb ~= 0.0 then
                        return make_float(line, as_double(L) / bb)
                    end
                end
            end
        elseif op == T.IDiv then
            if both_num_int(lk, rk) then -- 含浮点 -> 收窄成整数，不折叠
                local a = num_as_int(L)
                local b = num_as_int(R)
                if b ~= 0 then
                    return make_int(line, common.int_div(a, b)) -- 向零取整
                end
            end
        elseif op == T.Mod then
            if is_num_like(rk) then
                if both_num_int(lk, rk) then
                    local a = num_as_int(L)
                    local b = num_as_int(R)
                    if b ~= 0 then
                        return make_int(line, common.int_mod(a, b))
                    end
                else
                    local bb = as_double(R)
                    if bb ~= 0.0 then
                        -- 必须 fmod：余数符号跟被除数
                        return make_float(line, common.fmod(as_double(L), bb))
                    end
                end
            end
        elseif op == T.Pow then
            if is_num_like(rk) then
                if both_num_int(lk, rk) then
                    local b = num_as_int(R)
                    if b >= 0 then -- 非负整数指数走快速幂（溢出回绕）
                        return make_int(line, common.int_pow(num_as_int(L), b))
                    end
                end
                -- 负指数 / 含浮点：fpow（Lua 的 ^ 就是 C pow）
                local rr = common.fpow(as_double(L), as_double(R))
                if not common.is_special(rr) then
                    return make_float(line, rr) -- NaN / Inf -> 不折叠
                end
            end
        end
    elseif is_seq(lk) then
        -- ===== L4b 左值是序列（String / BinArr）=====
        if op == T.Add then
            if rk == lk then -- 同类才连接（跨类型不折）
                local ret = make_seq(line, lk)
                seq_append(ret, L)
                seq_append(ret, R)
                return ret
            end
        elseif op == T.Mul then
            if rk == Int or rk == Bool then
                return repeat_seq(line, L, num_as_int(R)) -- 串 * 整数 == 串重复
            end
        end
        -- 其余运算符（Sub 等）对序列无定义 -> 不折叠
    end
    return nil
end

return expr_optim
