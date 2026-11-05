// doc_visitor.js：STML 文档 -> 类与函数，含编译、索引预算与 self 链接
// （对应 C++ 的 DocVisitor.*）。

import {
  Compiler,
  Lexer,
  Parser,
  Program,
  AST,
  Result,
} from '../../src/index.js'
import { FunctionInfo, MethodInfo } from './classes.js'
import { MemberKind, MemberRef } from './object.js'

// 装配期失败用 throw 上传（JS 有异常，与 C++ 的做法一致）。
export class DocVisitor {
  visitDoc(root, rt) {
    for (const e of root.children) {
      if (e.tag === 'class') this.visitClass(e, rt)
      else if (e.tag === 'func') this.visitFunc(e, rt)
    }
    this.linkSelfCalls(rt)
  }

  visitClass(e, rt) {
    const cls = rt.newClass()
    cls.name = e.attrs.get('name')
    for (const c of e.children) {
      if (c.tag === 'property') {
        cls.memberById.set(rt.newMemberId(c.attrs.get('name')),
          new MemberRef(MemberKind.PROP, cls.properties.length))
        cls.properties.push(c.attrs.get('name'))
      } else if (c.tag === 'method') {
        const idx = cls.methods.length
        this.visitMethod(c, rt, cls)
        if (cls.methods[cls.methods.length - 1].name !== '') {
          cls.memberById.set(rt.newMemberId(cls.methods[cls.methods.length - 1].name),
            new MemberRef(MemberKind.METHOD, idx))
        }
      } else if (c.tag === 'new') {
        const idx = cls.methods.length
        cls.constructorMap.set(c.attrs.get('name'), idx)
        this.visitMethod(c, rt, cls)
      } else if (c.tag === 'delete' && cls.deconstructorId === -1) {
        const idx = cls.methods.length
        cls.deconstructorId = idx
        this.visitMethod(c, rt, cls)
        cls.memberById.set(rt.newMemberId('delete'),
          new MemberRef(MemberKind.DELETE, idx))
      }
    }
  }

  visitMethod(e, rt, cls) {
    const m = new MethodInfo()
    m.name = e.attrs.has('name') ? e.attrs.get('name') : ''
    if (e.attrs.has('params')) {
      m.params = e.attrs.get('params').split(/\s+/).filter(Boolean)
    }
    // pre_exports = 形参（属性不进：self:<属性> 走隐式导出，链接遍配对）。
    m.program = this.compile(e.text, e.textLine, m.params)
    // 装配期预计算整数索引：宿主函数 -> (槽位, 序号)；形参 -> 槽位。
    for (const [nm, idx] of rt.hostFuncMap) {
      if (m.program.exports.has(nm)) m.hostBinds.push([m.program.exports.get(nm), idx])
    }
    for (const p of m.params) m.paramSlots.push(m.program.exports.get(p))
    cls.methods.push(m)
  }

  visitFunc(e, rt) {
    const f = new FunctionInfo()
    f.name = e.attrs.get('name')
    if (e.attrs.has('params')) {
      f.params = e.attrs.get('params').split(/\s+/).filter(Boolean)
    }
    f.program = this.compile(e.text, e.textLine, f.params)
    for (const [nm, idx] of rt.hostFuncMap) {
      if (f.program.exports.has(nm)) f.hostBinds.push([f.program.exports.get(nm), idx])
    }
    for (const p of f.params) f.paramSlots.push(f.program.exports.get(p))
    rt.functions.push(f)
  }

  // 链接 self:<属性> 与 self:<方法名>，并校验方法里 self: 前缀的隐式导出
  // 全部链接成功（拼写错误装配期拦下）。必须在全部类访问完之后跑：方法可以
  // 引用文档里后定义的成员。<func> 里的 self: 有意不校验（见 docs §10）。
  linkSelfCalls(rt) {
    for (const cls of rt.classes) {
      for (const m of cls.methods) {
        for (let fi = 0; fi < cls.properties.length; ++fi) {
          const nm = 'self:' + cls.properties[fi]
          if (m.program.exports.has(nm)) {
            m.selfProps.push([m.program.exports.get(nm), fi])
          }
        }
        for (const [nm, memberId] of rt.memberNameMap) {
          if (nm === '') continue // <delete> 无名
          const ref = cls.memberById.get(memberId)
          if (ref === undefined || ref.kind !== MemberKind.METHOD) continue
          const enm = 'self:' + nm
          if (m.program.exports.has(enm)) {
            m.selfMethodBinds.push([m.program.exports.get(enm), memberId])
          }
        }
        for (const [enm, slot] of m.program.exports) {
          if (!enm.startsWith('self:')) continue
          const linked = m.selfProps.some((p) => p[0] === slot) ||
            m.selfMethodBinds.some((b) => b[0] === slot)
          if (!linked) throw new Error(`unlinked self member: ${enm}`)
        }
      }
    }
  }

  // 编译一份源码：pre_exports = 形参；失败即抛（对齐 C++ 的装配期异常）。
  compile(src, startLine, preExports) {
    const lexer = new Lexer(src)
    lexer.line = startLine // 报错行号对齐原文档
    const parser = new Parser(lexer)
    const tree = new AST.Prog()
    parser.ParseProgram(tree)
    if (lexer.errors.length > 0 || parser.errors.length > 0) {
      for (const e of lexer.errors) console.log('  lexer: ' + e)
      for (const e of parser.errors) console.log('  parser: ' + e)
      throw new Error('parse failed')
    }
    const compiler = new Compiler()
    const out = new Program()
    if (compiler.Compile(tree, out, preExports) !== Result.Success) {
      for (const e of compiler.errors) console.log('  compiler: ' + e)
      throw new Error('compile failed')
    }
    return out
  }
}
