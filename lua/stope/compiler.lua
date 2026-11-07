-- compiler.lua —— 把 AST 编译成 Program。端口 python/stope/compiler.py（C++ 为权威）。
--
-- 【指令流的形状】opcodes 是指令与操作数混排：PushInt/Float/String/BinArr/Value/Id
-- 常量池或变量表索引（0 起）；Call/At 参数个数；If/GoTo 跳转目标（0 起的 opcodes 下标）；
-- Return 返回值个数；自定义指令变长时多一个参数个数。
--
-- 【PushValue 与 PushId 的分工】PushId 压槽位引用（左值），只有「有赋值的 let」左侧与
-- Assign 左端是裸标识符两处产生；其余读变量一律 PushValue。
--
-- 【preExports】遍历 AST 之前按顺序登记（export 进 exports），空名 / 重名报
-- line 0 的错误；源码顶层 let/export 与名单撞名报 duplicate（块内 let 是遮蔽）。

local ast = require("stope.ast")
local common = require("stope.common")
local token_mod = require("stope.token")
local opcode_mod = require("stope.opcode")
local scope_context = require("stope.scope_context")

local Compiler = {}
local MT = { __index = Compiler }

local NT = ast.NodeType
local T = token_mod.TokenType
local Opcode = opcode_mod.Opcode
local Result = common.Result

function Compiler.new(custom)
    local self = setmetatable({}, MT)
    self.prog = nil
    self.custom_opcodes = custom -- 可空，只读
    self.errors = {}
    self.var_alloc = nil
    self.stack_size_mgr = nil
    self.scope_stack = {}
    self.cur_line = -1
    -- 全局声明序号：declare_local / declare_exported（非隐式）时递增。
    -- defer 的冻结名字绑定靠它判定「在 defer 之后才声明」。
    self.decl_counter = 0
    -- defer 载荷编译期状态：当前生效的声明序号基线（-1 = 不在拼接中）与
    -- 载荷编译期报错（duplicate export）的归责行号（defer 语句行）。
    self.defer_order_floor = -1
    self.defer_err_line = -1
    -- 刚访问完的语句是否终止控制流（return / break / continue / 真死循环）。
    -- 死代码消除：终止语句之后的语句不再发射，defer 也不再登记。
    self.stmt_terminates = false
    -- 最内层 while 体里是否出现过本层 break（死循环判定用；按 while 保存/恢复）
    self.saw_break = false
    return self
end

function Compiler:reset(custom)
    self.errors = {}
    self.custom_opcodes = custom
end

-- ---------------- 对外接口 ----------------

--- 编译 ast，结果直接写进 out。有错误返回 Result.Error 并把 out 复原为空。
function Compiler:compile(ast_tree, out, pre_exports)
    self:reset_compile(out)
    self:export_pre_exports(pre_exports or {})
    self:visit(ast_tree)
    -- 顶层 defer：程序尾结算。程序以终止语句（return / 死循环等）结尾时
    -- 这里不可达（return 出口已在 visit_return_stmt 结算过），再拼就是
    -- Return 之后的死代码——跳过；自然结束（fall-through）才需要这份结算。
    if not self.stmt_terminates then
        self:splice_defers(self:file_scope())
    end
    self:file_scope().defers = {} -- 最终结算
    if #self.errors > 0 then
        out:clear()
        return Result.Error
    end
    out.variable_num = self.var_alloc:num()
    out.required_stack_size = self.stack_size_mgr.max_size
    return Result.Success
end

function Compiler:export_pre_exports(names)
    local fs = self:file_scope()
    for _, n in ipairs(names) do
        -- 行号记 0：这些名字不来自源码，硬套 cur_line（此刻是 -1）只会误导
        if n == "" then
            self:error(0, "empty name in pre-exports. ")
        elseif fs.id_map[n] ~= nil then
            self:error(0, string.format('duplicate export of "%s". ', n))
        else
            self:declare_exported(n, self.var_alloc:new_unique_var(n))
        end
    end
end

function Compiler:reset_compile(out)
    self.errors = {}
    self.var_alloc = scope_context.VariableAllocator()
    self.stack_size_mgr = scope_context.StackSizeManager()
    self.scope_stack = {}
    self.decl_counter = 0
    self.defer_order_floor = -1
    self.defer_err_line = -1
    self.stmt_terminates = false
    self.saw_break = false
    self.cur_line = -1
    self.prog = out
    out:clear()
    self.scope_stack[#self.scope_stack + 1] = scope_context.FileScope()
end

-- ---------------- 指令输出 ----------------

function Compiler:code_size()
    return #self.prog.opcodes -- 0 起的「下一格」下标 == 1 起数组长度
end

function Compiler:emit_op(op)
    self.prog.opcodes[#self.prog.opcodes + 1] = op
end

--- 写一个操作数（索引 / 跳转目标）。超出 int16 要报错，否则回绕出来的跳转目标会把 VM 带飞。
function Compiler:emit_index(idx)
    if idx < -32768 or idx > 32767 then
        self:error(self.cur_line, "compile output too large: index exceeds int16. ")
        idx = 0
    end
    self.prog.opcodes[#self.prog.opcodes + 1] = idx
end

--- 占位：先写 -1，回填时才知道目标。返回 0 起的位置。
function Compiler:emit_placeholder()
    self.prog.opcodes[#self.prog.opcodes + 1] = -1
    return self:code_size() - 1
end

function Compiler:patch_index(pos, target)
    if target < -32768 or target > 32767 then
        self:error(self.cur_line, "compile output too large: jump target exceeds int16. ")
        target = 0
    end
    self.prog.opcodes[pos + 1] = target -- pos 0 起 -> 数组 1 起
end

--- 常量入池：相同的值只存一份，返回 0 起索引。
function Compiler:const_index(pool, v)
    for i = 1, #pool do
        local cur = pool[i]
        if type(cur) == type(v) and cur == v then
            return i - 1
        end
    end
    pool[#pool + 1] = v
    return #pool - 1
end

function Compiler:error(line, msg)
    self.errors[#self.errors + 1] = string.format("line %d: %s", line, msg)
end

-- ---------------- 遍历分发 ----------------

--- 与 ast_visitor 的 VISIT_MAP 等价：NodeType -> 方法名。
local VISIT_MAP = {
    [NT.Prog] = "visit_prog",
    [NT.ExprStmt] = "visit_expr_stmt",
    [NT.LetStmt] = "visit_let_stmt",
    [NT.ReturnStmt] = "visit_return_stmt",
    [NT.ExportStmt] = "visit_export_stmt",
    [NT.BlockStmt] = "visit_block_stmt",
    [NT.IfStmt] = "visit_if_stmt",
    [NT.WhileStmt] = "visit_while_stmt",
    [NT.AssignStmt] = "visit_assign_stmt",
    [NT.BreakStmt] = "visit_break_stmt",
    [NT.ContinueStmt] = "visit_continue_stmt",
    [NT.DeferStmt] = "visit_defer_stmt",
    [NT.NullExpr] = "visit_null_expr",
    [NT.BoolExpr] = "visit_bool_expr",
    [NT.IntExpr] = "visit_int_expr",
    [NT.FloatExpr] = "visit_float_expr",
    [NT.BinArrExpr] = "visit_binarr_expr",
    [NT.StringExpr] = "visit_string_expr",
    [NT.IdentExpr] = "visit_ident_expr",
    [NT.ArgcExpr] = "visit_argc_expr",
    [NT.ArgsExpr] = "visit_args_expr",
    [NT.UnaryOpExpr] = "visit_unary_op_expr",
    [NT.BinaryOpExpr] = "visit_binary_op_expr",
    [NT.CallExpr] = "visit_call_expr",
    [NT.AtExpr] = "visit_at_expr",
    [NT.CustomOpcodeExpr] = "visit_custom_opcode_expr",
}

function Compiler:visit(n)
    if n == nil then return end
    self.cur_line = n.line
    local name = VISIT_MAP[n.nt]
    if name ~= nil then
        self[name](self, n)
    end
    -- NT.Node / NT.Stmt / NT.Expr 三个裸基类没有表项：错误恢复路径上出现，直接跳过
end

-- ---------------- 作用域 ----------------

function Compiler:push_block_scope()
    local s = scope_context.BlockScope()
    self.scope_stack[#self.scope_stack + 1] = s
    return s
end

function Compiler:push_while_scope()
    local s = scope_context.WhileScope()
    self.scope_stack[#self.scope_stack + 1] = s
    return s
end

function Compiler:pop_scope()
    self.scope_stack[#self.scope_stack] = nil
end

--- 由内向外找最近的名字作用域（FileScope 也算）。
function Compiler:top_block_scope()
    for i = #self.scope_stack, 1, -1 do
        local s = self.scope_stack[i]
        if scope_context.is_block_scope(s) then return s end
    end
    return nil
end

function Compiler:find_ident_host(name)
    for i = #self.scope_stack, 1, -1 do
        local s = self.scope_stack[i]
        if scope_context.is_block_scope(s) and s.id_map[name] ~= nil then
            return s
        end
    end
    return nil
end

--- 冻结名字绑定下的宿主查找（仅在拼接 defer 载荷时使用）。
--- 最内层载荷根（栈中最靠内的 is_defer_payload 块）以内是载荷自己的内部
--- 作用域，名字解析不过滤；它以外才应用「defer 语句处可见」的基线 —— 跳过
--- 声明序号 >= floor 的本地名（那些在 defer 之后才声明，对载荷不可见）。
function Compiler:find_ident_host_frozen(name, floor)
    local payload_idx = -1
    for i = #self.scope_stack, 1, -1 do
        local s = self.scope_stack[i]
        if scope_context.is_block_scope(s) and s.is_defer_payload then
            payload_idx = i
            break
        end
    end
    for i = #self.scope_stack, 1, -1 do
        local s = self.scope_stack[i]
        if scope_context.is_block_scope(s) and s.id_map[name] ~= nil then
            if i < payload_idx then -- 登记 scope 一侧：跳过 defer 之后才声明的（遮蔽）
                local order = s.id_order[name]
                -- 基线 = 登记时的 declCounter（= 下一个待分配序号），所以
                -- 「order >= 基线」⟺ 在 defer 之后声明。
                if order ~= nil and order >= 0 and order >= floor then
                    -- continue（跳过这个名字宿主）
                else
                    return s
                end
            else
                return s
            end
        end
    end
    return nil
end

--- 拼接期间的名字解析（冻结绑定）。冻结查找命中 → 用冻结规则（名字→槽位
--- 按 defer 语句位置定）。未命中 → 不再查 now、不再报 declared after
--- （OQ-8，2026-11-08 定夺：后文声明的本地名不被捕获，按隐式导出宿主变量
--- 处理，同未声明名字的路径）。FileScope 已有同名（后文顶层 let / export
--- 声明的文件级变量）时无法再建同名宿主变量，报重复——行号归 defer 语句
--- （冲突在 defer 绑定符号时就已注定；若 defer 先于顶层声明结算，则由后文
--- declare_local 报 duplicate declaration，两处报错互斥）。返回 FileScope：
--- 编译已失败，避免连锁隐式导出。都空 → 返回 nil，调用方走隐式导出路径
--- （新建宿主变量）。与 cpp/src/compiler.cpp 的 resolveAtSplice 一致。
function Compiler:resolve_at_splice(name)
    local frozen = self:find_ident_host_frozen(name, self.defer_order_floor)
    if frozen ~= nil then
        return frozen
    end
    local fs = self:file_scope()
    if fs.id_map[name] ~= nil then
        self:error(self.defer_err_line,
            string.format('duplicate export of "%s". ', name))
        return fs
    end
    return nil
end

--- 退出点结算：逆序拼接 bs 登记的 defer 载荷（LIFO，后登记先执行）。
--- ⚠ 不清空 bs.defers：一个块可以有多个运行期出口（break / continue /
--- return 各一处 + 块尾），每个出口都要拼一份自己的副本；只有块尾 / 程序尾
--- 的「最终结算」由调用方在拼接后清空。某个载荷编译出错即停（错误去重：
--- 载荷在每个退出点重编译，报一次就够）。
function Compiler:splice_defers(bs)
    if #bs.defers == 0 or #self.errors > 0 then
        return
    end
    for k = #bs.defers, 1, -1 do
        if #self.errors > 0 then
            return
        end
        local d = bs.defers[k]
        local saved_floor = self.defer_order_floor
        local saved_line = self.defer_err_line
        self.defer_order_floor = d.order_baseline
        self.defer_err_line = d.line
        -- 载荷包一层隐式作用域并打标记：break/continue/return 的越界检查
        -- 靠它识别「从收尾代码里跳回主流程」。
        local ps = self:push_block_scope()
        ps.is_defer_payload = true
        self:visit(d.stmt)
        -- 载荷 scope 自己的 defers（直接嵌套 defer defer X 落在这里）：
        -- 触发点 = 载荷 scope 结束 = 同一退出点，就地拼接。
        self:splice_defers(ps)
        self:pop_scope()
        for _, idx in pairs(ps.id_map) do
            self.var_alloc:free_var(idx)
        end
        self.defer_order_floor = saved_floor
        self.defer_err_line = saved_line
    end
end

function Compiler:file_scope()
    return self.scope_stack[1]
end

-- ---------------- 语句 ----------------

function Compiler:visit_prog(p)
    -- 语句序列：终止语句（return / break / continue / 死循环）之后的语句
    -- 在语言语义下执行不到——不再发射，也不登记它们的 defer（死代码消除）。
    -- 序列的终止性 = 最后一条已发射语句。
    local terminated = false
    for _, s in ipairs(p.stmts) do
        if terminated then
            break
        end
        self.stmt_terminates = false -- 每条语句先清零；终止语句的 visitor 置 true
        self:visit(s)
        terminated = self.stmt_terminates
    end
    self.stmt_terminates = terminated
end

function Compiler:visit_expr_stmt(s)
    self:visit(s.expr)
    self:emit_op(Opcode.Pop)
    self.stack_size_mgr:dec()
end

function Compiler:visit_let_stmt(s)
    local bs = self:top_block_scope()
    if bs == nil then return end
    if s.has_assign then
        -- let a = expr; —— 只有一个标识符
        if #s.idents == 0 then return end
        local name = s.idents[1]
        if bs.id_map[name] ~= nil then
            self:error(s.line, string.format("duplicate declaration of '%s'. ", name))
            return
        end
        -- 不要 visit 标识符本身，这里要绑定到新变量
        local idx = self.var_alloc:new_var()
        self:declare_local(bs, name, idx)
        self:emit_op(Opcode.PushId)
        self:emit_index(idx)
        self.stack_size_mgr:inc()
        self:visit(s.expr)
        self:emit_op(Opcode.Assign)
        self.stack_size_mgr:dec(2)
    else
        for _, nm in ipairs(s.idents) do
            if bs.id_map[nm] ~= nil then
                self:error(s.line, string.format("duplicate declaration of '%s'. ", nm))
            else
                self:declare_local(bs, nm, self.var_alloc:new_var())
            end
        end
    end
end

function Compiler:visit_return_stmt(s)
    -- defer 边界：return 的终点是整个程序，在载荷内必然越界，一律报错。
    for _, sc in ipairs(self.scope_stack) do
        if scope_context.is_block_scope(sc) and sc.is_defer_payload then
            self:error(s.line, '"return" cannot be used in a defer statement. ')
            return
        end
    end
    -- 顺序：先结算，再求返回值，最后 Return（结算 → PushValue → Return）。
    -- 结算先于退出动作，与块退出一致——defer 可以影响返回值。
    for i = #self.scope_stack, 1, -1 do
        local sc = self.scope_stack[i]
        if scope_context.is_block_scope(sc) then
            self:splice_defers(sc)
        end
    end
    for _, e in ipairs(s.exprs) do
        self:visit(e)
    end
    self:emit_op(Opcode.Return)
    self:emit_index(#s.exprs)
    if #s.exprs > self.prog.max_return_num then
        self.prog.max_return_num = #s.exprs
    end
    self.stmt_terminates = true
    -- Return 会让 VM 直接跳到 code 末尾，栈上的返回值不回收
end

function Compiler:visit_export_stmt(s)
    if #self.scope_stack > 1 then
        self:error(s.line, '"export" can only be used at top scope. ')
    end
    local fs = self:file_scope()
    for _, name in ipairs(s.idents) do
        if fs.id_map[name] ~= nil then
            self:error(s.line, string.format('duplicate export of "%s". ', name))
        else
            self:declare_exported(name, self.var_alloc:new_unique_var(name))
        end
    end
end

function Compiler:visit_block_stmt(s)
    local bs = self:push_block_scope()
    self:visit(s.prog)
    -- 块尾结算：本 scope 的 defer 在这里执行（LIFO）。块体以终止语句结尾时
    -- 这里不可达（return 出口已结算、break/continue 出口就地结算过）——
    -- 跳过，避免拼出不可达的副本。
    if not self.stmt_terminates then
        self:splice_defers(bs)
    end
    bs.defers = {} -- 最终结算：途中出口（break/return）已各拼过副本
    self:pop_scope()
    for _, idx in pairs(bs.id_map) do
        self.var_alloc:free_var(idx) -- 回收局部变量索引
    end
end

function Compiler:visit_if_stmt(s)
    if s.cond == nil then return end
    local goto_end_indices = {}
    local all_branches_terminate = true
    self:visit(s.cond)
    self:emit_op(Opcode.If)
    self.stack_size_mgr:dec()
    local last_if_pos = self:emit_placeholder() -- 条件为假时跳到这里
    self:visit_body_as_block(s.first_prog)
    local branch_term = self.stmt_terminates
    all_branches_terminate = all_branches_terminate and branch_term
    if not branch_term then -- 分支走完会落到这里，需要跳出整个 if；终止则死代码
        self:emit_op(Opcode.GoTo)
        goto_end_indices[#goto_end_indices + 1] = self:emit_placeholder()
    end
    self:patch_index(last_if_pos, self:code_size())
    for _, ei in ipairs(s.elifs) do
        if ei.cond ~= nil then
            self:visit(ei.cond)
            self:emit_op(Opcode.If)
            self.stack_size_mgr:dec()
            last_if_pos = self:emit_placeholder()
            self:visit_body_as_block(ei.prog)
            branch_term = self.stmt_terminates
            all_branches_terminate = all_branches_terminate and branch_term
            if not branch_term then
                self:emit_op(Opcode.GoTo)
                goto_end_indices[#goto_end_indices + 1] = self:emit_placeholder()
            end
            self:patch_index(last_if_pos, self:code_size())
        end
    end
    local has_else = s.else_prog ~= nil
    if has_else then
        self:visit_body_as_block(s.else_prog)
    else
        all_branches_terminate = false -- 无 else：条件全假时落到 if 之后
    end
    for _, pos in ipairs(goto_end_indices) do
        self:patch_index(pos, self:code_size())
    end
    -- if 语句的终止性：else 存在且所有分支终止（组合式，逐分支局部判断）
    self.stmt_terminates = has_else and all_branches_terminate
end

function Compiler:visit_while_stmt(s)
    local ws = self:push_while_scope()
    ws.start_index = self:code_size() -- continue 回到这里
    local case_goto_end_pos = -1
    if s.cond ~= nil then
        -- while cond { } —— cond 可省
        self:visit(s.cond)
        self:emit_op(Opcode.If)
        self.stack_size_mgr:dec()
        case_goto_end_pos = self:emit_placeholder()
    end
    -- saw_break 按 while 配对保存/恢复：嵌套循环里的 break 只算最内层的
    local saved_saw_break = self.saw_break
    self.saw_break = false
    self:visit_body_as_block(s.prog)
    local body_term = self.stmt_terminates
    local body_saw_break = self.saw_break
    self.saw_break = saved_saw_break
    if not body_term then -- 体终止（return/break/continue 收尾）则回跳是死代码
        self:emit_op(Opcode.GoTo)
        self:emit_index(ws.start_index)
    end
    for _, pos in ipairs(ws.break_indices) do
        self:patch_index(pos, self:code_size())
    end
    -- 条件可省。无条件时必须跳过回填，否则会把第 0 条指令改成跳转目标
    if case_goto_end_pos >= 0 then
        self:patch_index(case_goto_end_pos, self:code_size())
    end
    -- while 的终止性：只有「无条件 + 体不含本层 break」的真死循环才永不
    -- 退出。`while true { }` 带条件，按可退出处理（用户明确要求），不视同
    -- `while { }`，不做字面量折叠。
    self.stmt_terminates = (s.cond == nil) and not body_saw_break
    self:pop_scope()
end

function Compiler:visit_assign_stmt(s)
    if s.left_expr.nt == NT.IdentExpr then
        -- 赋值左端的裸标识符要压【槽位】而不是值，否则 Assign 无处可存
        local idx = self:ident_slot(s.left_expr.ident)
        self:emit_op(Opcode.PushId)
        self:emit_index(idx)
        self.stack_size_mgr:inc()
    else
        -- 可能是使用者设计的数组元素引用、对象成员引用等。压入值。
        self:visit(s.left_expr)
    end
    self:visit(s.right_expr)
    self:emit_op(Opcode.Assign)
    self.stack_size_mgr:dec(2)
end

function Compiler:visit_break_stmt(s)
    -- 找最内层 WhileScope。途中先撞到 defer 载荷边界 = 目标循环在载荷外：
    -- 载荷在退出点才执行，break 从收尾代码里跳回主流程是灾难语义，禁。
    local wi = -1 -- 1 起的栈下标
    for i = #self.scope_stack, 1, -1 do
        local sc = self.scope_stack[i]
        if sc.type == "while" then
            wi = i
            break
        end
        if scope_context.is_block_scope(sc) and sc.is_defer_payload then
            self:error(s.line, '"break" cannot cross a defer statement. ')
            return
        end
    end
    if wi < 0 then
        self:error(s.line, 'cannot use "break" outside of a loop. ')
        return
    end
    -- 结算 break 越过的所有块：从最内层到循环体块（不含 WhileScope 本身、
    -- 不含循环外的任何 scope）。运行时 break 直接跳循环尾，这些块的正常
    -- 块尾拼接不会执行到，必须在跳转前就地结算。
    for i = #self.scope_stack, wi + 1, -1 do
        if scope_context.is_block_scope(self.scope_stack[i]) then
            self:splice_defers(self.scope_stack[i])
        end
    end
    self:emit_op(Opcode.GoTo)
    local ws = self.scope_stack[wi]
    ws.break_indices[#ws.break_indices + 1] = self:emit_placeholder()
    self.saw_break = true -- 告知最内层 while：本层有 break（死循环判定用）
    self.stmt_terminates = true
end

function Compiler:visit_continue_stmt(s)
    -- 同 break：continue 也退出循环体块，体块的 defer 必须先结算。
    local wi = -1 -- 1 起的栈下标
    for i = #self.scope_stack, 1, -1 do
        local sc = self.scope_stack[i]
        if sc.type == "while" then
            wi = i
            break
        end
        if scope_context.is_block_scope(sc) and sc.is_defer_payload then
            self:error(s.line, '"continue" cannot cross a defer statement. ')
            return
        end
    end
    if wi < 0 then
        self:error(s.line, 'cannot use "continue" outside of a loop. ')
        return
    end
    for i = #self.scope_stack, wi + 1, -1 do
        if scope_context.is_block_scope(self.scope_stack[i]) then
            self:splice_defers(self.scope_stack[i])
        end
    end
    self:emit_op(Opcode.GoTo)
    self:emit_index(self.scope_stack[wi].start_index)
    self.stmt_terminates = true
end

function Compiler:visit_defer_stmt(s)
    local bs = self:top_block_scope()
    if bs == nil then
        return -- 不可能：FileScope 常驻栈底
    end
    -- 纯编译期登记，defer 语句位置零指令。载荷在退出点才编译（每个退出点
    -- 各编译一次——If/GoTo 操作数是绝对下标，编译一次再拷贝会破坏跳转目标）。
    bs.defers[#bs.defers + 1] =
        { stmt = s.stmt, line = s.line, order_baseline = self.decl_counter }
end

-- ---------------- 表达式 ----------------

function Compiler:visit_null_expr(_n)
    self:emit_op(Opcode.PushNull)
    self.stack_size_mgr:inc()
end

function Compiler:visit_bool_expr(x)
    self:emit_op(x.value and Opcode.PushTrue or Opcode.PushFalse)
    self.stack_size_mgr:inc()
end

function Compiler:visit_int_expr(x)
    self:emit_op(Opcode.PushInt)
    self:emit_index(self:const_index(self.prog.int_consts, x.value))
    self.stack_size_mgr:inc()
end

function Compiler:visit_float_expr(x)
    self:emit_op(Opcode.PushFloat)
    self:emit_index(self:const_index(self.prog.float_consts, x.value))
    self.stack_size_mgr:inc()
end

function Compiler:visit_string_expr(x)
    self:emit_op(Opcode.PushString)
    self:emit_index(self:const_index(self.prog.string_consts, x.value))
    self.stack_size_mgr:inc()
end

function Compiler:visit_binarr_expr(x)
    self:emit_op(Opcode.PushBinArr)
    self:emit_index(self:const_index(self.prog.binarr_consts, x.value))
    self.stack_size_mgr:inc()
end

function Compiler:visit_ident_expr(x)
    local idx = self:ident_slot(x.ident)
    self:emit_op(Opcode.PushValue) -- 压的是变量的【值】；要槽位请用 PushId
    self:emit_index(idx)
    self.stack_size_mgr:inc()
end

function Compiler:visit_argc_expr(_n)
    self:emit_op(Opcode.ArgNum)
    self.stack_size_mgr:inc()
end

function Compiler:visit_args_expr(x)
    self:visit(x.key_expr)
    self:emit_op(Opcode.GetArg) -- 弹下标、压结果，栈大小不变
end

function Compiler:visit_unary_op_expr(x)
    self:visit(x.expr)
    if x.op == T.Not then
        self:emit_op(Opcode.Not)
    elseif x.op == T.Sub then
        self:emit_op(Opcode.Minus)
    end
    -- 一元指令：弹 1 压 1，栈大小不变
end

function Compiler:visit_binary_op_expr(x)
    if x.op == T.Or then
        self:visit_or_expr(x)
        return
    elseif x.op == T.And then
        self:visit_and_expr(x)
        return
    end
    self:visit(x.left_expr)
    self:visit(x.right_expr)
    self:emit_op(binary_opcode(x.op))
    self.stack_size_mgr:dec() -- 弹 2 压 1
end

function Compiler:visit_or_expr(x)
    -- 短路或：任一侧为真就 PushTrue，两条路径都在栈上留下恰好 1 个结果
    self:visit(x.left_expr)
    self:emit_op(Opcode.If)
    self.stack_size_mgr:dec()
    local first_if_pos = self:emit_placeholder()
    local depth_at_if_target = self.stack_size_mgr.size -- If 已弹掉条件 = 汇合点深度
    self:emit_op(Opcode.PushTrue)
    self.stack_size_mgr:inc()
    self:emit_op(Opcode.GoTo)
    local goto_end1 = self:emit_placeholder()
    self:patch_index(first_if_pos, self:code_size())
    self.stack_size_mgr:converge(depth_at_if_target)

    self:visit(x.right_expr)
    self:emit_op(Opcode.If)
    self.stack_size_mgr:dec()
    local second_if_pos = self:emit_placeholder()
    depth_at_if_target = self.stack_size_mgr.size
    self:emit_op(Opcode.PushTrue)
    self.stack_size_mgr:inc()
    self:emit_op(Opcode.GoTo)
    local goto_end2 = self:emit_placeholder()
    self:patch_index(second_if_pos, self:code_size())
    self.stack_size_mgr:converge(depth_at_if_target)

    self:emit_op(Opcode.PushFalse) -- 两侧都不成立
    self.stack_size_mgr:inc()
    self:patch_index(goto_end1, self:code_size())
    self:patch_index(goto_end2, self:code_size())
end

function Compiler:visit_and_expr(x)
    self:visit(x.left_expr)
    self:emit_op(Opcode.If)
    self.stack_size_mgr:dec()
    local first_if_pos = self:emit_placeholder()
    self:visit(x.right_expr)
    self:emit_op(Opcode.If)
    self.stack_size_mgr:dec()
    local second_if_pos = self:emit_placeholder()
    local depth_at_if_target = self.stack_size_mgr.size -- 两侧都为真才落到这里
    self:emit_op(Opcode.PushTrue)
    self.stack_size_mgr:inc()
    self:emit_op(Opcode.GoTo)
    local goto_end = self:emit_placeholder()
    self:patch_index(first_if_pos, self:code_size())
    self:patch_index(second_if_pos, self:code_size())
    self.stack_size_mgr:converge(depth_at_if_target)
    self:emit_op(Opcode.PushFalse)
    self.stack_size_mgr:inc()
    self:patch_index(goto_end, self:code_size())
end

function Compiler:visit_call_expr(x)
    self:visit(x.callee)
    for _, a in ipairs(x.args) do
        self:visit(a)
    end
    self:emit_op(Opcode.Call)
    self:emit_index(#x.args)
    self.stack_size_mgr:dec(#x.args) -- callee + args 换成 1 个返回值
end

function Compiler:visit_at_expr(x)
    self:visit(x.container)
    for _, k in ipairs(x.key_exprs) do
        self:visit(k)
    end
    self:emit_op(Opcode.At)
    self:emit_index(#x.key_exprs)
    self.stack_size_mgr:dec(#x.key_exprs)
end

function Compiler:visit_custom_opcode_expr(x)
    if self.custom_opcodes == nil or self.custom_opcodes.opcodes[x.opcode_name] == nil then
        self:error(x.line, string.format('undefined custom opcode "%s". ', x.opcode_name))
        return
    end
    local info = self.custom_opcodes.opcodes[x.opcode_name]
    local is_var_arg = info.arg_num < 0 -- 与 C++ 的 isVarArg 同一判据
    if not is_var_arg and info.arg_num ~= #x.args then
        self:error(x.line, string.format(
            'custom opcode "%s" expected %d args, but got %d. ',
            x.opcode_name, info.arg_num, #x.args))
    end
    for _, a in ipairs(x.args) do
        self:visit(a)
    end
    self:emit_op(info.opcode)
    if is_var_arg then
        self:emit_index(#x.args)
    end
    -- 自定义指令没有 callee 入栈，结果仍占 1 格 => dec(参数个数 - 1)
    self.stack_size_mgr:dec(#x.args - 1)
end

-- ---------------- 小工具 ----------------

--- 标识符 -> 变量槽位索引。没声明过就当作外部变量，登记到文件作用域。
--- PushValue / PushId 共用这一处查找；拼接 defer 载荷时走冻结名字绑定
--- （resolve_at_splice）。
function Compiler:ident_slot(name)
    local host
    if self.defer_order_floor >= 0 then
        host = self:resolve_at_splice(name)
    else
        host = self:find_ident_host(name)
    end
    if host ~= nil then
        return host.id_map[name]
    end
    self:declare_exported(name, self.var_alloc:new_unique_var(name), true)
    return self:file_scope().id_map[name]
end

--- 登记一个会进 Program.exports 的变量。索引来自 new_unique_var（不回收）。
--- 隐式导出（从未声明的宿主变量）记序号 -1：豁免 defer 冻结绑定检查——
--- 它不是本地槽位，是宿主变量。
function Compiler:declare_exported(name, idx, implicit_export)
    local fs = self:file_scope()
    fs.id_map[name] = idx
    if implicit_export then
        fs.id_order[name] = -1
    else
        fs.id_order[name] = self.decl_counter
        self.decl_counter = self.decl_counter + 1
    end
    self.prog.exports[name] = idx
end

--- 登记一个局部变量：id_map 之外还要记声明序号（冻结名字绑定用）。
function Compiler:declare_local(bs, name, idx)
    bs.id_map[name] = idx
    bs.id_order[name] = self.decl_counter
    self.decl_counter = self.decl_counter + 1
end

function Compiler:visit_body_as_block(p)
    -- 块 / if 分支 / 循环体在 AST 里都是裸 Prog（没有 BlockStmt 包着），
    -- 这里补一层 BlockScope，让内部 let 的变量在离开时被回收
    local bs = self:push_block_scope()
    self:visit(p)
    -- 块尾结算（if 分支 / 循环体同普通块）。体以终止语句结尾时这里不可达，
    -- 跳过——出口结算（return / break / continue）已就地拼过副本。
    if not self.stmt_terminates then
        self:splice_defers(bs)
    end
    bs.defers = {} -- 最终结算
    self:pop_scope()
    for _, idx in pairs(bs.id_map) do
        self.var_alloc:free_var(idx)
    end
end

--- 二元运算符 -> 指令。注意二元 - 是 Sub 而不是 Minus。
function binary_opcode(op)
    if op == T.EQ then return Opcode.EQ end
    if op == T.NE then return Opcode.NE end
    if op == T.LT then return Opcode.LT end
    if op == T.LE then return Opcode.LE end
    if op == T.GT then return Opcode.GT end
    if op == T.GE then return Opcode.GE end
    if op == T.Add then return Opcode.Add end
    if op == T.Sub then return Opcode.Sub end
    if op == T.Mul then return Opcode.Mul end
    if op == T.Div then return Opcode.Div end
    if op == T.IDiv then return Opcode.IDiv end
    if op == T.Mod then return Opcode.Mod end
    if op == T.Pow then return Opcode.Pow end
    return Opcode.Pop -- 到不了：parser 只会用上面这些 op 构造 BinaryOpExpr
end

return Compiler
