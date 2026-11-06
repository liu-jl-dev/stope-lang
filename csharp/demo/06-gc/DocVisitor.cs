using System;
using System.Collections.Generic;

using Stope;
using Stope.Stml;

namespace Stope.Demo;

// ==================== DocVisitor：STML 文档 -> 类与函数 ====================
// 与 demo 5 的差异：<delete> 只设 Deconstructor（不注册 obj:delete 成员）；
// Link 阶段多一步 ExportBinds 预算（方法体里的 <类名>:<构造名> / obj:<名>）。

/// <summary>装配期失败用异常上传（对齐 C++ 的 throw；main 里接住）。</summary>
internal sealed class DocVisitor
{
    public void VisitDoc(Stml.Element root, Runtime rt)
    {
        foreach (var e in root.Children)
        {
            if (e.Tag == "class") VisitClass(e, rt);
            else if (e.Tag == "func") VisitFunc(e, rt);
        }
        LinkSelfCalls(rt);
    }

    private void VisitClass(Stml.Element e, Runtime rt)
    {
        var cls = rt.NewClass();
        cls.Name = e.Attrs["name"];
        rt.ClassMap[cls.Name] = cls.Id; // 命名后再登记：NewClass 时 Name 还是空
        foreach (var c in e.Children)
        {
            if (c.Tag == "property")
            {
                cls.MemberById[rt.NewMemberId(c.Attrs["name"])] =
                    new MemberRef { Kind = MemberKind.Prop, Index = cls.Properties.Count };
                cls.Properties.Add(c.Attrs["name"]);
            }
            else if (c.Tag == "method")
            {
                int idx = cls.Methods.Count;
                VisitMethod(c, rt, cls);
                if (cls.Methods[^1].Name != "")
                    cls.MemberById[rt.NewMemberId(cls.Methods[^1].Name)] =
                        new MemberRef { Kind = MemberKind.Method, Index = idx };
            }
            else if (c.Tag == "new")
            {
                int idx = cls.Methods.Count;
                cls.ConstructorMap[c.Attrs["name"]] = idx;
                VisitMethod(c, rt, cls);
            }
            else if (c.Tag == "delete" && cls.DeconstructorId == -1)
            {
                int idx = cls.Methods.Count;
                cls.DeconstructorId = idx;
                VisitMethod(c, rt, cls);
                // demo 6：<delete> 是 gc 回收时自动跑的析构函数，不注册
                // obj:delete 成员——没有手动删除入口，成员 id 也不为它分配。
            }
        }
    }

    private void VisitMethod(Stml.Element e, Runtime rt, ClassInfo cls)
    {
        var m = new MethodInfo
        {
            Name = e.Attrs.TryGetValue("name", out var nm) ? nm : "",
        };
        if (e.Attrs.TryGetValue("params", out var ps))
            m.Params.AddRange(ps.Split(' ', StringSplitOptions.RemoveEmptyEntries));
        // pre_exports = 形参（属性不进：self:<属性> 走隐式导出，链接遍配对）。
        m.Program = Compile(e.Text, e.TextLine, m.Params);
        // 装配期预计算整数索引：宿主函数 -> (槽位, 序号)；形参 -> 槽位。
        foreach (var kv in rt.HostFuncMap)
            if (m.Program.Exports.TryGetValue(kv.Key, out var slot))
                m.HostBinds.Add(new[] { slot, kv.Value });
        foreach (var p in m.Params) m.ParamSlots.Add(m.Program.Exports[p]);
        cls.Methods.Add(m);
    }

    private void VisitFunc(Stml.Element e, Runtime rt)
    {
        var f = new FunctionInfo { Name = e.Attrs["name"] };
        if (e.Attrs.TryGetValue("params", out var ps))
            f.Params.AddRange(ps.Split(' ', StringSplitOptions.RemoveEmptyEntries));
        f.Program = Compile(e.Text, e.TextLine, f.Params);
        foreach (var kv in rt.HostFuncMap)
            if (f.Program.Exports.TryGetValue(kv.Key, out var slot))
                f.HostBinds.Add(new[] { slot, kv.Value });
        foreach (var p in f.Params) f.ParamSlots.Add(f.Program.Exports[p]);
        rt.Functions.Add(f);
    }

    // 链接 self:<属性> 与 self:<方法名>，并校验方法里 self: 前缀的隐式导出
    // 全部链接成功（拼写错误装配期拦下）。必须在全部类访问完之后跑：方法可以
    // 引用文档里后定义的成员。<func> 里的 self: 有意不校验（见 docs §10）。
    private void LinkSelfCalls(Runtime rt)
    {
        foreach (var cls in rt.Classes)
        {
            foreach (var m in cls.Methods)
            {
                for (int fi = 0; fi < cls.Properties.Count; ++fi)
                {
                    var nm = "self:" + cls.Properties[fi];
                    if (m.Program.Exports.TryGetValue(nm, out var slot))
                        m.SelfProps.Add(new[] { slot, fi });
                }
                foreach (var kv in rt.MemberNameMap)
                {
                    if (kv.Key == "") continue; // <delete> 无名
                    if (!cls.MemberById.TryGetValue(kv.Value, out var r)
                        || r.Kind != MemberKind.Method) continue;
                    var enm = "self:" + kv.Key;
                    if (m.Program.Exports.TryGetValue(enm, out var slot2))
                        m.SelfMethodBinds.Add(new[] { slot2, kv.Value });
                }
                // 方法体里的 <类名>:<构造名> / obj:<名>：方法有独立的
                // program，这些名字是它自己的隐式导出，每个 State 都要各自
                // 绑。描述符被 ExportBinds 引用着——引擎 GC 保证存活。
                foreach (var kv2 in m.Program.Exports)
                {
                    int colon = kv2.Key.IndexOf(':');
                    if (colon < 0) continue;
                    var head = kv2.Key[..colon];
                    var tail = kv2.Key[(colon + 1)..];
                    Handle? handle = null;
                    if (head == "obj")
                    {
                        if (!rt.MemberNameMap.TryGetValue(tail, out var mid)) continue;
                        handle = rt.ObjMgr.NewMemberDesc(mid);
                    }
                    else
                    {
                        if (!rt.ClassMap.TryGetValue(head, out var cid)) continue;
                        if (!rt.Classes[cid].ConstructorMap.TryGetValue(tail, out var ctorIdx)) continue;
                        handle = rt.ObjMgr.NewCtorDesc(cid, ctorIdx);
                    }
                    m.ExportBinds.Add(new object?[] { kv2.Value, handle });
                }
                foreach (var kv in m.Program.Exports)
                {
                    if (!kv.Key.StartsWith("self:", StringComparison.Ordinal)) continue;
                    bool linked = ContainsSlot(m.SelfProps, kv.Value)
                        || ContainsSlot(m.SelfMethodBinds, kv.Value);
                    if (!linked)
                        throw new Exception("unlinked self member: " + kv.Key);
                }
            }
        }
    }

    private static bool ContainsSlot(List<int[]> pairs, int slot)
    {
        foreach (var p in pairs)
            if (p[0] == slot)
                return true;
        return false;
    }

    // 编译一份源码：pre_exports = 形参；失败即抛（对齐 C++ 的装配期异常）。
    private static Program Compile(string src, int startLine, List<string> preExports)
    {
        var lexer = new Lexer(src);
        lexer.Line = startLine; // 报错行号对齐原文档
        var parser = new Parser(lexer);
        var tree = new Prog();
        parser.ParseProgram(tree);
        if (lexer.Errors.Count > 0 || parser.Errors.Count > 0)
            throw new Exception("parse failed");
        var compiler = new Compiler();
        var outProg = new Program();
        if (compiler.Compile(tree, outProg, preExports) != Result.Success)
            throw new Exception("compile failed");
        return outProg;
    }
}
