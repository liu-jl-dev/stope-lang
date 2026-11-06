// api.go：三个开口薄转发到 ObjectManager（对应 C++ 的 API.*）。
package main

import "stope/basicvm"

// DemoApi 内嵌 BaseApi（继承 OpTable 与默认 Handle 方法），覆写三个开口。
type DemoApi struct {
	*basicvm.BaseApi
	objMgr *ObjectManager
}

func (a *DemoApi) HandleAt(s *basicvm.State, handle *basicvm.Handle, key any) any {
	return a.objMgr.At(s, handle, key)
}

func (a *DemoApi) HandleAssign(s *basicvm.State, handle *basicvm.Handle, value any) {
	a.objMgr.Assign(s, handle, value)
}

func (a *DemoApi) HandleCall(s *basicvm.State, handle *basicvm.Handle, args []any) any {
	return a.objMgr.CallMember(s, handle, args)
}
