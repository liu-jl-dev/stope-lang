// runtime.go：静态结构 + 调用 + 入口绑定（对应 C++ 的 Runtime.*）。
package main

import (
	"fmt"

	"stope/basicvm"
)

type Runtime struct {
	hostFuncs     []basicvm.HostFunction
	hostFuncMap   map[string]int // 名 -> hostFuncs 序号
	memberNameMap map[string]int // 成员名 -> 成员 id（跨类共享同名 id）
	memberIDNext  int
	functions     []*FunctionInfo
	classes       []*ClassInfo
	objMgr        *ObjectManager
	api           *DemoApi
}

func newRuntime() *Runtime {
	rt := &Runtime{
		hostFuncMap:   map[string]int{},
		memberNameMap: map[string]int{},
	}
	rt.objMgr = newObjectManager(rt)
	rt.api = &DemoApi{BaseApi: basicvm.NewApi(), objMgr: rt.objMgr}
	return rt
}

func (rt *Runtime) newMemberID(nm string) int {
	if id, ok := rt.memberNameMap[nm]; ok {
		return id
	}
	id := rt.memberIDNext
	rt.memberIDNext++
	rt.memberNameMap[nm] = id
	return id
}

func (rt *Runtime) newClass() *ClassInfo {
	c := &ClassInfo{
		ID:              len(rt.classes),
		MemberByID:      map[int]*MemberRef{},
		ConstructorMap:  map[string]int{},
		DeconstructorID: -1,
	}
	rt.classes = append(rt.classes, c)
	return c
}

func (rt *Runtime) findFunction(nm string) *FunctionInfo {
	for _, f := range rt.functions {
		if f.Name == nm {
			return f
		}
	}
	return nil
}

func (rt *Runtime) addHostFunction(nm string, fn basicvm.HostFunction) {
	rt.hostFuncMap[nm] = len(rt.hostFuncs)
	rt.hostFuncs = append(rt.hostFuncs, fn)
}

// invokeMethod 方法调用：每层调用一个临时 State，随返回销毁 —— 嵌套调用就是
// Go 的递归栈。Runtime 不保存调用栈（demo 6 做根扫描时才需要）。
func (rt *Runtime) invokeMethod(m *MethodInfo, obj *Object, args []any) any {
	state := &basicvm.State{}
	state.SetApi(rt.api)
	state.SetProgram(m.Program)
	m.InitializeState(state, obj, args)
	for _, b := range m.HostBinds {
		state.Variables[b[0]] = rt.hostFuncs[b[1]]
	}
	// self:<方法名> 槽位绑 self 的绑定方法描述符——创建即绑定 self，
	// self:Greet() 无需 [对象]；去重缓存保证递归调用不重复分配。
	for _, b := range m.SelfMethodBinds {
		state.Variables[b[0]] = rt.objMgr.bind(b[1], &basicvm.Handle{Data: obj})
	}
	state.Run()
	for _, e := range state.Errors {
		fmt.Println("  vm: " + e)
	}
	// 返回前把 self: 槽位写回字段（只写实际引用的那几个）。
	for _, p := range m.SelfProps {
		obj.Fields[p[1]] = state.Variables[p[0]]
	}
	if len(state.Returns) > 0 {
		return state.Returns[0]
	}
	return nil
}

// bindEntry 装配入口函数：宿主函数、构造器描述符、obj:* 成员描述符绑进导出槽位。
// 按名只发生在这里（装配期），state.Run() 期间零按名查找。
func (rt *Runtime) bindEntry(state *basicvm.State, entry *FunctionInfo) {
	for _, b := range entry.HostBinds {
		state.Variables[b[0]] = rt.hostFuncs[b[1]]
	}
	for _, cls := range rt.classes {
		for nm, ctorIdx := range cls.ConstructorMap {
			rt.bindExport(state, entry, cls.Name+":"+nm,
				rt.objMgr.newCtorDesc(cls.ID, ctorIdx))
		}
		for _, prop := range cls.Properties {
			rt.bindExport(state, entry, "obj:"+prop,
				rt.objMgr.newMemberDesc(rt.newMemberID(prop)))
		}
		for _, m := range cls.Methods {
			if m.Name == "" {
				continue // <delete> 走 obj:delete
			}
			if _, isCtor := cls.ConstructorMap[m.Name]; isCtor {
				continue // 构造器不占 obj: 名
			}
			rt.bindExport(state, entry, "obj:"+m.Name,
				rt.objMgr.newMemberDesc(rt.newMemberID(m.Name)))
		}
		if cls.DeconstructorID >= 0 {
			rt.bindExport(state, entry, "obj:delete",
				rt.objMgr.newMemberDesc(rt.newMemberID("delete")))
		}
	}
}

func (rt *Runtime) bindExport(state *basicvm.State, entry *FunctionInfo, nm string, handle *basicvm.Handle) {
	if slot, ok := entry.Program.ExportOf(nm); ok {
		state.Variables[slot] = handle
	}
}
