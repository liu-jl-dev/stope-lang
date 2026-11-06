// object_manager.go：obj:* 域的全部行为（对应 cpp/demo/06-gc/ 的
// ObjectManager.*）。
//
// 与 demo 5 的差异：没有 bindCache / live 表 / obj:delete——描述符每次
// bind 新建（Go GC 回收不可达者），对象生命期归 gc 分配器。
// 三个开口入口先 SafePoint()：安全点根同步，先于一切 DelRef。
package main

import (
	"fmt"

	"stope/basicvm"
)

type ObjectManager struct {
	runtime *Runtime
	alloc   *gcAllocator // gc 分配器（C++ 版住在 ObjectManager 里）
}

func newObjectManager(rt *Runtime) *ObjectManager {
	m := &ObjectManager{runtime: rt, alloc: newGcAllocator()}
	return m
}

// newObject new 业务对象。返回 nil = 顶到 MaxNodes（调用方 s.Error 报错）。
func (m *ObjectManager) newObject(clsID int) *basicvm.Handle {
	obj := m.alloc.newNode()
	if obj == nil {
		return nil
	}
	obj.ClassID = clsID
	obj.Fields = make([]any, len(m.runtime.classes[clsID].Properties))
	return &basicvm.Handle{Data: obj}
}

// 描述符：每次新建，不去重——demo 5 的 bindCache / 驱逐在 demo 6 里全部
// 消失，不可达的描述符由 Go GC 回收。
func (m *ObjectManager) newMemberDesc(memberID int) *basicvm.Handle {
	return &basicvm.Handle{Data: &MemberDesc{MemberID: memberID}}
}

func (m *ObjectManager) newCtorDesc(clsID, ctorIdx int) *basicvm.Handle {
	return &basicvm.Handle{Data: &CtorDesc{ClsID: clsID, CtorIdx: ctorIdx}}
}

// bind 绑定描述符：每次新建。Obj 是普通 Handle——描述符不持有对象（GC 管
// 不到 gc 对象），「正在执行方法」的对象由 Runtime.pinned 保活。
func (m *ObjectManager) bind(memberID int, objHandle *basicvm.Handle) *basicvm.Handle {
	return &basicvm.Handle{Data: &MemberDesc{MemberID: memberID, Obj: objHandle}}
}

// SafePoint 三个开口的公共前奏：安全点——先同步根集合，再做本次操作。
// 「引用计数归零 -> 立即级联释放」的可靠性由这条顺序保证（见 gc.go 头注释）。
func (m *ObjectManager) SafePoint() { m.alloc.syncRoots() }

// At obj:<名>[p] -> 绑定描述符。
func (m *ObjectManager) At(s *basicvm.State, handle *basicvm.Handle, key any) any {
	m.SafePoint()
	d := handle.Data
	md, ok := d.(*MemberDesc)
	if !ok {
		s.Error("no implement for container type. ") // 构造描述符不可 At
		return nil
	}
	objHandle, ok := key.(*basicvm.Handle)
	if !ok {
		s.Error("not an object. ")
		return nil
	}
	return m.bind(md.MemberID, objHandle)
}

// Assign obj:<属性>[p] = v -> 写字段（走 SetField：旧值减引用可级联，新值加引用）。
func (m *ObjectManager) Assign(s *basicvm.State, handle *basicvm.Handle, value any) {
	m.SafePoint()
	d := handle.Data.(*MemberDesc)
	if d.Obj == nil {
		s.Error("not assignable. ")
		return
	}
	obj := d.Obj.Data.(*Object)
	if obj.Dead {
		s.Error("use after gc. ") // 死对象不可达才判死，正常程序到不了这里
		return
	}
	cls := m.runtime.classes[obj.ClassID] // 第一层
	ref, ok := cls.MemberByID[d.MemberID]
	if !ok || ref.Kind != memberProp {
		s.Error("not assignable. ") // 该类没有这个属性 / 方法不可赋值
		return
	}
	m.alloc.SetField(obj, ref.Index, value) // 第二层
}

// CallMember obj:<名>[p](...) -> 调方法；<Class>:<New>(...) -> 构造。
// demo 6 没有 obj:delete(p)：生命期归 gc 管。
func (m *ObjectManager) CallMember(s *basicvm.State, handle *basicvm.Handle, args []any) any {
	m.SafePoint()
	switch d := handle.Data.(type) {
	case *CtorDesc:
		cls := m.runtime.classes[d.ClsID]
		objHandle := m.newObject(d.ClsID)
		if objHandle == nil {
			s.Error("too many gc nodes. ") // 顶到 MaxNodes：走正常错误通道
			return nil
		}
		// 构造器压帧：返回值是新对象本身（不走「弹帧回填」通道）。
		m.runtime.pushMethodFrame(cls.Methods[d.CtorIdx], objHandle.Data.(*Object), args, false)
		return objHandle
	case *MemberDesc:
		if d.Obj == nil {
			s.Error("method not bound. ") // demo 6 只支持 obj:<名>[p]() 形式
			return nil
		}
		obj := d.Obj.Data.(*Object)
		if obj.Dead {
			s.Error("use after gc. ")
			return nil
		}
		cls := m.runtime.classes[obj.ClassID] // 第一层：ClassID 选类
		ref, ok := cls.MemberByID[d.MemberID]
		if !ok || ref.Kind != memberMethod {
			s.Error("no method. ") // 该类没有这个方法（属性不可调）
			return nil
		}
		// 方法调用压帧：返回占位 nil——op_call 把它压到调用方栈顶，
		// 方法帧弹栈时（finishFrame）再回填真正的返回值。
		m.runtime.pushMethodFrame(cls.Methods[ref.Index], obj, args, true)
		return nil
	}
	s.Error("\"Call\" can only call a function. ")
	return nil
}

// RunDestructor gc 回收前回调（alloc.onFree）：跑 <delete>。字段还完整可读。
func (m *ObjectManager) RunDestructor(obj *Object) {
	cls := m.runtime.classes[obj.ClassID]
	if cls.DeconstructorID >= 0 {
		m.runtime.invokeMethod(cls.Methods[cls.DeconstructorID], obj, nil)
	}
}

func (m *ObjectManager) reportLive() {
	m.alloc.ReportAlive()
	if m.alloc.RootCount() == 0 {
		fmt.Println("[gc] no roots: everything reachable has been freed")
	} else {
		fmt.Printf("[gc] roots keep %d object(s) alive\n", m.alloc.RootCount())
	}
}
