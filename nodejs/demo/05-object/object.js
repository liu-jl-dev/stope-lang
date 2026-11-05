// object.js：对象模型 —— 业务对象与描述符（对应 C++ 的 Object.*）。

// 成员种类（对应 C++ 的 kMemberProp / kMemberMethod / kMemberDelete）。
export const MemberKind = { PROP: 0, METHOD: 1, DELETE: 2 }

// 业务对象。JS 对象无法手动释放：deleted 标记 + 使用检测模拟手动管理的纪律。
export class MyObject {
  constructor() {
    this.classId = -1
    this.fields = [] // 下标对齐 ClassInfo.properties
    this.deleted = false
  }
}

export class MemberRef {
  constructor(kind, index) {
    this.kind = kind
    this.index = index // 进 properties 或 methods
  }
}

// 成员描述符：memberId + obj（绑定后才有，Handle）。
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
