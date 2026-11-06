# doc_visitor.py：STML 文档 -> 类与函数，含编译、索引预算与 self 链接
# （对应 C++ 的 DocVisitor.*）。
# 与 demo 5 的差异：<delete> 只设 deconstructor（不注册 obj:delete 成员）；
# link 阶段多一步 export_binds 预算（方法体里的 <类名>:<构造名> / obj:<名>）。

from stope import (AST, Compiler, Lexer, Parser, Program, Result)

from classes import FunctionInfo, MethodInfo
from object_model import METHOD, PROP, MemberRef


class DocVisitor:
    # 装配期失败用异常上传（对齐 C++ 的 throw；main 里接住）。
    def visit_doc(self, root, rt):
        for e in root.children:
            if e.tag == "class":
                self.visit_class(e, rt)
            elif e.tag == "func":
                self.visit_func(e, rt)
        self.link_self_calls(rt)

    def visit_class(self, e, rt):
        cls = rt.new_class()
        cls.name = e.attrs["name"]
        rt.class_map[cls.name] = cls.id  # 命名后再登记：new_class 时 name 还是空
        for c in e.children:
            if c.tag == "property":
                cls.member_by_id[rt.new_member_id(c.attrs["name"])] = \
                    MemberRef(PROP, len(cls.properties))
                cls.properties.append(c.attrs["name"])
            elif c.tag == "method":
                idx = len(cls.methods)
                self.visit_method(c, rt, cls)
                if cls.methods[-1].name != "":
                    cls.member_by_id[rt.new_member_id(cls.methods[-1].name)] = \
                        MemberRef(METHOD, idx)
            elif c.tag == "new":
                idx = len(cls.methods)
                cls.constructor_map[c.attrs["name"]] = idx
                self.visit_method(c, rt, cls)
            elif c.tag == "delete" and cls.deconstructor_id == -1:
                idx = len(cls.methods)
                cls.deconstructor_id = idx
                self.visit_method(c, rt, cls)
                # demo 6：<delete> 是 gc 回收时自动跑的析构函数，不注册
                # obj:delete 成员——没有手动删除入口，成员 id 也不为它分配。

    def visit_method(self, e, rt, cls):
        m = MethodInfo()
        m.name = e.attrs.get("name", "")
        if "params" in e.attrs:
            m.params = e.attrs["params"].split()
        # pre_exports = 形参（属性不进：self:<属性> 走隐式导出，链接遍配对）。
        m.program = self._compile(e.text, e.text_line, m.params)
        # 装配期预计算整数索引：宿主函数 -> (槽位, 序号)；形参 -> 槽位。
        for nm, idx in rt.host_func_map.items():
            if nm in m.program.exports:
                m.host_binds.append([m.program.exports[nm], idx])
        for p in m.params:
            m.param_slots.append(m.program.exports[p])
        cls.methods.append(m)

    def visit_func(self, e, rt):
        f = FunctionInfo()
        f.name = e.attrs["name"]
        if "params" in e.attrs:
            f.params = e.attrs["params"].split()
        f.program = self._compile(e.text, e.text_line, f.params)
        for nm, idx in rt.host_func_map.items():
            if nm in f.program.exports:
                f.host_binds.append([f.program.exports[nm], idx])
        for p in f.params:
            f.param_slots.append(f.program.exports[p])
        rt.functions.append(f)

    # 链接 self:<属性> 与 self:<方法名>，并校验方法里 self: 前缀的隐式导出
    # 全部链接成功（拼写错误装配期拦下）。必须在全部类访问完之后跑：方法可以
    # 引用文档里后定义的成员。<func> 里的 self: 有意不校验（见 docs §10）。
    def link_self_calls(self, rt):
        for cls in rt.classes:
            for m in cls.methods:
                for fi, prop in enumerate(cls.properties):
                    nm = "self:" + prop
                    if nm in m.program.exports:
                        m.self_props.append([m.program.exports[nm], fi])
                for nm, member_id in rt.member_name_map.items():
                    if nm == "":
                        continue  # <delete> 无名
                    ref = cls.member_by_id.get(member_id)
                    if ref is None or ref.kind != METHOD:
                        continue  # 不是本类的方法成员
                    enm = "self:" + nm
                    if enm in m.program.exports:
                        m.self_method_binds.append([m.program.exports[enm], member_id])
                # 方法体里的 <类名>:<构造名> / obj:<名>：方法有独立的
                # program，这些名字是它自己的隐式导出，每个 State 都要各自
                # 绑。描述符被 export_binds 引用着——引用计数保证存活。
                for enm2, slot2 in m.program.exports.items():
                    colon = enm2.find(":")
                    if colon < 0:
                        continue
                    head, tail = enm2[:colon], enm2[colon + 1:]
                    handle = None
                    if head == "obj":
                        mid = rt.member_name_map.get(tail)
                        if mid is None:
                            continue  # 不是任何已注册成员
                        handle = rt.obj_mgr.new_member_desc(mid)
                    else:
                        cid = rt.class_map.get(head)
                        if cid is None:
                            continue
                        ctor_idx = rt.classes[cid].constructor_map.get(tail)
                        if ctor_idx is None:
                            continue
                        handle = rt.obj_mgr.new_ctor_desc(cid, ctor_idx)
                    m.export_binds.append([slot2, handle])
                for enm, slot in m.program.exports.items():
                    if not enm.startswith("self:"):
                        continue
                    linked = any(p[0] == slot for p in m.self_props) or \
                        any(b[0] == slot for b in m.self_method_binds)
                    if not linked:
                        raise RuntimeError("unlinked self member: " + enm)

    # 编译一份源码：pre_exports = 形参；失败即抛（对齐 C++ 的装配期异常）。
    def _compile(self, src, start_line, pre_exports):
        lexer = Lexer(src)
        lexer.line = start_line  # 报错行号对齐原文档
        parser = Parser(lexer)
        tree = AST.Prog()
        parser.parse_program(tree)
        if lexer.errors or parser.errors:
            for e in lexer.errors:
                print("  lexer: " + e)
            for e in parser.errors:
                print("  parser: " + e)
            raise RuntimeError("parse failed")
        compiler = Compiler()
        out = Program()
        if compiler.compile(tree, out, pre_exports) != Result.Success:
            for e in compiler.errors:
                print("  compiler: " + e)
            raise RuntimeError("compile failed")
        return out
