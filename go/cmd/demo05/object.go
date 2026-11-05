// object.go：对象模型 —— 业务对象与描述符（对应 C++ 的 Object.*）。
package main

import "stope/basicvm"

// MemberKind 成员种类（对应 C++ 的 kMemberProp/Method/Delete）。
type MemberKind int

const (
	memberProp MemberKind = iota
	memberMethod
	memberDelete
)

// Object 业务对象。GC 管内存：deleted 标记 + 使用检测模拟手动管理的纪律。
type Object struct {
	ClassID int
	Fields  []any // 下标对齐 ClassInfo.Properties
	Deleted bool
}

type MemberRef struct {
	Kind  MemberKind
	Index int // 进 Properties 或 Methods
}

// MemberDesc 成员描述符：MemberID + Obj（绑定后才有，Handle）。
type MemberDesc struct {
	MemberID int
	Obj      *basicvm.Handle // nil = 未绑定
}

type CtorDesc struct {
	ClsID   int
	CtorIdx int
}
