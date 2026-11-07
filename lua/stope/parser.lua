-- parser.lua —— Pratt 语法分析器。端口 python/stope/parser.py（C++ 为权威实现）。
--
-- 约定（与另外几套实现一致）：
-- 1. 错误恢复：分隔符缺失时只报错、不推进，把后续 token 留给下一条语句重新解析。
--    例外：parse_let_stmt / parse_return_stmt 的兜底分支仍会推进。
-- 2. 不变量：parse_expr() 之后必有一次 next_token()。
-- 3. 顶层孤立 } 要报错并跳过继续解析；块内的 } 由外层消费，不报错。
-- 4. 常量折叠挂在 parse_unary_op_expr / parse_binary_op_expr 的构造末尾。
-- 5. 节点取 token 的 parsed 而非 lexeme；只有 BinArr 取 lexeme。
--
-- ⚠ 嵌套深度上限 256（max_depth，0 = 不限）：depth 走函数参数。超限时报一条
-- "line N: nesting too deep (max 256). " 并置 aborted（此后所有 error 不再记账），
-- 子函数返回 nil 但不逐层传染。

local ast = require("stope.ast")
local common = require("stope.common")
local token_mod = require("stope.token")
local binarr_parser_mod = require("stope.binarr_parser")
local expr_optim = require("stope.expr_optim")

local Parser = {}
local MT = { __index = Parser }

local T = token_mod.TokenType
local P = ast.Precedence
local Result = common.Result

-- 分发表（前向声明，文件尾部填充 —— parse_expr 引用它们，必须提前进作用域）
local PREFIX_FNS
local INFIX_FNS

--- 默认嵌套深度上限（与 C++ Parser::maxDepth 相同，文案也逐字相同）
local K_DEFAULT_MAX_DEPTH = 256
Parser.K_DEFAULT_MAX_DEPTH = K_DEFAULT_MAX_DEPTH

function Parser.new(lexer, custom)
    local self = setmetatable({}, MT)
    self.bin_arr_parser = binarr_parser_mod.new()
    self.errors = {}
    self.aborted = false
    self.custom = custom
    self.const_folding = true
    self.max_depth = K_DEFAULT_MAX_DEPTH
    self.cur_token = nil
    self.peek_token = nil
    if lexer ~= nil then
        self:reset(lexer, custom)
    end
    return self
end

function Parser:reset(lexer, custom)
    self.errors = {}
    self.aborted = false
    self.lexer = lexer
    self.custom = custom
    self.const_folding = true
    self.max_depth = K_DEFAULT_MAX_DEPTH
    -- 先读两个 token，cur / peek 才都有值 —— 顺序不能变
    self:next_token()
    self:next_token()
end

function Parser:parse_program(prog)
    self:parse_prog(prog, true, 1)
end

-- ================================ 语句 ================================
function Parser:parse_prog(prog, is_top_level, depth)
    if self.aborted then return end
    while (not self.aborted) and self.cur_token.type ~= T.Eof do
        local t = self.cur_token.type
        if t == T.RBrace then
            if not is_top_level then
                break -- 块内：正常结束，不跳过，交给外层处理
            end
            self:error(self.cur_token.line, 'unexpected "}" at top level. ')
            self:next_token()
        elseif t == T.Semi then -- 空语句
            self:next_token()
        else
            -- 语句分派：循环体与 defer 载荷共用同一条链
            local stmt = self:parse_stmt_dispatch(depth)
            -- 超限中止时子函数返回 nil：不追加、不再往下解析
            if stmt == nil then
                break
            end
            prog.stmts[#prog.stmts + 1] = stmt
        end
    end
end

--- 语句分派：parse_prog 循环体与 defer 载荷共用同一条链。
--- "{" / ";" / "}" 等结构性 token 由调用方（parse_prog 循环或 parse_defer_stmt）
--- 处理。超限中止时返回 nil。
function Parser:parse_stmt_dispatch(depth)
    if self.aborted then return nil end
    local t = self.cur_token.type
    if t == T.Let then
        return self:parse_let_stmt(depth)
    elseif t == T.Export then
        return self:parse_export_stmt(depth)
    elseif t == T.Return then
        return self:parse_return_stmt(depth)
    elseif t == T.LBrace then
        return self:parse_block_stmt(depth)
    elseif t == T.If then
        return self:parse_if_stmt(depth)
    elseif t == T.While then
        return self:parse_while_stmt(depth)
    elseif t == T.Break then
        return self:parse_break_stmt(depth)
    elseif t == T.Continue then
        return self:parse_continue_stmt(depth)
    elseif t == T.Defer then
        return self:parse_defer_stmt(depth)
    else
        return self:parse_expr_or_assign_stmt(depth) -- 表达式语句或赋值语句
    end
end

--- defer_stmt : "defer" stmt —— 载荷是一条完整语句。
--- 直接嵌套（defer defer X）合法：内层 defer 的触发点 = 外层载荷 scope 的结束
--- = 同一退出点。载荷缺语句（defer; / defer } / defer Eof）时报错但**不推进**：
--- ";" 与 "}" 交给外层 parse_prog 循环，否则死循环或吞掉外层块的 "}"。
function Parser:parse_defer_stmt(depth)
    if self.aborted then return nil end
    local stmt = ast.DeferStmt(self.cur_token.line)
    self:next_token() -- 跳过 defer
    if self.cur_token.type == T.Semi or self.cur_token.type == T.RBrace
        or self.cur_token.type == T.Eof then
        self:error(self.cur_token.line, 'expected statement after "defer". ')
        return stmt
    end
    -- 载荷 +1：defer 可经「载荷 → 分派 → parse_defer_stmt」递归（defer defer
    -- defer …），深度上限必须能数到这种嵌套。
    stmt.stmt = self:parse_stmt_dispatch(depth + 1)
    return stmt
end

function Parser:parse_let_stmt(depth)
    local stmt = ast.LetStmt(self.cur_token.line)
    stmt.has_assign = false
    self:next_token() -- 跳过 let
    if self.cur_token.type ~= T.Ident then
        self:error(self.cur_token.line, 'expected identifier after "let". ')
        self:next_token()
        return stmt
    end
    stmt.idents[#stmt.idents + 1] = self.cur_token.parsed
    self:next_token()
    if self.cur_token.type == T.Semi then
        self:next_token()
    elseif self.cur_token.type == T.Comma then
        -- 多个标识符，禁止赋值
        while true do
            if self.cur_token.type == T.Comma and self.peek_token.type == T.Ident then
                stmt.idents[#stmt.idents + 1] = self.peek_token.parsed
                self:next_token()
                self:next_token()
            elseif self.cur_token.type == T.Semi then
                self:next_token()
                break
            elseif self.cur_token.type == T.Eof or self.cur_token.type == T.RBrace then
                -- 缺 ";": 此处不能再推进
                self:error(self.cur_token.line, 'expected ";" in let statement. ')
                break
            else
                self:error(self.cur_token.line,
                    "failed to parse let statement with multiple identifiers. ")
                self:next_token()
            end
        end
    elseif self.cur_token.type == T.Assign then
        stmt.has_assign = true
        self:next_token()
        stmt.expr = self:parse_expr(P.Lowest, depth)
        self:next_token()
    else
        self:error(self.cur_token.line, "unexpected token in let statement. ")
        self:next_token()
    end
    return stmt
end

function Parser:parse_export_stmt(_depth)
    local stmt = ast.ExportStmt(self.cur_token.line)
    self:next_token() -- 跳过 export
    if self.cur_token.type ~= T.Ident then
        self:error(self.cur_token.line, 'expected identifier after "export". ')
        self:next_token()
        return stmt
    end
    stmt.idents[#stmt.idents + 1] = self.cur_token.parsed
    self:next_token()
    if self.cur_token.type == T.Semi then
        self:next_token()
    elseif self.cur_token.type == T.Comma then
        while true do
            if self.cur_token.type == T.Comma and self.peek_token.type == T.Ident then
                stmt.idents[#stmt.idents + 1] = self.peek_token.parsed
                self:next_token()
                self:next_token()
            elseif self.cur_token.type == T.Semi then
                self:next_token()
                break
            elseif self.cur_token.type == T.Eof or self.cur_token.type == T.RBrace then
                self:error(self.cur_token.line, 'expected ";" in export statement. ')
                break
            else
                self:error(self.cur_token.line,
                    "failed to parse export statement with multiple identifiers. ")
                self:next_token()
            end
        end
    else
        self:error(self.cur_token.line, "unexpected token in export statement. ")
        self:next_token()
    end
    return stmt
end

function Parser:parse_return_stmt(depth)
    local stmt = ast.ReturnStmt(self.cur_token.line)
    self:next_token() -- 跳过 return
    if self.cur_token.type == T.Semi then
        self:next_token()
        return stmt
    end
    if self.cur_token.type == T.Eof or self.cur_token.type == T.RBrace then
        -- 缺 ";": 不能吞掉 } 或 Eof
        self:error(self.cur_token.line, 'expected ";" in return statement. ')
        return stmt
    end
    stmt.exprs[#stmt.exprs + 1] = self:parse_expr(P.Lowest, depth)
    self:next_token() -- 到达 , 或 ;
    while true do
        if self.cur_token.type == T.Semi then
            self:next_token()
            break
        elseif self.cur_token.type == T.Comma then
            self:next_token()
            stmt.exprs[#stmt.exprs + 1] = self:parse_expr(P.Lowest, depth)
            self:next_token()
        else
            self:error(self.cur_token.line, 'expected ";" or "," in return statement. ')
            self:next_token()
            break
        end
    end
    return stmt
end

function Parser:parse_block_stmt(depth)
    if self.aborted then return nil end
    local stmt = ast.BlockStmt(self.cur_token.line)
    self:next_token() -- 跳过 {
    stmt.prog = ast.Prog()
    self:parse_prog(stmt.prog, false, depth + 1)
    if self.cur_token.type ~= T.RBrace then
        self:error(self.cur_token.line, 'expected "}" at end of block statement. ')
    end
    self:next_token() -- 跳过 }
    return stmt
end

function Parser:parse_if_stmt(depth)
    if self.aborted then return nil end
    local stmt = ast.IfStmt(self.cur_token.line)
    self:next_token() -- 跳过 if
    stmt.cond = self:parse_expr(P.Lowest, depth)
    self:next_token() -- 到达 {
    if self.cur_token.type ~= T.LBrace then
        self:error(self.cur_token.line, 'expected "{" in if statement. ')
        return stmt
    end
    self:next_token() -- 跳过 {
    stmt.first_prog = ast.Prog()
    self:parse_prog(stmt.first_prog, false, depth + 1)
    if self.cur_token.type ~= T.RBrace then
        self:error(self.cur_token.line, 'expected "}" in if statement. ')
        return stmt
    end
    self:next_token() -- 跳过 }
    while self.cur_token.type == T.Elif do
        local ei = ast.IfStmtElif(self.cur_token.line)
        self:next_token() -- 跳过 elif
        ei.cond = self:parse_expr(P.Lowest, depth)
        self:next_token()
        if self.cur_token.type ~= T.LBrace then
            self:error(self.cur_token.line, 'expected "{" of elif. ')
            return stmt
        end
        self:next_token() -- 跳过 {
        ei.prog = ast.Prog()
        self:parse_prog(ei.prog, false, depth + 1)
        if self.cur_token.type ~= T.RBrace then
            self:error(self.cur_token.line, 'expected "}" of elif. ')
            return stmt
        end
        self:next_token() -- 跳过 }
        stmt.elifs[#stmt.elifs + 1] = ei
    end
    if self.cur_token.type == T.Else then
        self:next_token()
        if self.cur_token.type ~= T.LBrace then
            self:error(self.cur_token.line, 'expected "{" after else. ')
            return stmt
        end
        self:next_token() -- 跳过 {
        stmt.else_prog = ast.Prog()
        self:parse_prog(stmt.else_prog, false, depth + 1)
        if self.cur_token.type ~= T.RBrace then
            self:error(self.cur_token.line, 'expected "}" in if statement. ')
            return stmt
        end
        self:next_token() -- 跳过 }
    end
    return stmt
end

function Parser:parse_while_stmt(depth)
    if self.aborted then return nil end
    local stmt = ast.WhileStmt(self.cur_token.line)
    self:next_token() -- 跳过 while
    if self.cur_token.type ~= T.LBrace then
        stmt.cond = self:parse_expr(P.Lowest, depth)
        self:next_token() -- 到达 {
    end
    if self.cur_token.type ~= T.LBrace then
        self:error(self.cur_token.line, 'expected "{" in while statement. ')
        return stmt
    end
    self:next_token() -- 跳过 {
    stmt.prog = ast.Prog()
    self:parse_prog(stmt.prog, false, depth + 1)
    if self.cur_token.type ~= T.RBrace then
        self:error(self.cur_token.line, 'expected "}" at end of while statement. ')
        return stmt
    end
    self:next_token()
    return stmt
end

function Parser:parse_break_stmt(_depth)
    local stmt = ast.BreakStmt(self.cur_token.line)
    self:next_token() -- 跳过 break
    if self.cur_token.type ~= T.Semi then
        self:error(self.cur_token.line, 'expected ";" in break statement. ')
    else
        self:next_token()
    end
    return stmt
end

function Parser:parse_continue_stmt(_depth)
    local stmt = ast.ContinueStmt(self.cur_token.line)
    self:next_token() -- 跳过 continue
    if self.cur_token.type ~= T.Semi then
        self:error(self.cur_token.line, 'expected ";" in continue statement. ')
    else
        self:next_token()
    end
    return stmt
end

function Parser:parse_expr_or_assign_stmt(depth)
    local left_expr = self:parse_expr(P.Lowest, depth)
    if left_expr == nil then
        return nil -- 超限中止：下面要读 left_expr.line
    end
    self:next_token() -- 到达 = 或 ;
    if self.cur_token.type == T.Semi then
        self:next_token() -- 跳过 ;
        local s = ast.ExprStmt(left_expr.line)
        s.expr = left_expr
        return s
    elseif self.cur_token.type == T.Assign then
        self:next_token() -- 跳过 =
        local a = ast.AssignStmt(left_expr.line)
        a.left_expr = left_expr
        a.right_expr = self:parse_expr(P.Lowest, depth)
        self:next_token() -- 到达 ;
        if self.cur_token.type ~= T.Semi then
            self:error(self.cur_token.line, 'expected ";" at end of assign statement. ')
        end
        self:next_token()
        return a
    end
    self:error(self.cur_token.line, 'expected ";" or "=". ')
    -- 不推进：当前 token 不是合法的语句边界，留给下一轮语句解析
    local s2 = ast.ExprStmt(left_expr.line)
    s2.expr = left_expr
    return s2
end

-- ================================ 表达式主循环 ================================
function Parser:parse_expr(precedence, depth)
    -- 深度检查只在这里和 parse_prog 做 —— 只有这两处会递归
    if self.aborted then
        return nil
    end
    if self.max_depth > 0 and depth > self.max_depth then
        self:abort_too_deep(self.cur_token.line)
        return nil
    end
    local prefix = PREFIX_FNS[self.cur_token.type]
    if prefix == nil then
        self:error(self.cur_token.line, "no prefix parse function for token type. ")
        return ast.BareExpr(self.cur_token.line) -- 失败路径返回裸节点 Err(L行号)
    end
    local left_expr = prefix(self, depth)
    if left_expr == nil then
        return nil -- 子表达式已中止（括号会原样透出）
    end
    while (not self.aborted) and self.peek_token.type ~= T.Semi
        and precedence < self:peek_precedence() do
        local infix = INFIX_FNS[self.peek_token.type]
        if infix == nil then
            self:error(self.peek_token.line, "no infix parse function for token type. ")
            return left_expr
        end
        self:next_token()
        left_expr = infix(self, left_expr, depth)
        if left_expr == nil then
            return nil
        end
    end
    return left_expr
end

function Parser:cur_precedence()
    return ast.BINOP_PREC[self.cur_token.type] or P.Lowest
end

function Parser:peek_precedence()
    return ast.BINOP_PREC[self.peek_token.type] or P.Lowest
end

function Parser:optimize_in_place(x)
    if not self.const_folding then
        return x
    end
    return expr_optim.optimize(x)
end

-- ================================ 基础设施 ================================
function Parser:next_token()
    self.cur_token = self.peek_token
    self.peek_token = self.lexer:next_token(self.custom)
end

function Parser:error(line, msg)
    -- 嵌套超限中止之后的一切错误都是连锁反应，不再记账
    if self.aborted then
        return
    end
    self.errors[#self.errors + 1] = string.format("line %d: %s", line, msg)
end

function Parser:abort_too_deep(line)
    self:error(line, string.format("nesting too deep (max %d). ", self.max_depth)) -- 必须在置位之前记账
    self.aborted = true
end

function Parser:has_err()
    return #self.errors > 0
end

-- ================================ 前缀 ================================
local function parse_ident_expr(p, _depth)
    return ast.IdentExpr(p.cur_token.line, p.cur_token.parsed)
end

local function parse_null_expr(p, _depth)
    return ast.NullExpr(p.cur_token.line)
end

local function parse_bool_expr(p, _depth)
    return ast.BoolExpr(p.cur_token.line, p.cur_token.type == T.True_)
end

local function parse_int_expr(p, _depth)
    return ast.IntExpr(p.cur_token.line, p.cur_token.value)
end

local function parse_float_expr(p, _depth)
    return ast.FloatExpr(p.cur_token.line, p.cur_token.value)
end

local function parse_string_expr(p, _depth)
    -- 取 parsed：转义已完成（lexeme 是未转义的原文）；值是 UTF-16LE 内部表示
    return ast.StringExpr(p.cur_token.line, p.cur_token.parsed)
end

local function parse_binarr_expr(p, _depth)
    local x = ast.BinArrExpr(p.cur_token.line)
    -- 取 lexeme：二进制数组不做转义，解析到一半失败也要保留前半段（报错但继续）
    local buf = {}
    local rc = p.bin_arr_parser:parse_binary_array(p.cur_token.lexeme, buf)
    local parts = {}
    for i = 1, #buf do
        parts[i] = string.char(buf[i])
    end
    x.value = table.concat(parts)
    if rc ~= Result.Success then
        p:error(p.cur_token.line, "invalid binary array. ")
    end
    return x
end

local function parse_argc_expr(p, _depth)
    return ast.ArgcExpr(p.cur_token.line)
end

local function parse_unary_op_expr(p, depth)
    local x = ast.UnaryOpExpr(p.cur_token.line)
    x.op = p.cur_token.type
    p:next_token()
    x.expr = p:parse_expr(P.Prefix, depth + 1)
    return p:optimize_in_place(x)
end

local function parse_paren_expr(p, depth)
    p:next_token()
    local x = p:parse_expr(P.Lowest, depth + 1)
    p:next_token()
    if p.cur_token.type ~= T.RParen then
        p:error(p.cur_token.line, 'expected ")". ')
    end
    return x -- 停在 )
end

local function parse_custom_opcode_expr(p, depth)
    local x = ast.CustomOpcodeExpr(p.cur_token.line)
    x.opcode_name = p.cur_token.parsed
    p:next_token() -- 到达 (
    if p.cur_token.type ~= T.LParen then
        p:error(p.cur_token.line, 'expected "(" after custom opcode. ')
        p:next_token()
        return x
    end
    p:next_token()
    if p.cur_token.type == T.RParen then
        -- 空参数表，cur 停在 )
    else
        x.args[#x.args + 1] = p:parse_expr(P.Lowest, depth + 1)
        while p.peek_token.type == T.Comma do
            p:next_token()
            p:next_token()
            x.args[#x.args + 1] = p:parse_expr(P.Lowest, depth + 1)
        end
        if p.peek_token.type ~= T.RParen then
            p:error(p.cur_token.line, 'expected ")". ')
        end
        p:next_token() -- 到达 )
    end
    return x
end

local function parse_args_expr(p, depth)
    local x = ast.ArgsExpr(p.cur_token.line)
    if p.peek_token.type ~= T.LBrack then
        -- 不推进（cur 停在 "args"）：把后续 token 留给下一条语句，避免吞掉
        p:error(p.peek_token.line, 'expected "[" after "args". ')
        return x
    end
    p:next_token() -- 到达 [
    p:next_token()
    x.key_expr = p:parse_expr(P.Lowest, depth + 1)
    p:next_token()
    if p.cur_token.type ~= T.RBrack then
        p:error(p.cur_token.line, 'expected "]". ')
    end
    return x
end

-- ================================ 中缀 ================================
local function parse_binary_op_expr(p, left_expr, depth)
    if left_expr == nil then return nil end
    local x = ast.BinaryOpExpr(left_expr.line)
    x.left_expr = left_expr
    x.op = p.cur_token.type
    local prec = p:cur_precedence()
    -- ^ 右结合：优先级 -1 让右侧继续吃同级的 ^
    if x.op == T.Pow then
        prec = prec - 1
    end
    p:next_token()
    x.right_expr = p:parse_expr(prec, depth + 1)
    return p:optimize_in_place(x)
end

local function parse_call_expr(p, callee, depth)
    if callee == nil then return nil end
    local x = ast.CallExpr(callee.line)
    x.callee = callee
    -- 外层已保证此处是 (
    if p.peek_token.type ~= T.RParen then
        p:next_token() -- 到达第一个表达式
        x.args[#x.args + 1] = p:parse_expr(P.Lowest, depth + 1)
        while p.peek_token.type == T.Comma do
            p:next_token() -- 到达 ","
            p:next_token() -- 到达下一个表达式
            x.args[#x.args + 1] = p:parse_expr(P.Lowest, depth + 1)
        end
    end
    if p.peek_token.type == T.RParen then
        p:next_token() -- 跳过 )
    else
        -- 缺 ")" 时不推进，避免吞掉后面的 token
        p:error(p.peek_token.line, 'expected ")". ')
    end
    return x
end

local function parse_at_expr(p, container, depth)
    if container == nil then return nil end
    local x = ast.AtExpr(container.line)
    x.container = container
    if p.peek_token.type ~= T.RBrack then
        p:next_token() -- 到达第一个表达式
        x.key_exprs[#x.key_exprs + 1] = p:parse_expr(P.Lowest, depth + 1)
        while p.peek_token.type == T.Comma do
            p:next_token() -- 到达 ","
            p:next_token() -- 到达下一个表达式
            x.key_exprs[#x.key_exprs + 1] = p:parse_expr(P.Lowest, depth + 1)
        end
    end
    if p.peek_token.type == T.RBrack then
        p:next_token() -- 跳过 ]
    else
        p:error(p.peek_token.line, 'expected "]". ')
    end
    return x
end

-- 分发表一次性填好（与 C++ 的 prefixParseFns / infixParseFns 逐项对应）
PREFIX_FNS = {
    [T.Ident] = parse_ident_expr,
    [T.Null] = parse_null_expr,
    [T.False_] = parse_bool_expr,
    [T.True_] = parse_bool_expr,
    [T.Integer] = parse_int_expr,
    [T.Float] = parse_float_expr,
    [T.String] = parse_string_expr,
    [T.BinArr] = parse_binarr_expr,
    [T.Argc] = parse_argc_expr,
    [T.Sub] = parse_unary_op_expr,
    [T.Not] = parse_unary_op_expr,
    [T.LParen] = parse_paren_expr,
    [T.Custom] = parse_custom_opcode_expr,
    [T.Args] = parse_args_expr,
}

INFIX_FNS = {}
for _, t in ipairs({ T.Or, T.And, T.EQ, T.NE, T.LT, T.LE, T.GT, T.GE,
                     T.Add, T.Sub, T.Mul, T.Div, T.IDiv, T.Mod, T.Pow }) do
    INFIX_FNS[t] = parse_binary_op_expr
end
INFIX_FNS[T.LParen] = parse_call_expr -- () 函数调用
INFIX_FNS[T.LBrack] = parse_at_expr   -- [] 取元素

Parser.PREFIX_FNS = PREFIX_FNS
Parser.INFIX_FNS = INFIX_FNS

return Parser
