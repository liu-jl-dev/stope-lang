// object_manager.js：obj:* 域的全部行为（对应 C++ 的 ObjectManager.*）。

import { BasicVM } from '../../src/index.js'
import { CtorDesc, MemberDesc, MemberKind, MyObject } from './object.js'

export class ObjectManager {
  constructor(runtime) {
    this.runtime = runtime
    this.live = new Set() // MyObject；delete 后移除
    this.maxObjects = 0 // 存活对象上限（live 表大小）；0 = 不限（对齐 maxDepth 约定）
    // 去重缓存：对象 -> (成员 id -> 绑定描述符)。绑定描述符只存这两样且创建后
    // 不可变，同一绑定永远等价；delete 时整组驱逐，不可达的描述符交给 GC。
    this.bindCache = new Map()
  }

  newObject(clsId) {
    const obj = new MyObject()
    obj.classId = clsId
    obj.fields.length = this.runtime.classes[clsId].properties.length
    this.live.add(obj)
    return new BasicVM.Handle(obj)
  }

  newMemberDesc(memberId) {
    const d = new MemberDesc()
    d.memberId = memberId
    return new BasicVM.Handle(d)
  }

  newCtorDesc(clsId, ctorIdx) {
    return new BasicVM.Handle(new CtorDesc(clsId, ctorIdx))
  }

  // 绑定（创建即去重）。C++ 版还有 freeDescs 复用池；这里不需要 —— 驱逐后
  // 不可达的描述符由 GC 回收，池的存在意义被语言机制替掉了。
  bind(memberId, objHandle) {
    const obj = objHandle.data
    let byMember = this.bindCache.get(obj)
    if (byMember === undefined) {
      byMember = new Map()
      this.bindCache.set(obj, byMember)
    }
    const hit = byMember.get(memberId)
    if (hit !== undefined) return new BasicVM.Handle(hit) // 命中：复用
    const d = new MemberDesc()
    d.memberId = memberId
    d.obj = objHandle
    byMember.set(memberId, d)
    return new BasicVM.Handle(d)
  }

  // obj:<名>[p] -> 绑定描述符（属性引用与绑定方法都从这里出发）。
  at(s, handle, key) {
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

  // obj:<属性>[p] = v -> 写字段。两层整数查询：对象自己的 classId 选类，
  // memberById 查 MemberRef——同名成员在各类里落在不同位置也各归各。
  assign(s, handle, value) {
    const d = handle.data
    if (!(d instanceof MemberDesc) || d.obj === null) {
      s.Error('not assignable. ')
      return
    }
    const obj = d.obj.data
    if (obj.deleted) {
      s.Error('use after free. ') // JS 无悬空指针：删除标记替代 UB（见入口文件头）
      return
    }
    const cls = this.runtime.classes[obj.classId] // 第一层
    const ref = cls.memberById.get(d.memberId)
    if (ref === undefined || ref.kind !== MemberKind.PROP) {
      s.Error('not assignable. ') // 该类没有这个成员 / 方法不可赋值
      return
    }
    obj.fields[ref.index] = value // 第二层：MemberRef.index 即字段下标
  }

  // obj:<名>[p](...) -> 调方法；obj:<名>(...) 直接调（delete 走这里，对象在
  // 实参里）；<Class>:<New>(...) -> 构造。
  callMember(s, handle, args) {
    const d = handle.data
    if (d instanceof CtorDesc) {
      // 构造
      if (this.maxObjects !== 0 && this.live.size >= this.maxObjects) {
        s.error('too many objects. ') // 手动管理：上限内也不自动回收，必须 obj:delete
        return null
      }
      const cls = this.runtime.classes[d.clsId]
      const objHandle = this.newObject(cls.id)
      // 构造器压帧：返回值是新对象本身（不走「弹帧回填」通道）。
      this.runtime.pushMethodFrame(cls.methods[d.ctorIdx], objHandle.data,
        args, false)
      return objHandle
    }
    if (d instanceof MemberDesc) {
      // kind 由 memberById 查表揭晓；类来自绑定对象或实参对象。
      let objHandle = d.obj
      if (objHandle === null) {
        if (args.length > 0 && args[0] instanceof BasicVM.Handle) {
          objHandle = args[0] // obj:delete(p) 实参形式
        } else {
          if (args.length > 0) s.Error('not an object. ') // 实参不是对象
          else s.Error('method not bound. ') // obj:<方法> 未带 [对象]
          return null
        }
      }
      const obj = objHandle.data
      if (obj.deleted) {
        s.Error('use after free. ')
        return null
      }
      const cls = this.runtime.classes[obj.classId] // 第一层
      const ref = cls.memberById.get(d.memberId)
      if (ref === undefined) {
        s.Error('no method. ') // 该类没有这个成员
        return null
      }
      if (ref.kind === MemberKind.DELETE) {
        this.deleteObj(s, obj) // 绑定形式与实参形式在此收敛
        return null
      }
      if (ref.kind !== MemberKind.METHOD) {
        s.Error('"Call" can only call a function. ') // 属性不可调
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

  // 跑 <delete>（可读写字段）-> 驱逐绑定描述符 -> 删除标记。双重 delete 拦下。
  deleteObj(s, obj) {
    if (!this.live.has(obj)) {
      s.Error('double delete. ')
      return
    }
    this.live.delete(obj)
    const cls = this.runtime.classes[obj.classId]
    if (cls.deconstructorId >= 0) {
      this.runtime.invokeMethod(cls.methods[cls.deconstructorId], obj, [])
    }
    this.bindCache.delete(obj) // 整组驱逐；不可达的描述符由 GC 回收
    obj.deleted = true // 内存回收时机交给 GC；之后使用即 use after free
  }

  reportLive() {
    if (this.live.size === 0) {
      console.log('[objects] all freed')
    } else {
      const parts = []
      for (const o of this.live) parts.push(`(class ${o.classId})`)
      console.log(`[objects] ${this.live.size} alive: ${parts.join(' ')}`)
    }
    let cached = 0
    for (const byMember of this.bindCache.values()) cached += byMember.size
    // 差异：C++ 打 allocated/pooled 两个数（复用池）；这里只有缓存里仍被
    // 引用的绑定描述符，池被 GC 替代了。
    console.log(`[bind-cache] ${cached} entries`)
  }
}
