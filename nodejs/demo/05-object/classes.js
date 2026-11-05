// classes.js：类 / 方法 / 函数的静态结构与槽位装配
// （对应 C++ 的 Class.* / Function.*）。

export class MethodInfo {
  constructor() {
    this.name = ''
    this.params = []
    this.program = null
    // 装配期预计算的整数索引：运行中不做任何按名查找。
    this.selfProps = [] // [槽位下标, 字段下标] —— 只含方法体实际引用的属性
    this.hostBinds = [] // [槽位下标, 宿主函数序号]
    this.selfMethodBinds = [] // [槽位下标, 成员 id]（self:<方法名> 调用）
    this.paramSlots = [] // params[i] -> 变量槽位下标
  }

  initializeState(state, selfObj, args) {
    for (const [slot, fieldIdx] of this.selfProps) {
      state.variables[slot] = selfObj.fields[fieldIdx] // 字段 -> 槽位
    }
    for (let k = 0; k < this.paramSlots.length; ++k) {
      // 缺参静默：缺的槽位是 null（已知局限，见 docs §10）
      state.variables[this.paramSlots[k]] = k < args.length ? args[k] : null
    }
  }
}

export class FunctionInfo {
  constructor() {
    this.name = ''
    this.params = []
    this.program = null
    this.hostBinds = []
    this.paramSlots = []
  }

  initializeState(state, args) {
    for (let k = 0; k < this.paramSlots.length; ++k) {
      state.variables[this.paramSlots[k]] = k < args.length ? args[k] : null
    }
  }
}

export class ClassInfo {
  constructor() {
    this.id = -1
    this.name = ''
    this.properties = []
    this.methods = []
    this.memberById = new Map() // 成员 id -> MemberRef（唯一的查找表）
    this.constructorMap = new Map() // <new 名> -> methods 下标
    this.deconstructorId = -1
  }
}
