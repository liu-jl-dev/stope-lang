// gc.js：对象分配器（对应 cpp/demo/06-gc/ 的 ObjectAllocator）。
//
// 引用计数的口径（与 C++ 版逐字对应，详见 cpp/docs/gc.md）：
//   * VM 对 Handle 的复制不通知宿主（Clear2/Copy 对 Handle 是无操作——缝的
//     设计），所以「栈/变量里此刻有哪些 Handle」只能靠扫描得知。
//   * refCount = 字段引用（setField 精确维护）+ 根引用（syncRoots 同步）。
//   * 安全点 = 每个 obj:* 开口入口 + collect 入口：扫描全部在册 State 的
//     variables/stack/returns，Handle 一律算根，diff 出增减。**先加后删**——
//     删除触发的级联发生在刚扫描完、根集合新鲜的瞬间，此时计数归零必然
//     意味着 VM 侧再无 Handle，「立即级联释放」才可靠。
// JS 差异：没有 String/BinArr 引用计数（引擎管）；「释放」= 摘链 + 判死 +
// 清字段，内存回收交给引擎——所以没有 C++ 的 trash / FlushTrash（JS 对象
// 不会地址复用，悬空指针不存在）。

import { BasicVM } from '../../src/index.js'
import { GcAnchor, MyObject } from './object.js'

export class ObjectAllocator {
  constructor() {
    this.anchor = new GcAnchor() // 哨兵：anchor.gcNext = 第一个对象
    this.anchor.gcPrev = this.anchor
    this.anchor.gcNext = this.anchor
    this.rootSet = new Set() // 当前认定的根对象集合
    this.aliveCount = 0 // 链上真实对象数（触发器用）
    this.gcTrigger = 64 // 存活数到阈值，分配前先 Collect
    this.maxNodes = 0 // gc 节点上限（JS 侧只计业务对象，描述符由引擎管）；
    // 顶到上限先 Collect 仍放不下则分配失败。0 = 不限
    this.collecting = false // Collect 重入守卫
    this.lastFreed = 0 // 上次 Collect 释放数（诊断用）
    // 安全点根扫描：宿主注册——枚举全部在册 State 的 variables/stack/returns
    // 与正在执行方法的对象，把 MyObject 塞进参数。分配器不认识 State。
    this.gatherRoots = null
    // 回收前回调：跑 <delete>（析构）。析构体可以读写自己的字段、调方法。
    this.onFree = null
  }

  // 新对象挂到链尾。返回 null = 顶到 maxNodes（开口里 s.Error 报错）。
  newObject() {
    if (!this.collecting && this.maxNodes !== 0 && this.aliveCount >= this.maxNodes) {
      this.collect() // 顶到上限：先回收再判断——gc 还有机会救
    }
    if (this.maxNodes !== 0 && this.aliveCount >= this.maxNodes) return null
    const obj = new MyObject()
    obj.gcNext = this.anchor
    obj.gcPrev = this.anchor.gcPrev
    this.anchor.gcPrev.gcNext = obj
    this.anchor.gcPrev = obj
    this.aliveCount += 1
    return obj
  }

  // ==================== 安全点：根同步 ====================

  // 先加后删的原因：删除可能级联释放。假设先删后加——根集合里过期的引用
  // 被摘除时，那个对象可能「恰好刚被本轮扫描发现在另一个 State 里」，先删
  // 会把它连同还活着的引用一起级联释放，后加就是把悬空指针登记成根。
  syncRoots() {
    if (this.gatherRoots === null || this.collecting) {
      return // 收集期间跳过重扫：根集合保持 Collect 入口时的新鲜度
    }
    const found = this.gatherRoots()

    // 先加：本轮新发现的根 +1（同一对象在多个槽位出现只记一次根）。
    for (const o of found) {
      if (o.dead) continue // 防御：死对象不可达，不该出现在扫描结果里
      if (!this.rootSet.has(o)) {
        this.rootSet.add(o)
        o.refCount += 1
      }
    }
    // 后删：上一轮的根这轮没再出现 -> -1，归零立即级联。
    const stale = []
    for (const o of this.rootSet) {
      if (!found.includes(o)) stale.push(o)
    }
    for (const o of stale) {
      this.rootSet.delete(o) // 无论死活都摘出根集合
      if (o.dead) continue // 同轮级联已收走
      o.refCount -= 1
      if (o.refCount < 1) this.freeNow(o) // 刚确认：VM 侧再无 Handle，立即级联
    }
  }

  // ==================== 引用计数 ====================

  // 只有 Handle 且载荷是 MyObject 才是对象引用；描述符由引擎管。
  objOf(v) {
    if (v instanceof BasicVM.Handle && v.data instanceof MyObject) return v.data
    return null
  }

  addRef(v) {
    const o = this.objOf(v)
    if (o !== null && !o.dead) o.refCount += 1
  }

  delRef(v) {
    const o = this.objOf(v)
    if (o === null || o.dead) return
    o.refCount -= 1
    if (o.refCount < 1) this.freeNow(o) // 归零立即级联释放
  }

  // 字段写入：旧引用先减（可能级联释放旧目标），再挂新引用。JS 无 String
  // 引用计数，无需 Clear2。
  setField(obj, index, v) {
    this.delRef(obj.fields[index])
    obj.fields[index] = v
    this.addRef(v)
  }

  // ==================== 释放（两条路径；JS 无需延迟删除） ====================

  // 计数归零路径：字段里的 Handle 引用递减，归零的子对象**级联**释放。
  freeNow(obj) {
    if (obj.dead) return
    if (this.onFree !== null) this.onFree(obj) // <delete> 先跑：字段还完整可读
    for (const v of obj.fields) {
      const child = this.objOf(v)
      if (child !== null && !child.dead) {
        child.refCount -= 1
        if (child.refCount < 1) this.freeNow(child) // 级联
      }
    }
    obj.fields = []
    this.unlink(obj)
  }

  // sweep 路径：字段引用只减计数**不级联**——真死透的子对象这次没被标记，
  // 马上就会在同一个 sweep 里被收走；还活着的计数不会归零。
  freeSweep(obj) {
    if (obj.dead) return
    if (this.onFree !== null) this.onFree(obj)
    for (const v of obj.fields) {
      const child = this.objOf(v)
      if (child !== null && !child.dead && child.refCount > 0) child.refCount -= 1
    }
    obj.fields = []
    this.unlink(obj)
  }

  unlink(obj) {
    obj.gcPrev.gcNext = obj.gcNext
    obj.gcNext.gcPrev = obj.gcPrev
    obj.dead = true
    this.aliveCount -= 1
  }

  // ==================== gc：标记清除 ====================

  // 迭代式标记：沿字段里的 Handle 引用铺开，显式栈防深对象图爆 JS 栈。
  markFrom(root) {
    if (root.dead || root.mark !== 0) return
    const work = [root]
    root.mark = 1
    while (work.length > 0) {
      const o = work.pop()
      for (const v of o.fields) {
        const c = this.objOf(v)
        if (c !== null && !c.dead && c.mark === 0) {
          c.mark = 1
          work.push(c)
        }
      }
    }
  }

  collect() {
    if (this.collecting) return // 析构里新建对象顶到阈值等重入：跳过
    this.syncRoots() // 收集前根集合先刷新到最新（此刻还没置位）

    this.collecting = true
    this.lastFreed = 0

    // 标记：从全部根出发。
    for (const root of this.rootSet) this.markFrom(root)

    // 清除：先收集死对象再逐个回收——onFree（析构）可能读写字段。
    const doomed = []
    for (let h = this.anchor.gcNext; h !== this.anchor; h = h.gcNext) {
      if (h.mark === 0) doomed.push(h)
    }
    for (const o of doomed) {
      if (!o.dead) {
        // 前面的析构可能已经级联/重入收走了它
        this.freeSweep(o)
        this.lastFreed += 1
      }
    }

    // 清标记：只走还活着的链。
    for (let h = this.anchor.gcNext; h !== this.anchor; h = h.gcNext) h.mark = 0

    this.collecting = false
    this.gcTrigger = this.aliveCount * 2 < 64 ? 64 : this.aliveCount * 2
  }

  // 退出兜底（C++ 的 ~ObjectAllocator）：逐个跑析构、判死——「deleted:
  // James」在这里打印；JS 内存随后由引擎回收。
  disposeAll() {
    for (let h = this.anchor.gcNext; h !== this.anchor; ) {
      const nxt = h.gcNext
      if (this.onFree !== null) this.onFree(h)
      this.unlink(h)
      h = nxt
    }
  }

  // ==================== 诊断 ====================

  reportAlive() {
    let objs = 0
    for (let h = this.anchor.gcNext; h !== this.anchor; h = h.gcNext) objs += 1
    console.log(`[gc] alive: ${objs} object(s), root set ${this.rootSet.size}`)
    for (let h = this.anchor.gcNext; h !== this.anchor; h = h.gcNext) {
      console.log(`  ${h.selfId}  class ${h.classId}  refCount ${h.refCount}`)
    }
  }
}
