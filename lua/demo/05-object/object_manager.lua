-- object_manager.lua：obj:* 域的全部行为（对应 cpp/demo/05-object/ 的
-- ObjectManager.*）。

local stope = require("stope")

local Handle = stope.Handle
local PROP, METHOD, DELETE = 0, 1, 2 -- MemberKind

local ObjectManager = {}
ObjectManager.__index = ObjectManager

function ObjectManager.new(runtime)
    local self = setmetatable({}, ObjectManager)
    self.runtime = runtime
    self.live = {}       -- 对象数组；delete 后移除
    self.max_objects = 0 -- 存活对象上限（live 表大小）；0 = 不限（对齐 maxDepth 约定）
    -- 去重缓存：对象 -> { [成员 id] = 绑定描述符 }。绑定描述符只存这两样且
    -- 创建后不可变，同一绑定永远等价；delete 时整组驱逐，不可达的描述符交给 GC。
    self.bind_cache = {}
    return self
end

function ObjectManager:new_object(cls_id)
    local obj = { class_id = cls_id, fields = {}, deleted = false }
    for _ in ipairs(self.runtime.classes[cls_id + 1].properties) do
        obj.fields[#obj.fields + 1] = stope.NULL
    end
    self.live[#self.live + 1] = obj
    return Handle.new(obj)
end

function ObjectManager:new_member_desc(member_id)
    return Handle.new({ member_id = member_id, obj = nil }) -- MemberDesc
end

function ObjectManager:new_ctor_desc(cls_id, ctor_idx)
    return Handle.new({ cls_id = cls_id, ctor_idx = ctor_idx }) -- CtorDesc
end

-- 绑定（创建即去重）。C++ 版还有 freeDescs 复用池；这里不需要 —— 驱逐后
-- 不可达的描述符由 GC 回收，池的存在意义被语言机制替掉了。
function ObjectManager:bind(member_id, obj_handle)
    local obj = obj_handle.data
    local by_member = self.bind_cache[obj]
    if by_member == nil then
        by_member = {}
        self.bind_cache[obj] = by_member
    end
    local hit = by_member[member_id]
    if hit ~= nil then
        return Handle.new(hit) -- 命中：复用
    end
    local d = { member_id = member_id, obj = obj_handle }
    by_member[member_id] = d
    return Handle.new(d)
end

-- obj:<名>[p] -> 绑定描述符（属性引用与绑定方法都从这里出发）。
function ObjectManager:at(s, handle, key)
    local d = handle.data
    if d.cls_id ~= nil then
        s:error("no implement for container type. ") -- 构造描述符不可 At
        return nil
    end
    if not Handle.is(key) then
        s:error("not an object. ")
        return nil
    end
    return self:bind(d.member_id, key)
end

-- obj:<属性>[p] = v -> 写字段。两层整数查询：对象自己的 class_id 选类，
-- member_by_id 查 MemberRef——同名成员在各类里落在不同位置也各归各。
function ObjectManager:assign(s, handle, value)
    local d = handle.data
    if d.cls_id ~= nil or d.obj == nil then
        s:error("not assignable. ")
        return
    end
    local obj = d.obj.data
    if obj.deleted then
        s:error("use after free. ") -- Lua 无悬空指针：删除标记替代 UB
        return
    end
    local cls = self.runtime.classes[obj.class_id + 1] -- 第一层
    local ref = cls.member_by_id[d.member_id]
    if ref == nil or ref.kind ~= PROP then
        s:error("not assignable. ") -- 该类没有这个成员 / 方法不可赋值
        return
    end
    obj.fields[ref.index + 1] = value -- 第二层：MemberRef.index 即字段下标
end

-- obj:<名>[p](...) -> 调方法；obj:<名>(...) 直接调（delete 走这里，对象在
-- 实参里）；<Class>:<New>(...) -> 构造。
function ObjectManager:call_member(s, handle, args)
    local d = handle.data
    if d.cls_id ~= nil then
        -- CtorDesc：构造
        if self.max_objects ~= 0 and #self.live >= self.max_objects then
            s:error("too many objects. ") -- 手动管理：上限内也不自动回收，必须 obj:delete
            return nil
        end
        local cls = self.runtime.classes[d.cls_id + 1]
        local obj_handle = self:new_object(d.cls_id)
        -- 构造器压帧：返回值是新对象本身（不走「弹帧回填」通道）。
        self.runtime:push_method_frame(cls.methods[d.ctor_idx + 1], obj_handle.data, args, false)
        return obj_handle
    end
    -- MemberDesc：kind 由 member_by_id 查表揭晓；类来自绑定对象或实参对象。
    local obj_handle = d.obj
    if obj_handle == nil then
        if #args > 0 and Handle.is(args[1]) then
            obj_handle = args[1] -- obj:delete(p) 实参形式
        else
            if #args > 0 then
                s:error("not an object. ") -- obj:<名>(实参)，但实参不是对象
            else
                s:error("method not bound. ") -- obj:<方法> 未带 [对象]
            end
            return nil
        end
    end
    local obj = obj_handle.data
    if obj.deleted then
        s:error("use after free. ")
        return nil
    end
    local cls = self.runtime.classes[obj.class_id + 1] -- 第一层
    local ref = cls.member_by_id[d.member_id]
    if ref == nil then
        s:error("no method. ") -- 该类没有这个成员
        return nil
    end
    if ref.kind == DELETE then
        self:delete(s, obj) -- 绑定形式与实参形式在此收敛
        return nil
    end
    if ref.kind ~= METHOD then
        s:error('"Call" can only call a function. ') -- 属性不可调
        return nil
    end
    -- 方法调用压帧：返回占位 NULL——op_call 把它压到调用方栈顶，方法帧弹栈
    -- 时（finish_top_frame）再回填真正的返回值。⚠ 必须是 stope.NULL 而不是
    -- Lua nil：`stack[#stack] = nil` 是删条目（栈会缩短），不是占位。
    self.runtime:push_method_frame(cls.methods[ref.index + 1], obj, args, true)
    return stope.NULL
end

-- 跑 <delete>（可读写字段）-> 驱逐绑定描述符 -> 删除标记。双重 delete 拦下。
function ObjectManager:delete(s, obj)
    local idx = nil
    for i, o in ipairs(self.live) do
        if o == obj then
            idx = i
            break
        end
    end
    if idx == nil then
        s:error("double delete. ")
        return
    end
    table.remove(self.live, idx)
    local cls = self.runtime.classes[obj.class_id + 1]
    if cls.deconstructor_id >= 0 then
        self.runtime:invoke_method(cls.methods[cls.deconstructor_id + 1], obj, {})
    end
    self.bind_cache[obj] = nil -- 整组驱逐；不可达的描述符由 GC 回收
    obj.deleted = true -- 内存回收时机交给 GC；之后使用即 use after free
end

function ObjectManager:report_live()
    if #self.live == 0 then
        print("[objects] all freed")
    else
        local parts = {}
        for _, o in ipairs(self.live) do
            parts[#parts + 1] = "(class " .. o.class_id .. ")"
        end
        print("[objects] " .. #self.live .. " alive: " .. table.concat(parts, " "))
    end
    local cached = 0
    for _, by_member in pairs(self.bind_cache) do
        for _ in pairs(by_member) do
            cached = cached + 1
        end
    end
    -- 差异：C++ 打 allocated/pooled 两个数（复用池）；这里只有缓存里仍被
    -- 引用的绑定描述符，池被 GC 替代了。
    print("[bind-cache] " .. cached .. " entries")
end

return ObjectManager
