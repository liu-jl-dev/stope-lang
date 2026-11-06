-- object_manager.lua：obj:* 域的全部行为（对应 cpp/demo/06-gc/ 的
-- ObjectManager.*）。
--
-- 与 demo 5 的差异：没有 bind_cache / live 表 / obj:delete——描述符每次
-- bind 新建（GC 回收不可达者），对象生命期归 gc 分配器。
-- 三个开口入口先 safe_point()：安全点根同步，先于一切 del_ref。

local stope = require("stope")

local Handle = stope.Handle
local PROP, METHOD = 0, 1 -- MemberKind（对应 C++ 的 kMemberProp / kMemberMethod）

local GcAllocator = require("gc_alloc")

local ObjectManager = {}
ObjectManager.__index = ObjectManager

function ObjectManager.new(runtime)
    local self = setmetatable({}, ObjectManager)
    self.runtime = runtime
    self.alloc = GcAllocator.new() -- gc 分配器（C++ 版住在 ObjectManager 里）
    return self
end

-- new 业务对象。返回 nil = 顶到 max_nodes（调用方 s:error 报错）。
function ObjectManager:new_object(cls_id)
    local obj = self.alloc:new_object()
    if obj == nil then
        return nil
    end
    obj.class_id = cls_id
    for _ in ipairs(self.runtime.classes[cls_id + 1].properties) do
        obj.fields[#obj.fields + 1] = stope.NULL
    end
    return Handle.new(obj)
end

-- 描述符：每次新建，不去重——demo 5 的 bind_cache / 驱逐在 demo 6 里
-- 全部消失，不可达的描述符由 GC 回收。
function ObjectManager:new_member_desc(member_id)
    return Handle.new({ member_id = member_id, obj = nil }) -- MemberDesc
end

function ObjectManager:new_ctor_desc(cls_id, ctor_idx)
    return Handle.new({ cls_id = cls_id, ctor_idx = ctor_idx }) -- CtorDesc
end

-- 绑定描述符：每次新建。obj 是普通 Handle——描述符不持有对象（GC 管不到
-- gc 对象），「正在执行方法」的对象由 runtime.pinned 保活。
function ObjectManager:bind(member_id, obj_handle)
    local d = { member_id = member_id, obj = obj_handle }
    return Handle.new(d)
end

-- 三个开口的公共前奏：安全点——先同步根集合，再做本次操作。「引用计数
-- 归零 -> 立即级联释放」的可靠性由这条顺序保证（见 gc_alloc.lua 头注释）。
function ObjectManager:safe_point()
    self.alloc:sync_roots()
end

-- obj:<名>[p] -> 绑定描述符。
function ObjectManager:at(s, handle, key)
    self:safe_point()
    local d = handle.data
    if d.member_id == nil then
        s:error("no implement for container type. ") -- 构造描述符不可 At
        return nil
    end
    if not Handle.is(key) then
        s:error("not an object. ")
        return nil
    end
    return self:bind(d.member_id, key)
end

-- obj:<属性>[p] = v -> 写字段（走 set_field：旧值减引用可级联，新值加引用）。
function ObjectManager:assign(s, handle, value)
    self:safe_point()
    local d = handle.data
    if d.member_id == nil or d.obj == nil then
        s:error("not assignable. ")
        return
    end
    local obj = d.obj.data
    if obj.dead then
        s:error("use after gc. ") -- 死对象不可达才判死，正常程序到不了这里
        return
    end
    local cls = self.runtime.classes[obj.class_id + 1] -- 第一层
    local ref = cls.member_by_id[d.member_id]
    if ref == nil or ref.kind ~= PROP then
        s:error("not assignable. ") -- 该类没有这个属性 / 方法不可赋值
        return
    end
    self.alloc:set_field(obj, ref.index + 1, value) -- 第二层
end

-- obj:<名>[p](...) -> 调方法；<Class>:<New>(...) -> 构造。
-- demo 6 没有 obj:delete(p)：生命期归 gc 管。
function ObjectManager:call_member(s, handle, args)
    self:safe_point()
    local d = handle.data
    if d.cls_id ~= nil then
        -- CtorDesc：构造
        local cls = self.runtime.classes[d.cls_id + 1]
        local obj_handle = self:new_object(d.cls_id)
        if obj_handle == nil then
            s:error("too many gc nodes. ") -- 顶到 max_nodes：走正常错误通道
            return nil
        end
        -- 构造期间新生对象的 Handle 只在局部 obj_handle 与构造方法 State
        -- 的 self 绑定里——下个安全点被登记为根。
        self.runtime:invoke_method(cls.methods[d.ctor_idx + 1], obj_handle.data, args)
        return obj_handle
    end
    -- MemberDesc
    if d.obj == nil then
        s:error("method not bound. ") -- demo 6 只支持 obj:<名>[p]() 形式
        return nil
    end
    local obj = d.obj.data
    if obj.dead then
        s:error("use after gc. ")
        return nil
    end
    local cls = self.runtime.classes[obj.class_id + 1] -- 第一层
    local ref = cls.member_by_id[d.member_id]
    if ref == nil or ref.kind ~= METHOD then
        s:error("no method. ") -- 该类没有这个方法（属性不可调）
        return nil
    end
    -- 方法调用压帧：返回占位 NULL——op_call 把它压到调用方栈顶，方法帧弹栈
    -- 时（finish_top_frame）再回填真正的返回值。⚠ 必须是 stope.NULL 而不是
    -- Lua nil：`stack[#stack] = nil` 是删条目（栈会缩短），不是占位。
    self.runtime:push_method_frame(cls.methods[ref.index + 1], obj, args, true)
    return stope.NULL
end

-- gc 回收前回调（alloc.on_free）：跑 <delete>。此时字段还完整可读。
function ObjectManager:run_destructor(obj)
    local cls = self.runtime.classes[obj.class_id + 1]
    if cls.deconstructor_id >= 0 then
        self.runtime:invoke_method(cls.methods[cls.deconstructor_id + 1], obj, {})
    end
end

function ObjectManager:report_live()
    self.alloc:report_alive()
    if self.alloc:root_count() == 0 then
        print("[gc] no roots: everything reachable has been freed")
    else
        print("[gc] roots keep " .. self.alloc:root_count()
            .. " object(s) alive - frame stack not empty (freed by dispose_all)")
    end
end

return ObjectManager
