// runtime.js：静态结构 + 调用 + 入口绑定（对应 C++ 的 Runtime.*）。

import { BasicVM } from '../../src/index.js'
import { DemoApi } from './api.js'
import { ObjectManager } from './object_manager.js'

export class Runtime {
  constructor() {
    this.hostFuncs = []
    this.hostFuncMap = new Map() // 名 -> hostFuncs 序号
    this.memberNameMap = new Map() // 成员名 -> 成员 id（跨类共享同名 id）
    this.functions = []
    this.classes = []
    this.objMgr = new ObjectManager(this)
    this.api = new DemoApi(this.objMgr)
  }

  newMemberId(nm) {
    if (this.memberNameMap.has(nm)) return this.memberNameMap.get(nm)
    const id = this.memberNameMap.size
    this.memberNameMap.set(nm, id)
    return id
  }

  newClass() {
    const c = {
      id: this.classes.length,
      name: '',
      properties: [],
      methods: [],
      memberById: new Map(), // 成员 id -> MemberRef（唯一的查找表）
      constructorMap: new Map(), // <new 名> -> methods 下标
      deconstructorId: -1,
    }
    this.classes.push(c)
    return c
  }

  findFunction(nm) {
    for (const f of this.functions) if (f.name === nm) return f
    return null
  }

  addHostFunction(nm, fn) {
    this.hostFuncMap.set(nm, this.hostFuncs.length)
    this.hostFuncs.push(fn)
  }

  // 方法调用：每层调用一个临时 State，随返回销毁 —— 嵌套调用就是 JS 的
  // 递归栈。Runtime 不保存调用栈（demo 6 做根扫描时才需要）。
  invokeMethod(m, obj, args) {
    const state = new BasicVM.State()
    state.SetApi(this.api)
    state.SetProgram(m.program)
    m.initializeState(state, obj, args)
    for (const [slot, hostIdx] of m.hostBinds) {
      state.variables[slot] = this.hostFuncs[hostIdx]
    }
    // self:<方法名> 槽位绑 self 的绑定方法描述符——创建即绑定 self，
    // self:Greet() 无需 [对象]；去重缓存保证递归调用不重复分配。
    for (const [slot, memberId] of m.selfMethodBinds) {
      state.variables[slot] = this.objMgr.bind(memberId, new BasicVM.Handle(obj))
    }
    state.Run()
    for (const e of state.errors) console.log('  vm: ' + e)
    // 返回前把 self: 槽位写回字段（只写实际引用的那几个）。
    for (const [slot, fieldIdx] of m.selfProps) {
      obj.fields[fieldIdx] = state.variables[slot]
    }
    return state.returns.length > 0 ? state.returns[0] : null
  }

  // 装配入口函数：宿主函数、构造器描述符、obj:* 成员描述符绑进导出槽位。
  // 按名只发生在这里（装配期），state.Run() 期间零按名查找。
  bindEntry(state, entry) {
    for (const [slot, hostIdx] of entry.hostBinds) {
      state.variables[slot] = this.hostFuncs[hostIdx]
    }
    for (const cls of this.classes) {
      for (const [nm, ctorIdx] of cls.constructorMap) {
        this.bindExport(state, entry, `${cls.name}:${nm}`,
          this.objMgr.newCtorDesc(cls.id, ctorIdx))
      }
      for (const prop of cls.properties) {
        this.bindExport(state, entry, 'obj:' + prop,
          this.objMgr.newMemberDesc(this.newMemberId(prop)))
      }
      for (const m of cls.methods) {
        if (m.name === '' || cls.constructorMap.has(m.name)) continue // <delete> 走 obj:delete；构造器不占 obj: 名
        this.bindExport(state, entry, 'obj:' + m.name,
          this.objMgr.newMemberDesc(this.newMemberId(m.name)))
      }
      if (cls.deconstructorId >= 0) {
        this.bindExport(state, entry, 'obj:delete',
          this.objMgr.newMemberDesc(this.newMemberId('delete')))
      }
    }
  }

  bindExport(state, entry, nm, handle) {
    if (!entry.program.exports.has(nm)) return
    state.variables[entry.program.exports.get(nm)] = handle
  }
}
