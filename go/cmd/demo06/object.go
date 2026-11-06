// object.go：对象模型 —— 业务对象与描述符（对应 cpp/demo/06-gc/ 的 Object.*）。
package main

import "stope/basicvm"

var selfIDNext int64 // 诊断打印用（C++ 打指针；Go 侧用自增 id 替代）

func nextSelfID() int64 {
	selfIDNext++
	return selfIDNext
}

// MemberKind 成员种类（对应 C++ 的 kMemberProp/Method；demo 6 无 delete）。
type MemberKind int

const (
	memberProp MemberKind = iota
	memberMethod
)

// GcNode 链表节点的鸭子类型：Object 与 gcAnchor 都实现它（Go 需要显式契约）。
type GcNode interface {
	gcPrev() GcNode
	gcSetPrev(GcNode)
	gcNext() GcNode
	gcSetNext(GcNode)
}

// gcHeader 链表头：内嵌进 Object / gcAnchor，方法提升即 GcNode 契约
// （Go 不能同名字段+方法，内嵌是标准解法）。
type gcHeader struct {
	prev GcNode // 循环双向链表（哨兵是 gcAnchor）
	next GcNode
}

func (h *gcHeader) gcPrev() GcNode     { return h.prev }
func (h *gcHeader) gcSetPrev(n GcNode) { h.prev = n }
func (h *gcHeader) gcNext() GcNode     { return h.next }
func (h *gcHeader) gcSetNext(n GcNode) { h.next = n }

// Object 业务对象。gc 决定「何时判死」：<delete> 在判死时运行、时机确定；
// 节点摘链后不可达，内存交给 Go GC——没有 C++ 的 delete/trash（对象不会
// 地址复用，悬空指针不存在）。gc 头内嵌在结构体里。
type Object struct {
	SelfID   int64 // 诊断打印用（C++ 打指针；Go 侧用自增 id 替代）
	ClassID  int
	Fields   []any // 下标对齐 ClassInfo.Properties
	gcHeader       // 循环双向链表（哨兵是 gcAnchor）
	RefCount int64 // 字段引用（精确）+ 根引用（安全点同步）
	Mark     int   // 0 未标记 / 1 已标记
	Dead     bool  // 已摘链判死：级联与 sweep 的回收名单重叠时防重复处理
}

// gcAnchor 链表哨兵：不占对象编号。
type gcAnchor struct {
	gcHeader
}

type MemberRef struct {
	Kind  MemberKind
	Index int // 进 Properties 或 Methods
}

// MemberDesc 描述符（Go GC 管理，不进 gc 链）。绑定描述符的 Obj 是普通
// Handle——不持有对象：gc 只认「State 可达 + 字段引用 + 正在执行方法」。
type MemberDesc struct {
	MemberID int
	Obj      *basicvm.Handle // nil = 未绑定
}

type CtorDesc struct {
	ClsID   int
	CtorIdx int
}
