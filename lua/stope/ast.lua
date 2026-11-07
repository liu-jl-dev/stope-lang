-- ast.lua —— AST 节点定义与形状串序列化。端口 python/stope/ast.py。
--
-- 节点一律是普通 table：`nt` 是节点类型编号、`line` 是行号，其余字段与 Python 版同名。
-- shape_prog / shape_stmt / shape_expr 是测试用序列化，严格照抄 C++ test_common.hpp。
--
-- ⚠ 字符串节点的 value 是 **UTF-16LE 字节串**（内部表示）；
--   BinArr 节点的 value 是原始字节串。

local token_mod = require("stope.token")
local common = require("stope.common")

local ast = {}

ast.NodeType = {
    Node = 0, Prog = 1, Stmt = 2, Expr = 3, ExprStmt = 4, LetStmt = 5,
    ReturnStmt = 6, ExportStmt = 7, BlockStmt = 8, IfStmt = 9, WhileStmt = 10,
    AssignStmt = 11, BreakStmt = 12, ContinueStmt = 13, DeferStmt = 14,
    NullExpr = 15, BoolExpr = 16, IntExpr = 17, FloatExpr = 18, BinArrExpr = 19,
    StringExpr = 20, IdentExpr = 21, ArgcExpr = 22, ArgsExpr = 23,
    UnaryOpExpr = 24, BinaryOpExpr = 25, CallExpr = 26, AtExpr = 27,
    CustomOpcodeExpr = 28,
}
local NT = ast.NodeType

--- 10 档优先级，与 C++ common.hpp 的 OpPrecedence 同序同值。
ast.Precedence = {
    Lowest = 0, Or = 1, And = 2, Equals = 3, LessGreater = 4,
    AddSub = 5, MulDiv = 6, Pow = 7, Prefix = 8, Paren = 9,
}

local T = token_mod.TokenType

--- 二元运算符 -> 优先级。调用 ()、取元素 [] 也是二元形式，优先级最高。
ast.BINOP_PREC = {
    [T.Or] = 1, [T.And] = 2, [T.EQ] = 3, [T.NE] = 3,
    [T.LT] = 4, [T.LE] = 4, [T.GT] = 4, [T.GE] = 4,
    [T.Add] = 5, [T.Sub] = 5, [T.Mul] = 6, [T.Div] = 6,
    [T.IDiv] = 6, [T.Mod] = 6, [T.Pow] = 7,
    [T.LParen] = 9, [T.LBrack] = 9,
}

--- 二元运算符的显示文本（错误信息与 to_str 用）。
ast.BINOP_LITERAL = {
    [T.Or] = "||", [T.And] = "&&", [T.EQ] = "==", [T.NE] = "!=",
    [T.LT] = "<", [T.LE] = "<=", [T.GT] = ">", [T.GE] = ">=",
    [T.Add] = "+", [T.Sub] = "-", [T.Mul] = "*", [T.Div] = "/",
    [T.IDiv] = "idiv", [T.Mod] = "%", [T.Pow] = "^",
}

-- ================================ 构造函数 ================================

function ast.node(line, nt)
    return { line = line, nt = nt }
end

function ast.Prog(line)
    return { line = line or -1, nt = NT.Prog, stmts = {} }
end

function ast.ExprStmt(line)
    return { line = line or -1, nt = NT.ExprStmt, expr = nil }
end

function ast.LetStmt(line)
    return { line = line or -1, nt = NT.LetStmt, has_assign = false, idents = {}, expr = nil }
end

function ast.ReturnStmt(line)
    return { line = line or -1, nt = NT.ReturnStmt, exprs = {} }
end

function ast.ExportStmt(line)
    return { line = line or -1, nt = NT.ExportStmt, idents = {} }
end

function ast.BlockStmt(line)
    return { line = line or -1, nt = NT.BlockStmt, prog = ast.Prog() }
end

function ast.IfStmtElif(line)
    return { line = line or -1, nt = NT.Node, cond = nil, prog = ast.Prog() }
end

function ast.IfStmt(line)
    return { line = line or -1, nt = NT.IfStmt, cond = nil, first_prog = ast.Prog(),
             elifs = {}, else_prog = nil } -- else_prog 为 nil 表示没有 else 分支
end

function ast.WhileStmt(line)
    return { line = line or -1, nt = NT.WhileStmt, cond = nil, prog = ast.Prog() }
end

function ast.AssignStmt(line)
    return { line = line or -1, nt = NT.AssignStmt, left_expr = nil, right_expr = nil }
end

function ast.BreakStmt(line)
    return { line = line or -1, nt = NT.BreakStmt }
end

function ast.ContinueStmt(line)
    return { line = line or -1, nt = NT.ContinueStmt }
end

--- defer_stmt : "defer" stmt —— 载荷缺省（defer; 报错路径）时 stmt 为 nil。
function ast.DeferStmt(line)
    return { line = line or -1, nt = NT.DeferStmt, stmt = nil }
end

function ast.NullExpr(line)
    return { line = line or -1, nt = NT.NullExpr }
end

function ast.BoolExpr(line, v)
    return { line = line or -1, nt = NT.BoolExpr, value = v }
end

function ast.IntExpr(line, v)
    return { line = line or -1, nt = NT.IntExpr, value = v }
end

function ast.FloatExpr(line, v)
    return { line = line or -1, nt = NT.FloatExpr, value = v }
end

function ast.BinArrExpr(line, v)
    return { line = line or -1, nt = NT.BinArrExpr, value = v }
end

function ast.StringExpr(line, v)
    return { line = line or -1, nt = NT.StringExpr, value = v }
end

function ast.IdentExpr(line, v)
    return { line = line or -1, nt = NT.IdentExpr, ident = v }
end

function ast.ArgcExpr(line)
    return { line = line or -1, nt = NT.ArgcExpr }
end

function ast.ArgsExpr(line)
    return { line = line or -1, nt = NT.ArgsExpr, key_expr = nil }
end

function ast.UnaryOpExpr(line)
    return { line = line or -1, nt = NT.UnaryOpExpr, op = T.Invalid, expr = nil }
end

function ast.BinaryOpExpr(line)
    return { line = line or -1, nt = NT.BinaryOpExpr, left_expr = nil, op = T.Invalid,
             right_expr = nil }
end

function ast.CallExpr(line)
    return { line = line or -1, nt = NT.CallExpr, callee = nil, args = {} }
end

function ast.AtExpr(line)
    return { line = line or -1, nt = NT.AtExpr, container = nil, key_exprs = {} }
end

function ast.CustomOpcodeExpr(line)
    return { line = line or -1, nt = NT.CustomOpcodeExpr, opcode_name = "", args = {} }
end

--- 失败路径返回的裸 Expr：nt = NT.Expr，line 恒为 -1（形状 Err(L-1)）。
function ast.BareExpr(line)
    return { line = line, nt = NT.Expr }
end

-- ================================ 形状串（测试用） ================================

local function indent(level)
    return string.rep("  ", level)
end

local function e(n)
    -- to_str 的调试序列化（测试与 demo 不用它，只求不炸）
    if n == nil then return "<null>" end
    local t = n.nt
    if t == NT.Prog then
        local parts = {}
        for _, s in ipairs(n.stmts) do parts[#parts + 1] = e(s) end
        return table.concat(parts)
    elseif t == NT.ExprStmt then return e(n.expr) .. ";\n"
    elseif t == NT.NullExpr then return "null"
    elseif t == NT.BoolExpr then return n.value and "true" or "false"
    elseif t == NT.IntExpr then return string.format("%d", n.value)
    elseif t == NT.FloatExpr then return common.fmt_g(n.value)
    elseif t == NT.StringExpr then return '"' .. common.esc_u16(n.value, {}) .. '"'
    elseif t == NT.IdentExpr then return n.ident
    elseif t == NT.BinArrExpr then return "'[" .. common.fmt_bytes(n.value) .. "]'"
    end
    return "?"
end

local function op_text(op)
    if op == T.Sub then return "-" end
    if op == T.Not then return "!" end
    return token_mod.type_name(op) .. "("
end

local function esc(s)
    return common.esc_u16(s, { quote = false })
end

local function esc8(s)
    return common.esc_u8(s, {})
end

local function join(parts, sep)
    return table.concat(parts, sep)
end

function ast.shape_prog(p)
    if p == nil then return "null" end
    local parts = {}
    for _, s in ipairs(p.stmts) do
        parts[#parts + 1] = ast.shape_stmt(s)
    end
    return join(parts, " ; ")
end

function ast.shape_stmt(s)
    if s == nil then return "null" end
    local t = s.nt
    if t == NT.ExprStmt then
        return "ExprStmt(" .. ast.shape_expr(s.expr) .. ")"
    elseif t == NT.LetStmt then
        local names = {}
        for _, i in ipairs(s.idents) do names[#names + 1] = esc8(i) end
        local d = "Let[" .. join(names, ",") .. "]"
        if s.has_assign then
            d = d .. "=" .. ast.shape_expr(s.expr)
        end
        return d
    elseif t == NT.ReturnStmt then
        local parts = {}
        for _, x in ipairs(s.exprs) do parts[#parts + 1] = ast.shape_expr(x) end
        return "Return(" .. join(parts, ", ") .. ")"
    elseif t == NT.ExportStmt then
        local names = {}
        for _, i in ipairs(s.idents) do names[#names + 1] = esc8(i) end
        return "Export[" .. join(names, ",") .. "]"
    elseif t == NT.BlockStmt then
        return "Block{" .. ast.shape_prog(s.prog) .. "}"
    elseif t == NT.IfStmt then
        local d = "If(" .. ast.shape_expr(s.cond) .. "){" .. ast.shape_prog(s.first_prog) .. "}"
        for _, ei in ipairs(s.elifs) do
            d = d .. "Elif(" .. ast.shape_expr(ei.cond) .. "){" .. ast.shape_prog(ei.prog) .. "}"
        end
        if s.else_prog ~= nil then
            d = d .. "Else{" .. ast.shape_prog(s.else_prog) .. "}"
        end
        return d
    elseif t == NT.WhileStmt then
        return "While(" .. ast.shape_expr(s.cond) .. "){" .. ast.shape_prog(s.prog) .. "}"
    elseif t == NT.AssignStmt then
        return "Assign(" .. ast.shape_expr(s.left_expr) .. ", " .. ast.shape_expr(s.right_expr) .. ")"
    elseif t == NT.BreakStmt then
        return "Break"
    elseif t == NT.ContinueStmt then
        return "Continue"
    elseif t == NT.DeferStmt then
        return "Defer(" .. ast.shape_stmt(s.stmt) .. ")"
    end
    return "?" .. ast.node_type_name(t)
end

function ast.shape_expr(x)
    if x == nil then return "null" end
    local t = x.nt
    if t == NT.Expr then -- 失败路径返回的裸节点：line 恒为 -1
        return "Err(L" .. string.format("%d", x.line) .. ")"
    elseif t == NT.NullExpr then
        return "Null"
    elseif t == NT.ArgcExpr then
        return "Argc"
    elseif t == NT.BoolExpr then
        return x.value and "Bool(true)" or "Bool(false)"
    elseif t == NT.IntExpr then
        return "Int(" .. string.format("%d", x.value) .. ")"
    elseif t == NT.FloatExpr then
        return "Float(" .. common.fmt_g(x.value) .. ")"
    elseif t == NT.BinArrExpr then
        return "BinArr[" .. common.fmt_bytes(x.value) .. "]"
    elseif t == NT.StringExpr then
        return 'Str("' .. esc(x.value) .. '")'
    elseif t == NT.IdentExpr then
        return "Ident(" .. esc8(x.ident) .. ")"
    elseif t == NT.ArgsExpr then
        if x.key_expr == nil then return "Args(null)" end
        return "Args(" .. ast.shape_expr(x.key_expr) .. ")"
    elseif t == NT.UnaryOpExpr then
        return "Unary(" .. token_mod.type_name(x.op) .. ", " .. ast.shape_expr(x.expr) .. ")"
    elseif t == NT.BinaryOpExpr then
        return "Bin(" .. token_mod.type_name(x.op) .. ", " .. ast.shape_expr(x.left_expr)
            .. ", " .. ast.shape_expr(x.right_expr) .. ")"
    elseif t == NT.CallExpr then
        local parts = { ast.shape_expr(x.callee) }
        for _, a in ipairs(x.args) do parts[#parts + 1] = ast.shape_expr(a) end
        return "Call(" .. join(parts, "; ") .. ")"
    elseif t == NT.AtExpr then
        local parts = { ast.shape_expr(x.container) }
        for _, k in ipairs(x.key_exprs) do parts[#parts + 1] = ast.shape_expr(k) end
        return "At(" .. join(parts, "; ") .. ")"
    elseif t == NT.CustomOpcodeExpr then
        local parts = { esc8(x.opcode_name) }
        for _, a in ipairs(x.args) do parts[#parts + 1] = ast.shape_expr(a) end
        return "Custom(" .. join(parts, "; ") .. ")"
    end
    return "?" .. ast.node_type_name(t)
end

local NODE_TYPE_NAMES = {
    "Node", "Prog", "Stmt", "Expr", "ExprStmt", "LetStmt", "ReturnStmt",
    "ExportStmt", "BlockStmt", "IfStmt", "WhileStmt", "AssignStmt",
    "BreakStmt", "ContinueStmt", "DeferStmt", "NullExpr", "BoolExpr",
    "IntExpr", "FloatExpr", "BinArrExpr", "StringExpr", "IdentExpr",
    "ArgcExpr", "ArgsExpr", "UnaryOpExpr", "BinaryOpExpr", "CallExpr",
    "AtExpr", "CustomOpcodeExpr",
}

function ast.node_type_name(t)
    if t >= 0 and t < #NODE_TYPE_NAMES then
        return NODE_TYPE_NAMES[t + 1]
    end
    return "?" .. tostring(t)
end

return ast
