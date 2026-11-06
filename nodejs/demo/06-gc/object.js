// object.js：对象模型 —— gc 管理的业务对象 + 引擎管理的描述符
// （对应 cpp/demo/06-gc/ 的 Object.*）。
//
// 与 demo 5 的差异：MyObject 头上多了 gc 字段（侵入式循环双向链表 + 引用
// 计数 + 标记），生命期归 gc；描述符仍是普通对象——JS 引擎 GC 替我们记账，
// 不需要 C++ demo 6 的 Pin（C++ 侧描述符进 gc 链、装配期 Pin 住，这里引擎
// 机制等价替代）。gc 字段语义见 gc.js 的头注释。

// 成员种类（对应 C++ 的 kMemberProp / kMemberMethod；demo 6 无 delete）。
export const MemberKind = { PROP: 0, METHOD: 1 }

// 业务对象。gc 决定「何时判死」；JS 内存回收交给引擎——判死后节点从链表
// 摘除、字段清空，不可达后由引擎回收内存。
export class MyObject {
  static nextId = 1 // 诊断打印用（C++ 打的是指针；JS 用自增 id 替代）

  constructor() {
    this.selfId = MyObject.nextId++
    this.classId = -1
    this.fields = [] // 下标对齐 ClassInfo.properties
    // ---- gc 头 ----
    this.gcPrev = null // 循环双向链表（哨兵是 GcAnchor）
    this.gcNext = null
    this.refCount = 0 // 字段引用（精确）+ 根引用（安全点同步）
    this.mark = 0 // 0 未标记 / 1 已标记
    this.dead = false // 已摘链判死：级联与 sweep 的回收名单重叠时防重复处理
  }
}

// 链表哨兵：不占对象编号，与 MyObject 一样有 gcPrev / gcNext（鸭子类型）。
export class GcAnchor {
  constructor() {
    this.gcPrev = null
    this.gcNext = null
  }
}

export class MemberRef {
  constructor(kind, index) {
    this.kind = kind
    this.index = index // 进 properties 或 methods
  }
}

// 描述符（引擎 GC 管理，不进 gc 链）。绑定描述符的 obj 是普通 Handle——
// 不持有对象：gc 只认「State 可达 + 字段引用 + 正在执行方法」的对象。
export class MemberDesc {
  constructor() {
    this.memberId = -1
    this.obj = null // StopeBasicVM.Handle，null = 未绑定
  }
}

export class CtorDesc {
  constructor(clsId, ctorIdx) {
    this.clsId = clsId
    this.ctorIdx = ctorIdx
  }
}
