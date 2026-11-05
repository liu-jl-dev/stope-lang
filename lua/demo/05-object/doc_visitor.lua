-- doc_visitor.lua：STML 文档 -> 类与函数，含编译、索引预算与 self 链接
-- （对应 cpp/demo/05-object/ 的 DocVisitor.*）。

local stope = require("stope")

local PROP, METHOD, DELETE = 0, 1, 2 -- MemberKind

-- 装配期失败用 error() 上传（Lua 有 error/pcall，对齐 C++ 的 throw；main 里接住）。
local DocVisitor = {}
DocVisitor.__index = DocVisitor

function DocVisitor.new()
    return setmetatable({}, DocVisitor)
end

function DocVisitor:visit_doc(root, rt)
    for _, e in ipairs(root.children) do
        if e.tag == "class" then
            self:visit_class(e, rt)
        elseif e.tag == "func" then
            self:visit_func(e, rt)
        end
    end
    self:link_self_calls(rt)
end

function DocVisitor:visit_class(e, rt)
    local cls = rt:new_class()
    cls.name = e.attrs["name"]
    for _, c in ipairs(e.children) do
        if c.tag == "property" then
            cls.member_by_id[rt:new_member_id(c.attrs["name"])] =
                { kind = PROP, index = #cls.properties }
            cls.properties[#cls.properties + 1] = c.attrs["name"]
        elseif c.tag == "method" then
            local idx = #cls.methods
            self:visit_method(c, rt, cls)
            if cls.methods[#cls.methods].name ~= "" then
                cls.member_by_id[rt:new_member_id(cls.methods[#cls.methods].name)] =
                    { kind = METHOD, index = idx }
            end
        elseif c.tag == "new" then
            local idx = #cls.methods
            cls.constructor_map[c.attrs["name"]] = idx
            self:visit_method(c, rt, cls)
        elseif c.tag == "delete" and cls.deconstructor_id == -1 then
            local idx = #cls.methods
            cls.deconstructor_id = idx
            self:visit_method(c, rt, cls)
            cls.member_by_id[rt:new_member_id("delete")] = { kind = DELETE, index = idx }
        end
    end
end

function DocVisitor:visit_method(e, rt, cls)
    local m = { name = e.attrs["name"] or "", params = {}, program = nil,
        self_props = {}, host_binds = {}, self_method_binds = {}, param_slots = {} }
    if e.attrs["params"] ~= nil then
        for p in e.attrs["params"]:gmatch("%S+") do
            m.params[#m.params + 1] = p
        end
    end
    -- pre_exports = 形参（属性不进：self:<属性> 走隐式导出，链接遍配对）。
    m.program = self:compile(e.text, e.text_line, m.params)
    -- 装配期预计算整数索引：宿主函数 -> (槽位, 序号)；形参 -> 槽位。
    for nm, idx in pairs(rt.host_func_map) do
        local slot = m.program.exports[nm]
        if slot ~= nil then
            m.host_binds[#m.host_binds + 1] = { slot, idx }
        end
    end
    for _, p in ipairs(m.params) do
        m.param_slots[#m.param_slots + 1] = m.program.exports[p]
    end
    cls.methods[#cls.methods + 1] = m
end

function DocVisitor:visit_func(e, rt)
    local f = { name = e.attrs["name"], params = {}, program = nil,
        host_binds = {}, param_slots = {} }
    if e.attrs["params"] ~= nil then
        for p in e.attrs["params"]:gmatch("%S+") do
            f.params[#f.params + 1] = p
        end
    end
    f.program = self:compile(e.text, e.text_line, f.params)
    for nm, idx in pairs(rt.host_func_map) do
        local slot = f.program.exports[nm]
        if slot ~= nil then
            f.host_binds[#f.host_binds + 1] = { slot, idx }
        end
    end
    for _, p in ipairs(f.params) do
        f.param_slots[#f.param_slots + 1] = f.program.exports[p]
    end
    rt.functions[#rt.functions + 1] = f
end

-- 链接 self:<属性> 与 self:<方法名>，并校验方法里 self: 前缀的隐式导出
-- 全部链接成功（拼写错误装配期拦下）。必须在全部类访问完之后跑：方法可以
-- 引用文档里后定义的成员。<func> 里的 self: 有意不校验（见 docs §10）。
function DocVisitor:link_self_calls(rt)
    for _, cls in ipairs(rt.classes) do
        for _, m in ipairs(cls.methods) do
            for fi, prop in ipairs(cls.properties) do
                local nm = "self:" .. prop
                local slot = m.program.exports[nm]
                if slot ~= nil then
                    m.self_props[#m.self_props + 1] = { slot, fi - 1 }
                end
            end
            for nm, member_id in pairs(rt.member_name_map) do
                if nm ~= "" then -- <delete> 无名
                    local ref = cls.member_by_id[member_id]
                    if ref ~= nil and ref.kind == METHOD then
                        local enm = "self:" .. nm
                        local slot = m.program.exports[enm]
                        if slot ~= nil then
                            m.self_method_binds[#m.self_method_binds + 1] = { slot, member_id }
                        end
                    end
                end
            end
            for enm, slot in pairs(m.program.exports) do
                if enm:sub(1, 5) == "self:" then
                    local linked = false
                    for _, p in ipairs(m.self_props) do
                        if p[1] == slot then linked = true end
                    end
                    for _, b in ipairs(m.self_method_binds) do
                        if b[1] == slot then linked = true end
                    end
                    if not linked then
                        error("unlinked self member: " .. enm)
                    end
                end
            end
        end
    end
end

-- 编译一份源码：pre_exports = 形参；失败即 error（对齐 C++ 的装配期异常）。
function DocVisitor:compile(src_code, start_line, pre_exports)
    local lexer = stope.Lexer.new(src_code)
    lexer.line = start_line -- 报错行号对齐原文档
    local parser = stope.Parser.new(lexer)
    local tree = stope.AST.Prog()
    parser:parse_program(tree)
    if #lexer.errors > 0 or #parser.errors > 0 then
        local errs = {}
        for _, e in ipairs(lexer.errors) do errs[#errs + 1] = "  lexer: " .. e end
        for _, e in ipairs(parser.errors) do errs[#errs + 1] = "  parser: " .. e end
        error(table.concat(errs, "\n"))
    end
    local compiler = stope.Compiler.new()
    local out = stope.Program.new()
    if compiler:compile(tree, out, pre_exports) ~= stope.Result.Success then
        local errs = {}
        for _, e in ipairs(compiler.errors) do errs[#errs + 1] = "  compiler: " .. e end
        error(table.concat(errs, "\n"))
    end
    return out
end

return DocVisitor
