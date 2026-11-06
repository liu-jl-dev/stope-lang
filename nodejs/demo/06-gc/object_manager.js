// object_manager.js：obj:* 域的全部行为（对应 C++ 的 ObjectManager.*）。
//
// 与 demo 5 的差异：没有 bindCache / live 表 / obj:delete——描述符每次
// Bind 新建（引擎 GC 回收不可达者），对象生命期归 gc 分配器。
// 三个开口入口先 safePoint()：安全点根同步，先于一切 delRef。

import { BasicVM } from '../../src/index.js'
import { CtorDesc, MemberDesc, MemberKind } from './object.js'
import { ObjectAllocator } from './gc.js'

export class ObjectManager {
  constructor(runtime) {
    this.runtime = runtime
    this.alloc = new ObjectAllocator() // gc 分配器（C++ 版住在 ObjectManager 里）
  }

  // new 业务对象。返回 null = 顶到 maxNodes（调用方 s.Error）。
  newObject(clsId) {
    const obj = this.alloc.newObject()
    if (obj === null) return null
    obj.classId = clsId
    obj.fields.length = this.runtime.classes[clsId].properties.length
    return new BasicVM.Handle(obj)
  }

  // 描述符：每次新建，不去重——demo 5 的 bindCache / 驱逐在 demo 6 里
  // 全部消失，不可达的描述符由引擎 GC 回收。
  newMemberDesc(memberId) {
    const d = new MemberDesc()
    d.memberId = memberId
    return new BasicVM.Handle(d)
  }

  newCtorDesc(clsId, ctorIdx) {
    return new BasicVM.Handle(new CtorDesc(clsId, ctorIdx))
  }

  // 绑定描述符：每次新建。obj 是普通 Handle——描述符不持有对象（引擎 GC
  // 管不到 gc 对象），「正在执行方法」的对象由 runtime.pinned 保活。
  bind(memberId, objHandle) {
    const d = new MemberDesc()
    d.memberId = memberId
    d.obj = objHandle
    return new BasicVM.Handle(d)
  }

  // 三个开口的公共前奏：安全点——先同步根集合，再做本次操作。「引用计数
  // 归零 -> 立即级联释放」的可靠性由这条顺序保证（见 gc.js 头注释）。
  safePoint() {
    this.alloc.syncRoots()
  }

  // obj:<名>[p] -> 绑定描述符。
  at(s, handle, key) {
    this.safePoint()
    const d = handle.data
    if (!(d instanceof MemberDesc)) {
      s.Error('no implement for container type. ')
      return null
    }
    if (!(key instanceof BasicVM.Handle)) {
      s.Error('not an object. ')
      return null
    }
    return this.bind(d.memberId, key)
  }

  // obj:<属性>[p] = v -> 写字段（走 setField：旧值减引用可级联，新值加引用）。
  assign(s, handle, value) {
    this.safePoint()
    const d = handle.data
    if (!(d instanceof MemberDesc) || d.obj === null) {
      s.Error('not assignable. ')
      return
    }
    const obj = d.obj.data
    if (obj.dead) {
      s.Error('use after gc. ') // 死对象不可达才判死，正常程序到不了这里
      return
    }
    const cls = this.runtime.classes[obj.classId] // 第一层
    const ref = cls.memberById.get(d.memberId)
    if (ref === undefined || ref.kind !== MemberKind.PROP) {
      s.Error('not assignable. ') // 该类没有这个属性 / 方法不可赋值
      return
    }
    this.alloc.setField(obj, ref.index, value) // 第二层
  }

  // obj:<名>[p](...) -> 调方法；<Class>:<New>(...) -> 构造。
  // demo 6 没有 obj:delete(p)：生命期归 gc 管。
  callMember(s, handle, args) {
    this.safePoint()
    const d = handle.data
    if (d instanceof CtorDesc) {
      const cls = this.runtime.classes[d.clsId]
      const objHandle = this.newObject(cls.id)
      if (objHandle === null) {
        s.Error('too many gc nodes. ') // 顶到 maxNodes：走正常错误通道
        return null
      }
      // 构造器压帧：返回值是新对象本身（不走「弹帧回填」通道）。
      this.runtime.pushMethodFrame(cls.methods[d.ctorIdx], objHandle.data,
        args, false)
      return objHandle
    }
    if (d instanceof MemberDesc) {
      if (d.obj === null) {
        s.Error('method not bound. ') // demo 6 只支持 obj:<名>[p]() 形式
        return null
      }
      const obj = d.obj.data
      if (obj.dead) {
        s.Error('use after gc. ')
        return null
      }
      const cls = this.runtime.classes[obj.classId] // 第一层：classId 选类
      const ref = cls.memberById.get(d.memberId)
      if (ref === undefined || ref.kind !== MemberKind.METHOD) {
        s.Error('no method. ') // 该类没有这个方法（属性不可调）
        return null
      }
      // 方法调用压帧：返回占位 null——op_call 把它压到调用方栈顶，
      // 方法帧弹栈时（finishFrame）再回填真正的返回值。
      this.runtime.pushMethodFrame(cls.methods[ref.index], obj, args, true)
      return null
    }
    s.Error('"Call" can only call a function. ')
    return null
  }

  // gc 回收前回调（alloc.onFree）：跑 <delete>。此时字段还完整可读。
  runDestructor(obj) {
    const cls = this.runtime.classes[obj.classId]
    if (cls.deconstructorId >= 0) {
      this.runtime.invokeMethod(cls.methods[cls.deconstructorId], obj, [])
    }
  }

  reportLive() {
    this.alloc.reportAlive()
    if (this.alloc.rootSet.size === 0) {
      console.log('[gc] no roots: everything reachable has been freed')
    } else {
      console.log(
        `[gc] roots keep ${this.alloc.rootSet.size} object(s) alive - variables outlive Run()`
      )
    }
  }
}
