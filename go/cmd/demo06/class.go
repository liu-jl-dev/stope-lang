// class.go：类 / 方法 / 函数的静态结构与槽位装配（对应 cpp/demo/06-gc/ 的
// Class.* / Function.*）。与 demo 5 的差异：MethodInfo 多一个 ExportBinds。
package main

import (
	"stope"
	"stope/basicvm"
)

// ExportBind 方法体里的 <类名>:<构造名> / obj:<名> 描述符绑定。
// 方法有独立的 program，这些名字是它自己的隐式导出——每个 State 都要各自
// 绑。描述符被 MethodInfo.ExportBinds 引用着，Go GC 保证存活。
type ExportBind struct {
	Slot   int
	Handle *basicvm.Handle
}

type MethodInfo struct {
	Name    string
	Params  []string
	Program *stope.Program
	// 装配期预计算的整数索引：运行中不做任何按名查找。
	SelfProps       [][2]int // [槽位下标, 字段下标] —— 只含方法体实际引用的属性
	HostBinds       [][2]int // [槽位下标, 宿主函数序号]
	SelfMethodBinds [][2]int // [槽位下标, 成员 id]
	ExportBinds     []ExportBind
	ParamSlots      []int // Params[i] -> 变量槽位下标
}

func (m *MethodInfo) InitializeState(state *basicvm.State, selfObj *Object, args []any) {
	for _, p := range m.SelfProps {
		state.Variables[p[0]] = selfObj.Fields[p[1]] // 字段 -> 槽位
	}
	for k, slot := range m.ParamSlots {
		// 缺参静默：缺的槽位是 nil（已知局限，见 docs §10）
		if k < len(args) {
			state.Variables[slot] = args[k]
		} else {
			state.Variables[slot] = nil
		}
	}
}

type FunctionInfo struct {
	Name       string
	Params     []string
	Program    *stope.Program
	HostBinds  [][2]int
	ParamSlots []int
}

func (f *FunctionInfo) InitializeState(state *basicvm.State, args []any) {
	for k, slot := range f.ParamSlots {
		if k < len(args) {
			state.Variables[slot] = args[k]
		} else {
			state.Variables[slot] = nil
		}
	}
}

type ClassInfo struct {
	ID              int
	Name            string
	Properties      []string
	Methods         []*MethodInfo
	MemberByID      map[int]*MemberRef // 唯一的查找表
	ConstructorMap  map[string]int     // <new 名> -> methods 下标
	DeconstructorID int
}
