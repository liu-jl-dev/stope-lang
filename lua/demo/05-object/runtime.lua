-- runtime.lua：静态结构 + 调用 + 入口绑定（对应 cpp/demo/05-object/ 的
-- Runtime.*）。

local stope = require("stope")
local ObjectManager = require("object_manager")

-- ==================== Api：三个开口薄转发到 ObjectManager ====================
-- Lua 没有 class 继承语法：new 一个 Api，在实例上覆写三个字段即可（转发走
-- s.api，State 挂着的正是这个实例）。

local function new_demo_api(obj_mgr)
    local api = stope.Api.new()
    function api:handle_at(_s, handle, key) return obj_mgr:at(_s, handle, key) end
    function api:handle_assign(_s, handle, value) obj_mgr:assign(_s, handle, value) end
    function api:handle_call(_s, handle, args) return obj_mgr:call_member(_s, handle, args) end
    return api
end

-- ==================== Runtime：静态结构 + 调用 ====================

local Runtime = {}
Runtime.__index = Runtime

function Runtime.new()
    local self = setmetatable({}, Runtime)
    self.host_funcs = {}
    self.host_func_map = {} -- 名 -> host_funcs 序号
    self.member_name_map = {} -- 成员名 -> 成员 id（跨类共享同名 id）
    self.functions = {}
    self.classes = {}
    self.obj_mgr = ObjectManager.new(self)
    self.api = new_demo_api(self.obj_mgr)
    return self
end

function Runtime:new_member_id(nm)
    local id = self.member_name_map[nm]
    if id ~= nil then return id end
    id = self.member_id_next or 0 -- 成员 id 连续分配（0 起）
    self.member_id_next = id + 1
    self.member_name_map[nm] = id
    return id
end

function Runtime:new_class()
    local cls = { id = #self.classes, name = "", properties = {}, methods = {},
        member_by_id = {}, constructor_map = {}, deconstructor_id = -1 }
    self.classes[#self.classes + 1] = cls
    return cls
end

function Runtime:find_function(nm)
    for _, f in ipairs(self.functions) do
        if f.name == nm then return f end
    end
    return nil
end

function Runtime:add_host_function(nm, fn)
    self.host_func_map[nm] = #self.host_funcs + 1
    self.host_funcs[#self.host_funcs + 1] = fn
end

-- 方法/函数调用：每层调用一个临时 State，随返回销毁 —— 嵌套调用就是 Lua 的
-- 递归栈。Runtime 不保存调用栈（demo 6 做根扫描时才需要）。
function Runtime:invoke_method(m, obj, args)
    local state = stope.State.new()
    state:set_api(self.api)
    state:set_program(m.program)
    -- self:<属性> 槽位：从字段拷入（只拷方法体实际引用的）。
    for _, p in ipairs(m.self_props) do
        state.variables[p[1]] = obj.fields[p[2] + 1]
    end
    for k, slot in ipairs(m.param_slots) do
        -- 缺参静默：缺的槽位是 null（已知局限，见 docs §10）
        state.variables[slot] = args[k] or stope.NULL
    end
    for _, b in ipairs(m.host_binds) do
        state.variables[b[1]] = self.host_funcs[b[2]]
    end
    -- self:<方法名> 槽位绑 self 的绑定方法描述符——创建即绑定 self，
    -- self:Greet() 无需 [对象]；去重缓存保证递归调用不重复分配。
    for _, b in ipairs(m.self_method_binds) do
        state.variables[b[1]] = self.obj_mgr:bind(b[2], stope.Handle.new(obj))
    end
    state:run()
    for _, e in ipairs(state.errors) do
        print("  vm: " .. e)
    end
    -- 返回前把 self: 槽位写回字段（只写实际引用的那几个）。
    for _, p in ipairs(m.self_props) do
        obj.fields[p[2] + 1] = state.variables[p[1]]
    end
    return state.returns[1] or stope.NULL
end

-- 装配入口函数：宿主函数、构造器描述符、obj:* 成员描述符绑进导出槽位。
-- 按名只发生在这里（装配期），state:run() 期间零按名查找。
function Runtime:bind_entry(state, entry)
    for _, b in ipairs(entry.host_binds) do
        state.variables[b[1]] = self.host_funcs[b[2]]
    end
    for _, cls in ipairs(self.classes) do
        for nm, ctor_idx in pairs(cls.constructor_map) do
            self:_bind_export(state, entry, cls.name .. ":" .. nm,
                self.obj_mgr:new_ctor_desc(cls.id, ctor_idx))
        end
        for _, prop in ipairs(cls.properties) do
            self:_bind_export(state, entry, "obj:" .. prop,
                self.obj_mgr:new_member_desc(self:new_member_id(prop)))
        end
        for _, m in ipairs(cls.methods) do
            if m.name ~= "" and cls.constructor_map[m.name] == nil then
                self:_bind_export(state, entry, "obj:" .. m.name,
                    self.obj_mgr:new_member_desc(self:new_member_id(m.name)))
            end
        end
        if cls.deconstructor_id >= 0 then
            self:_bind_export(state, entry, "obj:delete",
                self.obj_mgr:new_member_desc(self:new_member_id("delete")))
        end
    end
end

function Runtime:_bind_export(state, entry, nm, handle)
    local slot = entry.program.exports[nm]
    if slot ~= nil then
        state.variables[slot] = handle
    end
end

return Runtime
