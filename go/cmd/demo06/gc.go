// gc.go：对象分配器（对应 cpp/demo/06-gc/ 的 ObjectAllocator）。
//
// 引用计数的口径（与 C++ 版逐字对应，详见 cpp/docs/gc.md）：
//   - VM 对 Handle 的复制不通知宿主（Clear2/Copy 对 Handle 是无操作——缝的
//     设计），所以「栈/变量里此刻有哪些 Handle」只能靠扫描得知。
//   - RefCount = 字段引用（SetField 精确维护）+ 根引用（SyncRoots 同步）。
//   - 安全点 = 每个 obj:* 开口入口 + Collect 入口：扫描全部在册 State 的
//     Variables/Stack/Returns，Handle 一律算根，diff 出增减。**先加后删**——
//     删除触发的级联发生在刚扫描完、根集合新鲜的瞬间，此时计数归零必然
//     意味着 VM 侧再无 Handle，「立即级联释放」才可靠。
//
// Go 差异：没有 String/BinArr 引用计数（引擎管）；「释放」= 摘链 + 判死 +
// 清字段，内存交给 Go GC——没有 C++ 的 trash/FlushTrash（对象不会地址复用，
// 悬空指针不存在）。
package main

import (
	"fmt"

	"stope/basicvm"
)

// gcAllocator 对象分配器。
type gcAllocator struct {
	anchor      gcAnchor // 哨兵：anchor.next = 第一个对象
	rootSet     map[*Object]struct{}
	aliveCount  int
	gcTrigger   int  // 存活数到阈值，分配前先 Collect
	maxNodes    int  // gc 节点上限（Go 侧只计业务对象，描述符由 GC 管）；0 = 不限
	collecting  bool // Collect 重入守卫
	lastFreed   int  // 上次 Collect 释放数（诊断用）
	gatherRoots func() []*Object
	onFree      func(*Object)
}

func newGcAllocator() *gcAllocator {
	a := &gcAllocator{
		rootSet:   map[*Object]struct{}{},
		gcTrigger: 64,
	}
	a.anchor.prev = &a.anchor
	a.anchor.next = &a.anchor
	return a
}

// newNode 新对象挂到链尾。返回 nil = 顶到 maxNodes（开口里 s.Error 报错）。
func (a *gcAllocator) newNode() *Object {
	if !a.collecting && a.maxNodes != 0 && a.aliveCount >= a.maxNodes {
		a.Collect() // 顶到上限：先回收再判断——gc 还有机会救
	}
	if a.maxNodes != 0 && a.aliveCount >= a.maxNodes {
		return nil
	}
	obj := &Object{SelfID: nextSelfID()}
	obj.gcSetNext(&a.anchor)
	obj.gcSetPrev(a.anchor.gcPrev())
	a.anchor.gcPrev().gcSetNext(obj)
	a.anchor.gcSetPrev(obj)
	a.aliveCount++
	return obj
}

// ==================== 安全点：根同步 ====================

// syncRoots 先加后删的原因：删除可能级联释放——先删会把「恰好刚被本轮扫描
// 发现」的对象连同活引用一起级联释放。见 cpp/docs/gc.md §4。
func (a *gcAllocator) syncRoots() {
	if a.gatherRoots == nil || a.collecting {
		return // 收集期间跳过重扫：根集合保持 Collect 入口时的新鲜度
	}
	found := a.gatherRoots()
	foundSet := map[*Object]struct{}{}
	for _, o := range found {
		foundSet[o] = struct{}{}
	}

	// 先加：本轮新发现的根 +1（同一对象在多个槽位出现只记一次根）。
	for _, o := range found {
		if o.Dead {
			continue // 防御：死对象不可达
		}
		if _, ok := a.rootSet[o]; !ok {
			a.rootSet[o] = struct{}{}
			o.RefCount++
		}
	}
	// 后删：上一轮的根这轮没再出现 -> -1，归零立即级联。
	var stale []*Object
	for o := range a.rootSet {
		if _, ok := foundSet[o]; !ok {
			stale = append(stale, o)
		}
	}
	for _, o := range stale {
		delete(a.rootSet, o) // 无论死活都摘出根集合
		if o.Dead {
			continue // 同轮级联已收走
		}
		o.RefCount--
		if o.RefCount < 1 {
			a.freeNow(o) // 刚确认：VM 侧再无 Handle，立即级联释放
		}
	}
}

// ==================== 引用计数 ====================

// objOf 只有 Handle 且载荷是 *Object 才是对象引用；描述符由 GC 管。
func objOf(v any) *Object {
	if h, ok := v.(*basicvm.Handle); ok {
		if o, ok2 := h.Data.(*Object); ok2 {
			return o
		}
	}
	return nil
}

func (a *gcAllocator) addRef(v any) {
	o := objOf(v)
	if o != nil && !o.Dead {
		o.RefCount++
	}
}

func (a *gcAllocator) delRef(v any) {
	o := objOf(v)
	if o == nil || o.Dead {
		return
	}
	o.RefCount--
	if o.RefCount < 1 {
		a.freeNow(o) // 归零立即级联释放
	}
}

// SetField 字段写入：旧引用先减（可能级联），再挂新引用。Go 无 String 引用计数。
func (a *gcAllocator) SetField(obj *Object, index int, v any) {
	a.delRef(obj.Fields[index])
	obj.Fields[index] = v
	a.addRef(v)
}

// ==================== 释放（两条路径；Go 无需延迟删除） ====================

// freeNow 计数归零路径：字段引用递减，归零的子对象**级联**释放。
func (a *gcAllocator) freeNow(obj *Object) {
	if obj.Dead {
		return
	}
	if a.onFree != nil {
		a.onFree(obj) // <delete> 先跑：字段还完整可读
	}
	for _, v := range obj.Fields {
		if child := objOf(v); child != nil && !child.Dead {
			child.RefCount--
			if child.RefCount < 1 {
				a.freeNow(child) // 级联
			}
		}
	}
	obj.Fields = nil
	a.unlink(obj)
}

// freeSweep sweep 路径：字段引用只减计数**不级联**——真死透的子对象马上就轮到。
func (a *gcAllocator) freeSweep(obj *Object) {
	if obj.Dead {
		return
	}
	if a.onFree != nil {
		a.onFree(obj)
	}
	for _, v := range obj.Fields {
		if child := objOf(v); child != nil && !child.Dead && child.RefCount > 0 {
			child.RefCount--
		}
	}
	obj.Fields = nil
	a.unlink(obj)
}

func (a *gcAllocator) unlink(obj *Object) {
	obj.gcPrev().gcSetNext(obj.gcNext())
	obj.gcNext().gcSetPrev(obj.gcPrev())
	obj.Dead = true
	a.aliveCount--
}

// ==================== gc：标记清除 ====================

// markFrom 迭代式标记：沿字段里的 Handle 引用铺开，显式栈防深对象图爆栈。
func (a *gcAllocator) markFrom(root *Object) {
	if root.Dead || root.Mark != 0 {
		return
	}
	work := []*Object{root}
	root.Mark = 1
	for len(work) > 0 {
		o := work[len(work)-1]
		work = work[:len(work)-1]
		for _, v := range o.Fields {
			if c := objOf(v); c != nil && !c.Dead && c.Mark == 0 {
				c.Mark = 1
				work = append(work, c)
			}
		}
	}
}

// Collect 标记清除：循环引用的兜底，阈值触发。
func (a *gcAllocator) Collect() {
	if a.collecting {
		return // 析构里新建对象顶到阈值等重入：本次跳过，下个安全点再来
	}
	a.syncRoots() // 收集前根集合先刷新到最新（此刻还没置位）

	a.collecting = true
	a.lastFreed = 0

	// 标记：从全部根出发。
	for root := range a.rootSet {
		a.markFrom(root)
	}

	// 清除：先收集死对象再逐个回收——onFree（析构）可能读写字段。
	var doomed []*Object
	for h := a.anchor.gcNext(); h != GcNode(&a.anchor); h = h.gcNext() {
		if o := h.(*Object); o.Mark == 0 {
			doomed = append(doomed, o)
		}
	}
	for _, o := range doomed {
		if !o.Dead { // 前面的析构可能已经级联/重入收走了它
			a.freeSweep(o)
			a.lastFreed++
		}
	}

	// 清标记：只走还活着的链。
	for h := a.anchor.gcNext(); h != GcNode(&a.anchor); h = h.gcNext() {
		h.(*Object).Mark = 0
	}

	a.collecting = false
	if a.aliveCount*2 < 64 {
		a.gcTrigger = 64
	} else {
		a.gcTrigger = a.aliveCount * 2
	}
}

// DisposeAll 退出兜底（C++ 的 ~ObjectAllocator）：逐个跑析构、判死——剩余
// 对象（p）的「deleted: James」在这里打印；内存随后由 Go GC 回收。
func (a *gcAllocator) DisposeAll() {
	for a.anchor.next != GcNode(&a.anchor) {
		mo := a.anchor.next.(*Object)
		if a.onFree != nil {
			a.onFree(mo)
		}
		a.unlink(mo)
	}
}

// ReportAlive 诊断：走一遍链表，报告存活对象。
func (a *gcAllocator) ReportAlive() {
	objs := 0
	for h := a.anchor.gcNext(); h != GcNode(&a.anchor); h = h.gcNext() {
		objs++
	}
	fmt.Printf("[gc] alive: %d object(s), root set %d\n", objs, len(a.rootSet))
	for h := a.anchor.gcNext(); h != GcNode(&a.anchor); h = h.gcNext() {
		o := h.(*Object)
		fmt.Printf("  %d  class %d  refCount %d\n", o.SelfID, o.ClassID, o.RefCount)
	}
}

// RootCount 当前根集合大小（诊断用）。
func (a *gcAllocator) RootCount() int { return len(a.rootSet) }
