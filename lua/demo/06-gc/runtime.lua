-- runtime.lua：静态结构 + 调用 + 入口绑定（对应 cpp/demo/06-gc/ 的
-- Runtime.*）。
--
-- 执行模型是**显式帧栈**：frames 里每帧一个 State，run_steps(max) 只跑栈顶
-- 帧的至多 max 条指令，run_all() 一口气跑到帧栈清空，随时可切。方法调用不
-- 再递归——call 开口直接压新帧（Lua 没有借用限制，回调可以直接碰 frames，
-- 这是它比 Rust 版少一层 pending 暂存的原因）。析构 <delete> 走**同步旁路**
-- invoke_method：级联/sweep 中间不能让出执行权，其执行期间压的帧没人跑。

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
    self.class_map = {} -- 类名 -> 类 id（export_binds 按类名找构造器）
    self.functions = {}
    self.classes = {}
    self.obj_mgr = ObjectManager.new(self)
    self.api = new_demo_api(self.obj_mgr)
    -- frames 显式帧栈：入口帧 + 压住的方法帧。run_steps 每次只跑栈顶帧；
    -- 方法调用压帧、返回弹帧，调用方在栈里压住等返回值。
    self.frames = {}
    self.had_errors = false -- 任一帧出错置位（错误已打印，供入口返回码用）
    -- live_states 只装 <delete> 析构的同步旁路 State（见 invoke_method）。
    self.live_states = {}
    -- 正在执行方法的对象（Lua 版的「保活」机制）：C++ demo 6 靠绑定描述符
    -- 的字段引用撑住 self，Lua 的描述符不参与 gc，改由这个表强引用——
    -- 压帧时加入、弹帧收尾移除；invoke_method（同步旁路）同样。
    self.pinned = {}
    -- gc 根扫描：分配器不认识 State，由 Runtime 供给。只有「Handle 载荷是
    -- 业务对象」才算引用；描述符由 GC 管，不算。
    self.obj_mgr.alloc.gather_roots = function()
        return self:gather_roots()
    end
    -- 析构回调：对象被回收前跑 <delete>。
    self.obj_mgr.alloc.on_free = function(obj)
        self.obj_mgr:run_destructor(obj)
    end
    return self
end

function Runtime:gather_roots()
    local out = {}
    -- 注意：State.variables 是 0 起的平表（let 的槽位可能是 0），必须用
    -- pairs 走全表——ipairs 从 1 起，会漏掉 0 号槽位里的根。
    local function scan(s)
        for _, arr in ipairs({ s.variables, s.stack, s.returns }) do
            if type(arr) == "table" then
                for _, v in pairs(arr) do
                    if stope.Handle.is(v) and type(v.data) == "table"
                        and v.data.tag == "gcnode" then
                        out[#out + 1] = v.data
                    end
                end
            end
        end
    end
    for _, f in ipairs(self.frames) do
        scan(f.state)
    end
    for _, s in ipairs(self.live_states) do
        scan(s)
    end
    for _, o in ipairs(self.pinned) do
        out[#out + 1] = o
    end
    return out
end

function Runtime:track_state(s)
    self.live_states[#self.live_states + 1] = s
end

function Runtime:untrack_state(s)
    for i = #self.live_states, 1, -1 do
        if self.live_states[i] == s then
            table.remove(self.live_states, i)
            return
        end
    end
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

-- ==================== 显式帧栈：把 State 显式放在一个栈里，驱动循环只跑栈顶帧 ====================

-- 装配入口函数并压帧：宿主函数、构造器描述符、obj:* 成员描述符绑进导出槽
-- 位（bind_entry）。demo 6 没有 obj:delete——生命期归 gc 管，<delete> 是回
-- 收时自动跑的析构。
function Runtime:push_entry_frame(entry)
    local state = stope.State.new()
    state:set_api(self.api)
    state:set_program(entry.program)
    self:bind_entry(state, entry)
    self.frames[#self.frames + 1] =
        { state = state, self_props = {}, self_obj = nil, wants_return = false }
end

-- 装配方法 State（push_method_frame / invoke_method 共用）。
function Runtime:setup_method_state(m, obj, args)
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
    -- 方法体里的 <类名>:<构造名> / obj:<名> 描述符：装配期已预算好
    -- (槽位, Handle)，逐个拷进槽位。
    for _, b in ipairs(m.export_binds) do
        state.variables[b[1]] = b[2]
    end
    -- self:<方法名> 槽位绑 self 的绑定方法描述符——每次新建（不去重）。
    for _, b in ipairs(m.self_method_binds) do
        state.variables[b[1]] = self.obj_mgr:bind(b[2], stope.Handle.new(obj))
    end
    return state
end

-- 压入方法帧，不执行——run_steps 自然切到栈顶帧。调用方（call 开口的发起
-- 方）停在 Call 的下一条；开口返回的占位 nil 会被 op_call 压到调用方栈顶，
-- 弹帧收尾时用真正的返回值覆盖。self 进 pinned 保活。
function Runtime:push_method_frame(m, obj, args, wants_return)
    local state = self:setup_method_state(m, obj, args)
    self.frames[#self.frames + 1] = {
        state = state, self_props = m.self_props, self_obj = obj, wants_return = wants_return,
    }
    self.pinned[#self.pinned + 1] = obj
end

-- 每帧限步驱动：只跑栈顶帧，至多 max_steps 条指令；帧弹栈（Return / 指令流
-- 走完 / 出错中止当前函数）不消耗步数。返回 false = 帧栈已空。
function Runtime:run_steps(max_steps)
    local steps = max_steps
    while steps > 0 do
        local top = self.frames[#self.frames]
        if top == nil then return false end
        if top.state.i >= #top.state.program.opcodes then
            self:finish_top_frame() -- Return 已把返回值备好；弹栈不消耗步数
        elseif top.state:step() ~= stope.Result.Success then
            self:finish_top_frame() -- 运行期错误：只中止当前函数，调用方继续
        else
            steps = steps - 1
        end
    end
    return self.frames[#self.frames] ~= nil
end

-- 直接执行：一口气跑到帧栈清空。与 run_steps 随时可切。
function Runtime:run_all()
    while self:run_steps(math.huge) do end
end

-- 摘出栈顶帧并收尾：错误打印、self: 槽位写回字段（走 set_field：引用计数
-- 照常维护）、返回值回填调用方栈顶（op_call 已把占位 nil 压到那里，覆盖即
-- 可）。
function Runtime:finish_top_frame()
    local f = table.remove(self.frames)
    for _, e in ipairs(f.state.errors) do
        print("  vm: " .. e)
        self.had_errors = true
    end
    if f.self_obj == nil then return end -- 入口帧：没有 selfProps / 返回值
    self.pinned[#self.pinned] = nil -- 与 push_method_frame 配对
    -- 返回前把 self: 槽位写回字段——selfProps 只含方法体实际引用的属性。
    for _, p in ipairs(f.self_props) do
        self.obj_mgr.alloc:set_field(f.self_obj, p[2] + 1, f.state.variables[p[1]])
    end
    -- 回填调用方栈顶（wants_return 帧）。构造器帧返回的是新对象本身，不走这里。
    if f.wants_return then
        local caller = self.frames[#self.frames]
        if caller ~= nil and f.state.returns[1] ~= nil then
            caller.state.stack[#caller.state.stack] = f.state.returns[1]
        end
    end
end

-- 同步执行整个方法（<delete> 析构路径）：装配 + Run + 收尾。析构在级联释放
-- / sweep 的中间被调用，跑完后调用方还要清字段——不能让出执行权。析构里再
-- 调方法也走这条路：压帧没人跑（此刻正停在 Step 中间）。
function Runtime:invoke_method(m, obj, args)
    local state = self:setup_method_state(m, obj, args)
    self.pinned[#self.pinned + 1] = obj
    self:track_state(state)
    state:run()
    self:untrack_state(state)
    self.pinned[#self.pinned] = nil
    for _, e in ipairs(state.errors) do
        print("  vm: " .. e)
        self.had_errors = true
    end
    -- 返回前把 self: 槽位写回字段（走 set_field：引用计数照常维护）。
    for _, p in ipairs(m.self_props) do
        self.obj_mgr.alloc:set_field(obj, p[2] + 1, state.variables[p[1]])
    end
    return state.returns[1] or stope.NULL
end

-- 装配入口函数：宿主函数、构造器描述符、obj:* 成员描述符绑进导出槽位。
-- demo 6 没有 obj:delete——生命期归 gc 管，<delete> 是回收时自动跑的析构。
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
    end
end

function Runtime:_bind_export(state, entry, nm, handle)
    local slot = entry.program.exports[nm]
    if slot ~= nil then
        state.variables[slot] = handle
    end
end

return Runtime
