-- scope_context.lua —— 编译器的作用域与变量分配。端口 python/stope/compiler.py 的
-- Scope / BlockScope / FileScope / WhileScope / MinHeap / VariableAllocator /
-- StackSizeManager。
--
-- 文件作用域判据：`is_file = true`；名字作用域判据：`id_map ~= nil`。

local scope_context = {}

function scope_context.BlockScope()
    return {
        type = "block",
        id_map = {},
        -- 名字 → 声明序号（Compiler.decl_counter 的全局值，跨 scope 可比）。
        -- defer 的「冻结名字绑定」靠它判定：序号 >= defer 语句处基线的本地名
        -- 对载荷不可见（不捕获，按隐式导出宿主变量处理；OQ-8，2026-11-08）。
        -- 隐式导出（从未声明的宿主变量）记 -1，豁免检查。
        id_order = {},
        -- defer 语句在本 scope 的登记：{ stmt = 载荷节点, line = defer 行号,
        -- order_baseline = 登记时的声明序号基线 }。退出点（块尾 / break /
        -- continue / return）由 Compiler 逆序拼接 —— 运行时没有 defer 栈，
        -- 顺序在编译期物化。
        defers = {},
        -- 该 scope 是否为 defer 载荷的隐式作用域：break / continue / return
        -- 不得跨越它（break/continue 的目标循环在载荷外 → 报错；return 在
        -- 载荷内一律报错）。
        is_defer_payload = false,
    }
end

function scope_context.FileScope()
    -- 与 BlockScope 同构（对照 C++：FileScope 继承 BlockScope），仅 type 不同。
    return {
        type = "file",
        id_map = {},
        id_order = {},
        defers = {},
        is_defer_payload = false,
        is_file = true,
    }
end

function scope_context.WhileScope()
    return { type = "while", start_index = 0, break_indices = {} }
end

-- 是名字作用域（BlockScope 与 FileScope 都算）？
function scope_context.is_block_scope(s)
    return s.id_map ~= nil
end

-- ==================== 最小堆：变量索引回收用，保证总是复用最小的空位 ====================

local MinHeap = {}
MinHeap.__index = MinHeap

function scope_context.MinHeap()
    return setmetatable({ data = {}, members = {} }, MinHeap)
end

function MinHeap:is_empty()
    return #self.data == 0
end

function MinHeap:push(v)
    local data = self.data
    data[#data + 1] = v
    self.members[v] = true
    -- 上浮
    local i = #data
    while i > 1 do
        local parent = i // 2
        if data[parent] <= data[i] then break end
        data[parent], data[i] = data[i], data[parent]
        i = parent
    end
end

function MinHeap:pop()
    local data = self.data
    local top = data[1]
    self.members[top] = nil
    local last = table.remove(data)
    if #data > 0 then
        data[1] = last
        -- 下沉
        local n = #data
        local i = 1
        while true do
            local l, r = i * 2, i * 2 + 1
            local m = i
            if l <= n and data[l] < data[m] then m = l end
            if r <= n and data[r] < data[m] then m = r end
            if m == i then break end
            data[m], data[i] = data[i], data[m]
            i = m
        end
    end
    return top
end

function MinHeap:has(v)
    return self.members[v] == true
end

-- ==================== 变量分配器 ====================

local VariableAllocator = {}
VariableAllocator.__index = VariableAllocator

function scope_context.VariableAllocator()
    return setmetatable({ vars = {}, recycled = scope_context.MinHeap() }, VariableAllocator)
end

function VariableAllocator:num()
    return #self.vars
end

function VariableAllocator:new_var(name)
    name = name or ""
    if not self.recycled:is_empty() then
        local idx = self.recycled:pop()
        self.vars[idx + 1] = name
        return idx
    end
    local i = #self.vars
    self.vars[#self.vars + 1] = name
    return i -- 0 起的槽位编号
end

--- 不参与回收 —— 给 export 与「未声明就使用的标识符」用。
function VariableAllocator:new_unique_var(name)
    local i = #self.vars
    self.vars[#self.vars + 1] = name
    return i
end

function VariableAllocator:free_var(idx)
    if self.recycled:has(idx) then
        return -- 同一索引不重复回收
    end
    self.recycled:push(idx)
end

-- ==================== 栈深记账 ====================

local StackSizeManager = {}
StackSizeManager.__index = StackSizeManager

function scope_context.StackSizeManager()
    return setmetatable({ size = 0, max_size = 0 }, StackSizeManager)
end

function StackSizeManager:inc(n)
    self.size = self.size + (n or 1)
    if self.size > self.max_size then
        self.max_size = self.size
    end
end

function StackSizeManager:dec(n)
    self.size = self.size - (n or 1)
end

--- 分支汇合：把 size 扳回到「从别处跳到这里」时应有的深度。
function StackSizeManager:converge(depth)
    self.size = depth
end

return scope_context
