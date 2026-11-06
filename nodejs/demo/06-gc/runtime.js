// runtime.js：静态结构 + 调用 + 入口绑定（对应 C++ 的 Runtime.*）。

import { BasicVM, Result } from '../../src/index.js'
import { MyObject } from './object.js'
import { DemoApi } from './api.js'
import { ObjectManager } from './object_manager.js'

export class Runtime {
  constructor() {
    this.hostFuncs = []
    this.hostFuncMap = new Map() // 名 -> hostFuncs 序号
    this.memberNameMap = new Map() // 成员名 -> 成员 id（跨类共享同名 id）
    this.classMap = new Map() // 类名 -> 类 id（exportBinds 按类名找构造器）
    this.functions = []
    this.classes = []
    this.objMgr = new ObjectManager(this)
    this.api = new DemoApi(this.objMgr)
    // gc 根扫描的范围 = 显式帧栈 frames（入口帧 + 压住的方法帧）+ liveStates
    // （只装 <delete> 析构的同步旁路 State，见 invokeMethod）。
    this.frames = [] // Frame：{state, method, selfObj, wantsReturn}
    this.liveStates = []
    this.hadErrors = false // 任一帧出错置位（错误已打印，供入口返回码用）
    // 正在执行方法的对象（JS 版的「保活」机制）：C++ demo 6 靠绑定描述符
    // 的字段引用撑住 self，JS 的描述符不参与 gc，改由这个数组强引用——
    // pushMethodFrame 压入、弹帧收尾弹出；invokeMethod（同步旁路）同样。
    this.pinned = []
    // gc 根扫描：分配器不认识 State，由 Runtime 供给。只有「Handle 载荷是
    // MyObject」才算引用；描述符由引擎 GC 管，不算。
    this.objMgr.alloc.gatherRoots = () => this.gatherRoots()
    // 析构回调：对象被回收前跑 <delete>。
    this.objMgr.alloc.onFree = (obj) => this.objMgr.runDestructor(obj)
  }

  gatherRoots() {
    const out = []
    const scan = (s) => {
      for (const arr of [s.variables, s.stack, s.returns]) {
        for (const v of arr) {
          if (v instanceof BasicVM.Handle && v.data instanceof MyObject) {
            out.push(v.data)
          }
        }
      }
    }
    for (const f of this.frames) scan(f.state)
    for (const s of this.liveStates) scan(s)
    for (const o of this.pinned) out.push(o)
    return out
  }

  trackState(s) {
    this.liveStates.push(s)
  }

  untrackState(s) {
    const i = this.liveStates.lastIndexOf(s)
    if (i >= 0) this.liveStates.splice(i, 1)
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

  // ---------- 显式帧栈：把 State 显式放在一个栈里，驱动循环只跑栈顶帧 ----------
  // 调用栈从 JS 调用栈搬进 frames 成员：方法调用压帧、返回弹帧，调用方在
  // 栈里压住等返回值。换来 runSteps(maxSteps)「每帧限步」与 runAll()
  // 「一口气跑完」两种驱动，随时可切。

  // 装配入口函数并压帧：宿主函数、构造器描述符、obj:* 成员描述符绑进导出
  // 槽位。demo 6 没有 obj:delete——生命期归 gc 管，<delete> 是回收时自动跑
  // 的析构。
  pushEntryFrame(entry, vmArgs = null) {
    const state = new BasicVM.State()
    state.SetApi(this.api)
    state.SetProgram(entry.program)
    if (vmArgs != null) state.SetArguments(vmArgs)
    state.variables.length = entry.program.variableNum
    entry.initializeState(state, [])
    this.bindEntry(state, entry)
    this.frames.push({ state, method: null, selfObj: null, wantsReturn: false })
  }

  // 装配方法 State（pushMethodFrame / invokeMethod 共用）。
  setupMethodState(m, obj, args, state) {
    state.SetApi(this.api)
    state.SetProgram(m.program)
    m.initializeState(state, obj, args)
    for (const [slot, hostIdx] of m.hostBinds) {
      state.variables[slot] = this.hostFuncs[hostIdx]
    }
    // 方法体里的 <类名>:<构造名> / obj:<名> 描述符：装配期已预算好
    // (槽位, Handle)，逐个拷进槽位。
    for (const [slot, handle] of m.exportBinds) {
      state.variables[slot] = handle
    }
    // self:<方法名> 槽位绑 self 的绑定方法描述符——每次新建（不去重）。
    for (const [slot, memberId] of m.selfMethodBinds) {
      state.variables[slot] = this.objMgr.bind(memberId, new BasicVM.Handle(obj))
    }
  }

  // 压入方法帧，不执行——runSteps 自然切到栈顶帧。调用方（call 开口的
  // 发起方）停在 Call 的下一条；开口返回的占位 null 会被 op_call 压到调用
  // 方栈顶，弹帧收尾时用真正的返回值覆盖。self 进 pinned 保活。
  pushMethodFrame(m, obj, args, wantsReturn) {
    const state = new BasicVM.State()
    this.setupMethodState(m, obj, args, state)
    this.frames.push({ state, method: m, selfObj: obj, wantsReturn })
    this.pinned.push(obj)
  }

  // 每帧限步驱动：只跑栈顶帧，至多 maxSteps 条指令；帧弹栈（Return / 指令
  // 流走完 / 出错中止当前函数）不消耗步数。返回 false = 帧栈已空。
  runSteps(maxSteps) {
    while (maxSteps > 0 && this.frames.length > 0) {
      const s = this.frames[this.frames.length - 1].state
      if (s.i >= s.program.opcodes.length) {
        this.finishTopFrame() // Return 已把返回值备好；弹栈不消耗步数
        continue
      }
      if (s.Step() !== Result.Success) {
        this.finishTopFrame() // 运行期错误：只中止当前函数，调用方继续
        continue
      }
      --maxSteps
    }
    return this.frames.length > 0
  }

  // 直接执行：一口气跑到帧栈清空。与 runSteps 随时可切。
  runAll() {
    while (this.runSteps(0x3fffffff)) {}
  }

  // 摘出栈顶帧并收尾。
  finishTopFrame() {
    const f = this.frames.pop()
    this.finishFrame(f)
  }

  // 帧收尾：错误打印、self: 槽位写回字段（走 setField：引用计数照常维护）、
  // 返回值回填调用方栈顶（op_call 已把占位 null 压到那里，覆盖即可）。
  finishFrame(f) {
    for (const e of f.state.errors) {
      console.log('  vm: ' + e)
      this.hadErrors = true
    }
    if (f.method === null) return // 入口帧：没有 selfProps / 返回值
    this.pinned.pop() // 与 pushMethodFrame 配对
    // 返回前把 self: 槽位写回字段——selfProps 只含方法体实际引用的属性。
    for (const [slot, fieldIdx] of f.method.selfProps) {
      this.objMgr.alloc.setField(f.selfObj, fieldIdx, f.state.variables[slot])
    }
    // 回填调用方栈顶（wantsReturn 帧）。构造器帧返回的是新对象本身，不走这里。
    if (f.wantsReturn && this.frames.length > 0 && f.state.returns.length > 0) {
      const caller = this.frames[this.frames.length - 1].state
      caller.stack[caller.stack.length - 1] = f.state.returns[0]
    }
  }

  // 同步执行整个方法（<delete> 析构路径）：装配 + Run + 收尾。析构在级联
  // 释放 / sweep 的中间被调用，跑完后调用方还要清字段——不能让出执行权。
  // 析构里再调方法也走这条路：压帧没人跑（此刻正停在 Step 中间）。
  invokeMethod(m, obj, args) {
    const state = new BasicVM.State()
    this.setupMethodState(m, obj, args, state)
    this.pinned.push(obj)
    this.trackState(state)
    state.Run()
    this.untrackState(state)
    this.pinned.pop()
    for (const e of state.errors) {
      console.log('  vm: ' + e)
      this.hadErrors = true
    }
    for (const [slot, fieldIdx] of m.selfProps) {
      this.objMgr.alloc.setField(obj, fieldIdx, state.variables[slot])
    }
    return state.returns.length > 0 ? state.returns[0] : null
  }

  // 装配入口函数：宿主函数、构造器描述符、obj:* 成员描述符绑进导出槽位。
  // demo 6 没有 obj:delete——生命期归 gc 管，<delete> 是回收时自动跑的析构。
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
        if (m.name === '' || cls.constructorMap.has(m.name)) continue // 构造器不占 obj: 名
        this.bindExport(state, entry, 'obj:' + m.name,
          this.objMgr.newMemberDesc(this.newMemberId(m.name)))
      }
    }
  }

  bindExport(state, entry, nm, handle) {
    if (!entry.program.exports.has(nm)) return
    state.variables[entry.program.exports.get(nm)] = handle
  }
}
