// doc_visitor.go：STML 文档 -> 类与函数，含编译、索引预算与 self 链接
// （对应 cpp/demo/06-gc/ 的 DocVisitor.*）。
//
// 与 demo 5 的差异：<delete> 只设 Deconstructor（不注册 obj:delete 成员）；
// link 阶段多一步 ExportBinds 预算（方法体里的 <类名>:<构造名> / obj:<名>）。
package main

import (
	"strings"

	"stope"
	"stope/basicvm"
	"stope/stml"
)

type docVisitor struct{}

// visitDoc 装配期失败用 panic 上传（对齐 C++ 的 throw；main 里 recover 接住）。
func (v *docVisitor) visitDoc(root *stml.Element, rt *Runtime) {
	for _, e := range root.Children {
		switch e.Tag {
		case "class":
			v.visitClass(e, rt)
		case "func":
			v.visitFunc(e, rt)
		}
	}
	v.linkSelfCalls(rt)
}

func (v *docVisitor) visitClass(e *stml.Element, rt *Runtime) {
	cls := rt.newClass()
	cls.Name = e.Attr("name")
	rt.classMap[cls.Name] = cls.ID // 命名后再登记：newClass 时 Name 还是空
	for _, c := range e.Children {
		switch c.Tag {
		case "property":
			cls.MemberByID[rt.newMemberID(c.Attr("name"))] =
				&MemberRef{Kind: memberProp, Index: len(cls.Properties)}
			cls.Properties = append(cls.Properties, c.Attr("name"))
		case "method":
			idx := len(cls.Methods)
			v.visitMethod(c, rt, cls)
			if cls.Methods[idx].Name != "" {
				cls.MemberByID[rt.newMemberID(cls.Methods[idx].Name)] =
					&MemberRef{Kind: memberMethod, Index: idx}
			}
		case "new":
			idx := len(cls.Methods)
			cls.ConstructorMap[c.Attr("name")] = idx
			v.visitMethod(c, rt, cls)
		case "delete":
			if cls.DeconstructorID == -1 {
				idx := len(cls.Methods)
				cls.DeconstructorID = idx
				v.visitMethod(c, rt, cls)
				// demo 6：<delete> 是 gc 回收时自动跑的析构函数，不注册
				// obj:delete 成员——没有手动删除入口，成员 id 也不为它分配。
			}
		}
	}
}

func (v *docVisitor) visitMethod(e *stml.Element, rt *Runtime, cls *ClassInfo) {
	m := &MethodInfo{Name: e.Attr("name")}
	if ps := e.Attr("params"); ps != "" {
		m.Params = strings.Fields(ps)
	}
	// pre_exports = 形参（属性不进：self:<属性> 走隐式导出，链接遍配对）。
	m.Program = v.compile(e.Text, e.TextLine, m.Params)
	// 装配期预计算整数索引：宿主函数 -> (槽位, 序号)；形参 -> 槽位。
	for _, kv := range rt.hostFuncMapSlice() {
		if slot, ok := m.Program.ExportOf(kv.name); ok {
			m.HostBinds = append(m.HostBinds, [2]int{slot, kv.idx})
		}
	}
	for _, p := range m.Params {
		slot, _ := m.Program.ExportOf(p)
		m.ParamSlots = append(m.ParamSlots, slot)
	}
	cls.Methods = append(cls.Methods, m)
}

func (v *docVisitor) visitFunc(e *stml.Element, rt *Runtime) {
	f := &FunctionInfo{Name: e.Attr("name")}
	if ps := e.Attr("params"); ps != "" {
		f.Params = strings.Fields(ps)
	}
	f.Program = v.compile(e.Text, e.TextLine, f.Params)
	for _, kv := range rt.hostFuncMapSlice() {
		if slot, ok := f.Program.ExportOf(kv.name); ok {
			f.HostBinds = append(f.HostBinds, [2]int{slot, kv.idx})
		}
	}
	for _, p := range f.Params {
		slot, _ := f.Program.ExportOf(p)
		f.ParamSlots = append(f.ParamSlots, slot)
	}
	rt.functions = append(rt.functions, f)
}

// linkSelfCalls 链接 self:<属性> / self:<方法名> / <类名>:<构造名> / obj:<名>，
// 并校验 self: 前缀的隐式导出全部链接成功。必须在全部类访问完之后跑。
func (v *docVisitor) linkSelfCalls(rt *Runtime) {
	for _, cls := range rt.classes {
		for _, m := range cls.Methods {
			for fi, prop := range cls.Properties {
				if slot, ok := m.Program.ExportOf("self:" + prop); ok {
					m.SelfProps = append(m.SelfProps, [2]int{slot, fi})
				}
			}
			for nm, memberID := range rt.memberNameMap {
				if nm == "" {
					continue
				}
				ref, ok := cls.MemberByID[memberID]
				if !ok || ref.Kind != memberMethod {
					continue // 不是本类的方法成员
				}
				if slot, ok := m.Program.ExportOf("self:" + nm); ok {
					m.SelfMethodBinds = append(m.SelfMethodBinds, [2]int{slot, memberID})
				}
			}
			// 方法体里的 <类名>:<构造名> / obj:<名>：方法有独立的 program，
			// 这些名字是它自己的隐式导出，每个 State 都要各自绑。描述符被
			// ExportBinds 引用着——Go GC 保证存活。
			for _, entry := range m.Program.Exports {
				colon := strings.Index(entry.Name, ":")
				if colon < 0 {
					continue
				}
				head, tail := entry.Name[:colon], entry.Name[colon+1:]
				var handle *basicvm.Handle
				if head == "obj" {
					mid, ok := rt.memberNameMap[tail]
					if !ok {
						continue // 不是任何已注册成员
					}
					handle = rt.objMgr.newMemberDesc(mid)
				} else {
					cid, ok := rt.classMap[head]
					if !ok {
						continue
					}
					ctorIdx, ok := rt.classes[cid].ConstructorMap[tail]
					if !ok {
						continue
					}
					handle = rt.objMgr.newCtorDesc(cid, ctorIdx)
				}
				m.ExportBinds = append(m.ExportBinds, ExportBind{Slot: entry.Index, Handle: handle})
			}
			for _, entry := range m.Program.Exports {
				if !strings.HasPrefix(entry.Name, "self:") {
					continue
				}
				linked := containsSlot(m.SelfProps, entry.Index) ||
					containsSlot(m.SelfMethodBinds, entry.Index)
				if !linked {
					panic("unlinked self member: " + entry.Name)
				}
			}
		}
	}
}

// hostFuncMapSlice map 无序，装配期排序保证 HostBinds 稳定（诊断输出可复现）。
func (rt *Runtime) hostFuncMapSlice() []struct {
	name string
	idx  int
} {
	out := []struct {
		name string
		idx  int
	}{}
	for nm, idx := range rt.hostFuncMap {
		out = append(out, struct {
			name string
			idx  int
		}{nm, idx})
	}
	for i := 0; i < len(out); i++ {
		for j := i + 1; j < len(out); j++ {
			if out[j].idx < out[i].idx {
				out[i], out[j] = out[j], out[i]
			}
		}
	}
	return out
}

func containsSlot(pairs [][2]int, slot int) bool {
	for _, p := range pairs {
		if p[0] == slot {
			return true
		}
	}
	return false
}

// compile 编译一份源码：pre_exports = 形参；失败即 panic（对齐 C++ 的装配期异常）。
func (v *docVisitor) compile(src string, startLine int, preExports []string) *stope.Program {
	lexer := stope.NewLexer(src)
	lexer.Line = startLine // 报错行号对齐原文档
	parser := stope.NewParser(lexer, nil)
	tree := &stope.Prog{}
	parser.ParseProgram(tree)
	if len(lexer.Errors) > 0 || len(parser.Errors) > 0 {
		msgs := ""
		for _, e := range lexer.Errors {
			msgs += "  lexer: " + e + "\n"
		}
		for _, e := range parser.Errors {
			msgs += "  parser: " + e + "\n"
		}
		panic(msgs)
	}
	compiler := stope.NewCompiler(nil)
	out := stope.NewProgram()
	if compiler.Compile(tree, out, preExports) != stope.RSuccess {
		msgs := ""
		for _, e := range compiler.Errors {
			msgs += "  compiler: " + e + "\n"
		}
		panic(msgs)
	}
	return out
}
