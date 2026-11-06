// classes.js：类 / 方法 / 函数的静态结构与槽位装配
// （对应 C++ 的 Class.* / Function.*）。
// 与 demo 5 的差异：MethodInfo 多一个 exportBinds。

export class MethodInfo {
  constructor() {
    this.name = ''
    this.params = []
    this.program = null
    this.selfProps = [] // [槽位下标, 字段下标] —— 只含方法体实际引用的属性
    this.hostBinds = [] // [槽位下标, 宿主函数序号]
    this.selfMethodBinds = [] // [槽位下标, 成员 id]（self:<方法名> 调用）
    // 方法体里的 <类名>:<构造名> / obj:<名> 描述符：[槽位下标, Handle]。
    // 方法有独立的 program，这些名字是它自己的隐式导出——每个 State 都要
    // 各自绑。描述符被本数组引用着，引擎 GC 保证存活。
    this.exportBinds = []
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
