// doc_visitor.go：STML 文档 -> 类与函数，含编译、索引预算与 self 链接
// （对应 C++ 的 DocVisitor.*）。
package main

import (
	"fmt"
	"strings"

	"stope"
	"stope/stml"
)

// docVisitor 装配期失败用 panic 上传（对齐 C++ 的 throw；main 里 recover 接住）。
type docVisitor struct{}

func (v *docVisitor) visitDoc(root *stml.Element, rt *Runtime) {
	for _, e := range root.Children {
		if e.Tag == "class" {
			v.visitClass(e, rt)
		} else if e.Tag == "func" {
			v.visitFunc(e, rt)
		}
	}
	v.linkSelfCalls(rt)
}

func (v *docVisitor) visitClass(e *stml.Element, rt *Runtime) {
	cls := rt.newClass()
	cls.Name = e.Attr("name")
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
				cls.MemberByID[rt.newMemberID("delete")] =
					&MemberRef{Kind: memberDelete, Index: idx}
			}
		}
	}
}

func (v *docVisitor) visitMethod(e *stml.Element, rt *Runtime, cls *ClassInfo) {
	m := &MethodInfo{Name: e.Attr("name")}
	if e.Attr("params") != "" {
		m.Params = strings.Fields(e.Attr("params"))
	}
	// pre_exports = 形参（属性不进：self:<属性> 走隐式导出，链接遍配对）。
	m.Program = v.compile(e.Text, e.TextLine, m.Params)
	// 装配期预计算整数索引：宿主函数 -> (槽位, 序号)；形参 -> 槽位。
	for nm, idx := range rt.hostFuncMap {
		if slot, ok := m.Program.ExportOf(nm); ok {
			m.HostBinds = append(m.HostBinds, [2]int{slot, idx})
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
	if e.Attr("params") != "" {
		f.Params = strings.Fields(e.Attr("params"))
	}
	f.Program = v.compile(e.Text, e.TextLine, f.Params)
	for nm, idx := range rt.hostFuncMap {
		if slot, ok := f.Program.ExportOf(nm); ok {
			f.HostBinds = append(f.HostBinds, [2]int{slot, idx})
		}
	}
	for _, p := range f.Params {
		slot, _ := f.Program.ExportOf(p)
		f.ParamSlots = append(f.ParamSlots, slot)
	}
	rt.functions = append(rt.functions, f)
}

// linkSelfCalls 链接 self:<属性> 与 self:<方法名>，并校验方法里 self: 前缀的
// 隐式导出全部链接成功（拼写错误装配期拦下）。必须在全部类访问完之后跑：方法
// 可以引用文档里后定义的成员。<func> 里的 self: 有意不校验（见 docs §10）。
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
					continue // <delete> 无名
				}
				ref, ok := cls.MemberByID[memberID]
				if !ok || ref.Kind != memberMethod {
					continue // 不是本类的方法成员
				}
				if slot, ok := m.Program.ExportOf("self:" + nm); ok {
					m.SelfMethodBinds = append(m.SelfMethodBinds, [2]int{slot, memberID})
				}
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
		for _, e := range lexer.Errors {
			fmt.Println("  lexer: " + e)
		}
		for _, e := range parser.Errors {
			fmt.Println("  parser: " + e)
		}
		panic("parse failed")
	}
	compiler := stope.NewCompiler(nil)
	out := stope.NewProgram()
	if compiler.Compile(tree, out, preExports) != stope.RSuccess {
		for _, e := range compiler.Errors {
			fmt.Println("  compiler: " + e)
		}
		panic("compile failed")
	}
	return out
}
