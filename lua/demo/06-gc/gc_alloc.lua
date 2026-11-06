-- gc_alloc.lua：对象分配器（对应 cpp/demo/06-gc/ 的 ObjectAllocator）。
--
-- 引用计数的口径（与 C++ 版逐字对应，详见 cpp/docs/gc.md）：
--   * VM 对 Handle 的复制不通知宿主（Clear2/Copy 对 Handle 是无操作——缝的
--     设计），所以「栈/变量里此刻有哪些 Handle」只能靠扫描得知。
--   * ref_count = 字段引用（set_field 精确维护）+ 根引用（sync_roots 同步）。
--   * 安全点 = 每个 obj:* 开口入口 + collect 入口：扫描全部在册 State 的
--     variables/stack/returns，Handle 一律算根，diff 出增减。**先加后删**——
--     删除触发的级联发生在刚扫描完、根集合新鲜的瞬间，此时计数归零必然
--     意味着 VM 侧再无 Handle，「立即级联释放」才可靠。
-- Lua 差异：没有 String/BinArr 引用计数（引擎管）；「释放」= 摘链 + 判死
-- + 清字段，内存交给 Lua GC——没有 C++ 的 trash/flush_trash（对象不会地址
-- 复用，悬空指针不存在）；对象是平 table，gc 头字段直接长在表里。

local stope = require("stope")

local Handle = stope.Handle

local GcAllocator = {}
GcAnchor = GcAnchor or {} -- 哨兵的鸭子类型：与对象一样有 gc_prev / gc_next
GcAllocator.__index = GcAllocator

function GcAllocator.new()
    local self = setmetatable({}, GcAllocator)
    self.anchor = { gc_prev = nil, gc_next = nil } -- 哨兵：anchor.gc_next = 第一个对象
    self.anchor.gc_prev = self.anchor
    self.anchor.gc_next = self.anchor
    self.root_set = {}    -- 当前认定的根对象集合（对象 -> true）
    self.alive_count = 0  -- 链上真实对象数（触发器用）
    self.gc_trigger = 64  -- 存活数到阈值，分配前先 collect
    self.max_nodes = 0    -- gc 节点上限（Lua 侧只计业务对象，描述符由 GC 管）；
    -- 顶到上限先 collect 仍放不下则分配失败。0 = 不限
    self.collecting = false -- collect 重入守卫
    self.last_freed = 0     -- 上次 collect 释放数（诊断用）
    self.gather_roots = nil -- 安全点根扫描：宿主注册（枚举在册 State + pinned）
    self.on_free = nil      -- 回收前回调：跑 <delete>（析构）
    return self
end

-- 只有 Handle 且载荷是业务对象才算引用；描述符（table，有 member_id/cls_id
-- 字段）由 GC 管。判据：挂了 gc_next 字段的就是 gc 节点。
local function obj_of(v)
    if Handle.is(v) and type(v.data) == "table" and v.data.tag == "gcnode" then
        return v.data
    end
    return nil
end

-- 新对象挂到链尾。返回 nil = 顶到 max_nodes（开口里 s:error 报错）。
function GcAllocator:new_object()
    if not self.collecting and self.max_nodes ~= 0 and self.alive_count >= self.max_nodes then
        self:collect() -- 顶到上限：先回收再判断——gc 还有机会救
    end
    if self.max_nodes ~= 0 and self.alive_count >= self.max_nodes then
        return nil
    end
    local obj = { tag = "gcnode", class_id = -1, fields = {},
        gc_prev = nil, gc_next = nil, ref_count = 0, mark = 0, dead = false }
    obj.gc_next = self.anchor
    obj.gc_prev = self.anchor.gc_prev
    self.anchor.gc_prev.gc_next = obj
    self.anchor.gc_prev = obj
    self.alive_count = self.alive_count + 1
    return obj
end

-- ==================== 安全点：根同步 ====================

-- 先加后删的原因：删除可能级联释放。假设先删后加——根集合里过期的引用
-- 被摘除时，那个对象可能「恰好刚被本轮扫描发现在另一个 State 里」，先删
-- 会把它连同还活着的引用一起级联释放，后加就是把悬空指针登记成根。
function GcAllocator:sync_roots()
    if self.gather_roots == nil or self.collecting then
        return -- 收集期间跳过重扫：根集合保持 collect 入口时的新鲜度
    end
    local found = self.gather_roots()
    local found_set = {}
    for _, o in ipairs(found) do
        found_set[o] = true
    end

    -- 先加：本轮新发现的根 +1（同一对象在多个槽位出现只记一次根）。
    for _, o in ipairs(found) do
        if not o.dead and not self.root_set[o] then
            self.root_set[o] = true
            o.ref_count = o.ref_count + 1
        end
    end
    -- 后删：上一轮的根这轮没再出现 -> -1，归零立即级联。
    local stale = {}
    for o in pairs(self.root_set) do
        if not found_set[o] then
            stale[#stale + 1] = o
        end
    end
    for _, o in ipairs(stale) do
        self.root_set[o] = nil -- 无论死活都摘出根集合
        if not o.dead then
            o.ref_count = o.ref_count - 1
            if o.ref_count < 1 then
                self:free_now(o) -- 刚确认：VM 侧再无 Handle，立即级联释放
            end
        end
    end
end

-- ==================== 引用计数 ====================

function GcAllocator:add_ref(v)
    local o = obj_of(v)
    if o ~= nil and not o.dead then
        o.ref_count = o.ref_count + 1
    end
end

function GcAllocator:del_ref(v)
    local o = obj_of(v)
    if o == nil or o.dead then
        return
    end
    o.ref_count = o.ref_count - 1
    if o.ref_count < 1 then
        self:free_now(o) -- 归零立即级联释放
    end
end

-- 字段写入：旧引用先减（可能级联），再挂新引用。Lua 无 String 引用计数。
function GcAllocator:set_field(obj, index, v)
    self:del_ref(obj.fields[index])
    obj.fields[index] = v
    self:add_ref(v)
end

-- ==================== 释放（两条路径；Lua 无需延迟删除） ====================

-- 计数归零路径：字段里的 Handle 引用递减，归零的子对象**级联**释放。
function GcAllocator:free_now(obj)
    if obj.dead then
        return
    end
    if self.on_free ~= nil then
        self.on_free(obj) -- <delete> 先跑：字段还完整可读
    end
    for _, v in ipairs(obj.fields) do
        local child = obj_of(v)
        if child ~= nil and not child.dead then
            child.ref_count = child.ref_count - 1
            if child.ref_count < 1 then
                self:free_now(child) -- 级联
            end
        end
    end
    obj.fields = {}
    self:_unlink(obj)
end

-- sweep 路径：字段引用只减计数**不级联**——真死透的子对象马上就轮到。
function GcAllocator:free_sweep(obj)
    if obj.dead then
        return
    end
    if self.on_free ~= nil then
        self.on_free(obj)
    end
    for _, v in ipairs(obj.fields) do
        local child = obj_of(v)
        if child ~= nil and not child.dead and child.ref_count > 0 then
            child.ref_count = child.ref_count - 1
        end
    end
    obj.fields = {}
    self:_unlink(obj)
end

function GcAllocator:_unlink(obj)
    obj.gc_prev.gc_next = obj.gc_next
    obj.gc_next.gc_prev = obj.gc_prev
    obj.dead = true
    self.alive_count = self.alive_count - 1
end

-- ==================== gc：标记清除 ====================

-- 迭代式标记：沿字段里的 Handle 引用铺开，显式栈防深对象图爆 Lua 栈。
function GcAllocator:mark_from(root)
    if root.dead or root.mark ~= 0 then
        return
    end
    local work = { root }
    root.mark = 1
    while #work > 0 do
        local o = table.remove(work)
        for _, v in ipairs(o.fields) do
            local c = obj_of(v)
            if c ~= nil and not c.dead and c.mark == 0 then
                c.mark = 1
                work[#work + 1] = c
            end
        end
    end
end

function GcAllocator:collect()
    if self.collecting then
        return -- 析构里新建对象顶到阈值等重入：本次跳过，下个安全点再来
    end
    self:sync_roots() -- 收集前根集合先刷新到最新（此刻还没置位）

    self.collecting = true
    self.last_freed = 0

    -- 标记：从全部根出发。
    for root in pairs(self.root_set) do
        self:mark_from(root)
    end

    -- 清除：先收集死对象再逐个回收——on_free（析构）可能读写字段。
    local doomed = {}
    local h = self.anchor.gc_next
    while h ~= self.anchor do
        if h.mark == 0 then
            doomed[#doomed + 1] = h
        end
        h = h.gc_next
    end
    for _, o in ipairs(doomed) do
        if not o.dead then -- 前面的析构可能已经级联/重入收走了它
            self:free_sweep(o)
            self.last_freed = self.last_freed + 1
        end
    end

    -- 清标记：只走还活着的链。
    h = self.anchor.gc_next
    while h ~= self.anchor do
        h.mark = 0
        h = h.gc_next
    end

    self.collecting = false
    self.gc_trigger = math.max(64, self.alive_count * 2)
end

-- 退出兜底（C++ 的 ~ObjectAllocator）：逐个跑析构、判死——剩余对象（p）
-- 的「deleted: James」在这里打印；内存随后由 Lua GC 回收。
function GcAllocator:dispose_all()
    while self.anchor.gc_next ~= self.anchor do
        local mo = self.anchor.gc_next
        if self.on_free ~= nil then
            self.on_free(mo)
        end
        self:_unlink(mo)
    end
end

-- ==================== 诊断 ====================

function GcAllocator:report_alive()
    local objs = 0
    local h = self.anchor.gc_next
    while h ~= self.anchor do
        objs = objs + 1
        h = h.gc_next
    end
    print("[gc] alive: " .. objs .. " object(s), root set " .. self:root_count())
    h = self.anchor.gc_next
    while h ~= self.anchor do
        print("  " .. tostring(h) .. "  class " .. h.class_id
            .. "  refCount " .. h.ref_count)
        h = h.gc_next
    end
end

function GcAllocator:root_count()
    local n = 0
    for _ in pairs(self.root_set) do
        n = n + 1
    end
    return n
end

return GcAllocator
