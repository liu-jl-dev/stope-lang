// runtime.go：静态结构 + 调用 + 入口绑定（对应 cpp/demo/06-gc/ 的 Runtime.*）。
package main

import (
	"fmt"
	"math"

	"stope"
	"stope/basicvm"
)

type Runtime struct {
	hostFuncs     []basicvm.HostFunction
	hostFuncMap   map[string]int // 名 -> hostFuncs 序号
	memberNameMap map[string]int // 成员名 -> 成员 id（跨类共享同名 id）
	classMap      map[string]int // 类名 -> 类 id（ExportBinds 按类名找构造器）
	memberIDNext  int
	functions     []*FunctionInfo
	classes       []*ClassInfo
	objMgr        *ObjectManager
	api           *DemoApi
	// gc 根扫描的范围 = 显式帧栈 frames（入口帧 + 压住的方法帧）+ liveStates
	// （只装 <delete> 析构的同步旁路 State，见 invokeMethod）。
	frames     []frame
	hadErrors  bool // 任一帧出错置位（错误已打印，供入口返回码用）
	liveStates []*basicvm.State
	// pinned 正在执行方法的对象（Go 版的「保活」机制）：C++ demo 6 靠绑定
	// 描述符的字段引用撑住 self，Go 的描述符不参与 gc，改由这个切片强引用
	// ——pushMethodFrame 压入、弹帧收尾弹出；invokeMethod（同步旁路）同样。
	pinned []*Object
}

// frame 一个执行帧：一个 State 加「弹栈时怎么收尾」的元数据。Runtime.frames
// 是显式帧栈，runSteps 每次只跑栈顶帧——方法调用压帧、返回弹帧，调用方在
// 栈里压住等返回值（对应 C++ demo 06 的 Frame）。
type frame struct {
	state       *basicvm.State
	method      *MethodInfo // nil = 入口帧（main）：弹栈不回写不回填
	selfObj     *Object     // 方法帧的 self（selfProps 回写目标）
	wantsReturn bool        // true = 弹栈时把 Returns[0] 回填调用方栈顶
}

func newRuntime() *Runtime {
	rt := &Runtime{
		hostFuncMap:   map[string]int{},
		memberNameMap: map[string]int{},
		classMap:      map[string]int{},
	}
	rt.objMgr = newObjectManager(rt)
	rt.api = &DemoApi{BaseApi: basicvm.NewApi(), objMgr: rt.objMgr}
	// gc 根扫描：分配器不认识 State，由 Runtime 供给。只有「Handle 载荷是
	// *Object」才算引用；描述符由 GC 管，不算。
	rt.objMgr.alloc.gatherRoots = func() []*Object { return rt.gatherRoots() }
	// 析构回调：对象被回收前跑 <delete>。
	rt.objMgr.alloc.onFree = func(obj *Object) { rt.objMgr.RunDestructor(obj) }
	return rt
}

func (rt *Runtime) gatherRoots() []*Object {
	var out []*Object
	scan := func(s *basicvm.State) {
		for _, arr := range [][]any{s.Variables, s.Stack, s.Returns} {
			for _, v := range arr {
				if o := objOf(v); o != nil {
					out = append(out, o)
				}
			}
		}
	}
	for _, f := range rt.frames {
		scan(f.state)
	}
	for _, s := range rt.liveStates {
		scan(s)
	}
	for _, o := range rt.pinned {
		out = append(out, o)
	}
	return out
}

func (rt *Runtime) trackState(s *basicvm.State) { rt.liveStates = append(rt.liveStates, s) }

func (rt *Runtime) untrackState(s *basicvm.State) {
	// 从后往前找：调用栈是 LIFO，最后一个匹配就是要拆的那个。
	for i := len(rt.liveStates) - 1; i >= 0; i-- {
		if rt.liveStates[i] == s {
			rt.liveStates = append(rt.liveStates[:i], rt.liveStates[i+1:]...)
			return
		}
	}
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

// ---------- 显式帧栈：把 State 显式放在一个栈里，驱动循环只跑栈顶帧 ----------
// 调用栈从 Go goroutine 调用栈搬进 frames 成员：方法调用压帧、返回弹帧，
// 调用方在栈里压住等返回值。换来 runSteps(maxSteps)「每帧限步」与 runAll()
// 「一口气跑完」两种驱动，随时可切。

// pushEntryFrame 装配入口函数并压帧：宿主函数、构造器描述符、obj:* 成员描
// 述符绑进导出槽位。demo 6 没有 obj:delete——生命期归 gc 管，<delete> 是
// 回收时自动跑的析构。
func (rt *Runtime) pushEntryFrame(entry *FunctionInfo) {
	state := &basicvm.State{}
	state.SetApi(rt.api)
	state.SetProgram(entry.Program)
	entry.InitializeState(state, nil)
	rt.bindEntry(state, entry)
	rt.frames = append(rt.frames, frame{state: state})
}

// setupMethodState 装配方法 State（pushMethodFrame / invokeMethod 共用）。
func (rt *Runtime) setupMethodState(m *MethodInfo, obj *Object, args []any, state *basicvm.State) {
	state.SetApi(rt.api)
	state.SetProgram(m.Program)
	m.InitializeState(state, obj, args)
	for _, b := range m.HostBinds {
		state.Variables[b[0]] = rt.hostFuncs[b[1]]
	}
	// 方法体里的 <类名>:<构造名> / obj:<名> 描述符：装配期已预算好
	// (槽位, Handle)，逐个拷进槽位。
	for _, b := range m.ExportBinds {
		state.Variables[b.Slot] = b.Handle
	}
	// self:<方法名> 槽位绑 self 的绑定方法描述符——每次新建（不去重）。
	for _, b := range m.SelfMethodBinds {
		state.Variables[b[0]] = rt.objMgr.bind(b[1], &basicvm.Handle{Data: obj})
	}
}

// pushMethodFrame 压入方法帧，不执行——runSteps 自然切到栈顶帧。调用方
// （call 开口的发起方）停在 Call 的下一条；开口返回的占位 nil 会被 op_call
// 压到调用方栈顶，弹帧收尾时用真正的返回值覆盖。self 进 pinned 保活。
func (rt *Runtime) pushMethodFrame(m *MethodInfo, obj *Object, args []any, wantsReturn bool) {
	state := &basicvm.State{}
	rt.setupMethodState(m, obj, args, state)
	rt.frames = append(rt.frames, frame{state: state, method: m, selfObj: obj, wantsReturn: wantsReturn})
	rt.pinned = append(rt.pinned, obj)
}

// runSteps 每帧限步驱动：只跑栈顶帧，至多 maxSteps 条指令；帧弹栈（Return /
// 指令流走完 / 出错中止当前函数）不消耗步数。返回 false = 帧栈已空。
func (rt *Runtime) runSteps(maxSteps int) bool {
	for maxSteps > 0 && len(rt.frames) > 0 {
		s := rt.frames[len(rt.frames)-1].state
		if s.I >= len(s.Program.Opcodes) {
			rt.finishTopFrame() // Return 已把返回值备好；弹栈不消耗步数
			continue
		}
		if s.Step() != stope.RSuccess {
			rt.finishTopFrame() // 运行期错误：只中止当前函数，调用方继续
			continue
		}
		maxSteps--
	}
	return len(rt.frames) > 0
}

// runAll 直接执行：一口气跑到帧栈清空。与 runSteps 随时可切。
func (rt *Runtime) runAll() {
	for rt.runSteps(math.MaxInt32) {
	}
}

// finishTopFrame 摘出栈顶帧并收尾。
func (rt *Runtime) finishTopFrame() {
	f := rt.frames[len(rt.frames)-1]
	rt.frames = rt.frames[:len(rt.frames)-1]
	rt.finishFrame(&f)
}

// finishFrame 帧收尾：错误打印、self: 槽位写回字段（走 SetField：引用计数
// 照常维护）、返回值回填调用方栈顶（op_call 已把占位 nil 压到那里，覆盖即可）。
func (rt *Runtime) finishFrame(f *frame) {
	for _, e := range f.state.Errors {
		fmt.Println("  vm: " + e)
		rt.hadErrors = true
	}
	if f.method == nil {
		return // 入口帧：没有 selfProps / 返回值
	}
	rt.pinned = rt.pinned[:len(rt.pinned)-1] // 与 pushMethodFrame 配对
	// 返回前把 self: 槽位写回字段——selfProps 只含方法体实际引用的属性。
	for _, p := range f.method.SelfProps {
		rt.objMgr.alloc.SetField(f.selfObj, p[1], f.state.Variables[p[0]])
	}
	// 回填调用方栈顶（wantsReturn 帧）。构造器帧返回的是新对象本身，不走这里。
	if f.wantsReturn && len(rt.frames) > 0 && len(f.state.Returns) > 0 {
		caller := rt.frames[len(rt.frames)-1].state
		caller.Stack[len(caller.Stack)-1] = f.state.Returns[0]
	}
}

// invokeMethod 同步执行整个方法（<delete> 析构路径）：装配 + Run + 收尾。
// 析构在级联释放 / sweep 的中间被调用，跑完后调用方还要清字段——不能让出
// 执行权。析构里再调方法也走这条路：压帧没人跑（此刻正停在 Step 中间）。
func (rt *Runtime) invokeMethod(m *MethodInfo, obj *Object, args []any) any {
	state := &basicvm.State{}
	rt.setupMethodState(m, obj, args, state)
	rt.pinned = append(rt.pinned, obj)
	rt.trackState(state)
	state.Run()
	rt.untrackState(state)
	rt.pinned = rt.pinned[:len(rt.pinned)-1]
	for _, e := range state.Errors {
		fmt.Println("  vm: " + e)
		rt.hadErrors = true
	}
	// 返回前把 self: 槽位写回字段（走 SetField：引用计数照常维护）。
	for _, p := range m.SelfProps {
		rt.objMgr.alloc.SetField(obj, p[1], state.Variables[p[0]])
	}
	if len(state.Returns) > 0 {
		return state.Returns[0]
	}
	return nil
}

// bindEntry 装配入口函数：宿主函数、构造器描述符、obj:* 成员描述符绑进导出
// 槽位。demo 6 没有 obj:delete——生命期归 gc 管，<delete> 是回收时自动跑的
// 析构。按名只发生在这里（装配期），state.Run() 期间零按名查找。
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
				continue // <delete> 无名
			}
			if _, isCtor := cls.ConstructorMap[m.Name]; isCtor {
				continue // 构造器不占 obj: 名
			}
			rt.bindExport(state, entry, "obj:"+m.Name,
				rt.objMgr.newMemberDesc(rt.newMemberID(m.Name)))
		}
	}
}

func (rt *Runtime) bindExport(state *basicvm.State, entry *FunctionInfo, nm string, handle *basicvm.Handle) {
	if slot, ok := entry.Program.ExportOf(nm); ok {
		state.Variables[slot] = handle
	}
}
