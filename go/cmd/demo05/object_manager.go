// object_manager.go：obj:* 域的全部行为（对应 C++ 的 ObjectManager.*）。
package main

import (
	"fmt"

	"stope/basicvm"
)

type ObjectManager struct {
	runtime *Runtime
	live    map[*Object]struct{} // delete 后移除
	// 去重缓存：对象 -> (成员 id -> 绑定描述符)。绑定描述符只存这两样且创建后
	// 不可变，同一绑定永远等价；delete 时整组驱逐，不可达的描述符交给 GC。
	bindCache map[*Object]map[int]*MemberDesc
}

func newObjectManager(rt *Runtime) *ObjectManager {
	return &ObjectManager{
		runtime:   rt,
		live:      map[*Object]struct{}{},
		bindCache: map[*Object]map[int]*MemberDesc{},
	}
}

func (m *ObjectManager) newObject(clsID int) *basicvm.Handle {
	obj := &Object{ClassID: clsID}
	obj.Fields = make([]any, len(m.runtime.classes[clsID].Properties))
	m.live[obj] = struct{}{}
	return &basicvm.Handle{Data: obj}
}

func (m *ObjectManager) newMemberDesc(memberID int) *basicvm.Handle {
	return &basicvm.Handle{Data: &MemberDesc{MemberID: memberID}}
}

func (m *ObjectManager) newCtorDesc(clsID, ctorIdx int) *basicvm.Handle {
	return &basicvm.Handle{Data: &CtorDesc{ClsID: clsID, CtorIdx: ctorIdx}}
}

// bind 绑定（创建即去重）。C++ 版还有 freeDescs 复用池；这里不需要 —— 驱逐后
// 不可达的描述符由 GC 回收，池的存在意义被语言机制替掉了。
func (m *ObjectManager) bind(memberID int, objHandle *basicvm.Handle) *basicvm.Handle {
	obj := objHandle.Data.(*Object)
	byMember, ok := m.bindCache[obj]
	if !ok {
		byMember = map[int]*MemberDesc{}
		m.bindCache[obj] = byMember
	}
	if hit, ok := byMember[memberID]; ok {
		return &basicvm.Handle{Data: hit} // 命中：复用
	}
	d := &MemberDesc{MemberID: memberID, Obj: objHandle}
	byMember[memberID] = d
	return &basicvm.Handle{Data: d}
}

// At obj:<名>[p] -> 绑定描述符（属性引用与绑定方法都从这里出发）。
func (m *ObjectManager) At(s *basicvm.State, handle *basicvm.Handle, key any) any {
	d := handle.Data
	if _, isCtor := d.(*CtorDesc); isCtor {
		s.Error("no implement for container type. ")
		return nil
	}
	md := d.(*MemberDesc)
	objHandle, ok := key.(*basicvm.Handle)
	if !ok {
		s.Error("not an object. ")
		return nil
	}
	return m.bind(md.MemberID, objHandle)
}

// Assign obj:<属性>[p] = v -> 写字段。两层整数查询：对象自己的 ClassID 选类，
// MemberByID 查 MemberRef——同名成员在各类里落在不同位置也各归各。
func (m *ObjectManager) Assign(s *basicvm.State, handle *basicvm.Handle, value any) {
	d := handle.Data.(*MemberDesc)
	if d.Obj == nil {
		s.Error("not assignable. ")
		return
	}
	obj := d.Obj.Data.(*Object)
	if obj.Deleted {
		s.Error("use after free. ") // Go 无悬空指针：删除标记替代 UB
		return
	}
	cls := m.runtime.classes[obj.ClassID] // 第一层
	ref, ok := cls.MemberByID[d.MemberID]
	if !ok || ref.Kind != memberProp {
		s.Error("not assignable. ") // 该类没有这个成员 / 方法不可赋值
		return
	}
	obj.Fields[ref.Index] = value // 第二层：MemberRef.Index 即字段下标
}

// CallMember obj:<名>[p](...) -> 调方法；obj:<名>(...) 直接调（delete 走这里，
// 对象在实参里）；<Class>:<New>(...) -> 构造。
func (m *ObjectManager) CallMember(s *basicvm.State, handle *basicvm.Handle, args []any) any {
	switch d := handle.Data.(type) {
	case *CtorDesc:
		cls := m.runtime.classes[d.ClsID]
		objHandle := m.newObject(d.ClsID)
		m.runtime.invokeMethod(cls.Methods[d.CtorIdx], objHandle.Data.(*Object), args)
		return objHandle
	case *MemberDesc:
		// kind 由 MemberByID 查表揭晓；类来自绑定对象或实参对象。
		objHandle := d.Obj
		if objHandle == nil {
			if len(args) > 0 {
				if h, ok := args[0].(*basicvm.Handle); ok {
					objHandle = h // obj:delete(p) 实参形式
				}
			}
			if objHandle == nil {
				if len(args) > 0 {
					s.Error("not an object. ") // 实参不是对象
				} else {
					s.Error("method not bound. ") // obj:<方法> 未带 [对象]
				}
				return nil
			}
		}
		obj := objHandle.Data.(*Object)
		if obj.Deleted {
			s.Error("use after free. ")
			return nil
		}
		cls := m.runtime.classes[obj.ClassID] // 第一层
		ref, ok := cls.MemberByID[d.MemberID]
		if !ok {
			s.Error("no method. ") // 该类没有这个成员
			return nil
		}
		if ref.Kind == memberDelete {
			m.deleteObj(s, obj) // 绑定形式与实参形式在此收敛
			return nil
		}
		if ref.Kind != memberMethod {
			s.Error("\"Call\" can only call a function. ") // 属性不可调
			return nil
		}
		return m.runtime.invokeMethod(cls.Methods[ref.Index], obj, args)
	}
	s.Error("\"Call\" can only call a function. ")
	return nil
}

// deleteObj 跑 <delete>（可读写字段）-> 驱逐绑定描述符 -> 删除标记。双重 delete 拦下。
func (m *ObjectManager) deleteObj(s *basicvm.State, obj *Object) {
	if _, ok := m.live[obj]; !ok {
		s.Error("double delete. ")
		return
	}
	delete(m.live, obj)
	cls := m.runtime.classes[obj.ClassID]
	if cls.DeconstructorID >= 0 {
		m.runtime.invokeMethod(cls.Methods[cls.DeconstructorID], obj, nil)
	}
	delete(m.bindCache, obj) // 整组驱逐；不可达的描述符由 GC 回收
	obj.Deleted = true       // 内存回收时机交给 GC；之后使用即 use after free
}

func (m *ObjectManager) reportLive() {
	if len(m.live) == 0 {
		fmt.Println("[objects] all freed")
	} else {
		fmt.Printf("[objects] %d alive\n", len(m.live))
	}
	cached := 0
	for _, byMember := range m.bindCache {
		cached += len(byMember)
	}
	// 差异：C++ 打 allocated/pooled 两个数（复用池）；这里只有缓存里仍被
	// 引用的绑定描述符，池被 GC 替代了。
	fmt.Printf("[bind-cache] %d entries\n", cached)
}
