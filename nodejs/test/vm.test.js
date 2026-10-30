// 参考执行器（不是标准）的测试：跑通编译产物、锁住步进规则与运行期错误。
//
// ⚠ C++ 里没有 Bool 值类型：PushTrue/PushFalse 压的是 Integer 1/0，所以运行期
// `true` 读回来是 1n。断言都按 BigInt 写。
//
// Step() 与 Run() 是两份独立实现（热循环里不套函数调用），这里用同一批程序锁住
// 「两条路径的 returns / errors / 停机时的 i 逐项相同」。

import { test, describe } from 'node:test'
import assert from 'node:assert/strict'
import { Api, State, Arguments, Identifier } from '../src/basic_vm.js'
import { Lexer } from '../src/lexer.js'
import { Parser } from '../src/parser.js'
import { Compiler } from '../src/compiler.js'
import { Program } from '../src/program.js'
import { Prog } from '../src/ast.js'
import { Result } from '../src/common.js'

// 编译一份源码；失败直接让用例红（这里的用例都该编得过）
function compile(src, custom = null) {
  const ps = new Parser(new Lexer(src), custom)
  const tree = new Prog()
  ps.ParseProgram(tree)
  assert.deepEqual(ps.errors, [], `语法错误：${ps.errors.join('|')}`)
  const c = new Compiler(custom)
  const p = new Program()
  assert.equal(c.Compile(tree, p), Result.Success, `编译错误：${c.errors.join('|')}`)
  return p
}

// 默认实参表：没有 argc / args
class NoArgs extends Arguments {
  at(_state, _key) {
    return null
  }
  num() {
    return 0
  }
}

class FloatArgs extends Arguments {
  constructor(values) {
    super()
    this.data = values
  }
  at(state, key) {
    if (typeof key !== 'bigint') {
      state.error('index must be an integer. ')
      return null
    }
    const i = Number(key)
    if (i < 0 || i >= this.data.length) {
      state.error('index out of range. ')
      return null
    }
    return this.data[i]
  }
  num() {
    return this.data.length
  }
}

// 错误串的格式是 "<指令下标>: msg"（C++ 的 State::Error 同样带下标）。下标取决于
// 产物里指令的位置，所以断言只比 msg；下标格式单独用一条用例锁。
function msgs(errors) {
  return errors.map((e) => e.replace(/^\d+: /, ''))
}

function run(src, args = new NoArgs(), custom = null) {
  const p = compile(src, custom)
  const s = new State()
  s.Reset(new Api(), p, args)
  const rc = s.Run()
  return { s, rc, p, ret: s.returns, errors: s.errors }
}

// 跑同一个程序两次：一次 Run、一次反复 Step，逐项比对
function runBoth(src, args = new NoArgs()) {
  const p = compile(src)
  const a = new State()
  a.Reset(new Api(), p, args)
  const rcRun = a.Run()

  const b = new State()
  b.Reset(new Api(), p, new NoArgs())
  let steps = 0
  for (;;) {
    const rc = b.Step()
    if (rc !== Result.Success) break
    if (b.errors.length > 0) break
    if (b.i >= p.opcodes.length) break
    ++steps
  }
  assert.deepEqual(b.returns, a.returns, 'Step 与 Run 的 returns 必须一致')
  assert.deepEqual(b.errors, a.errors, 'Step 与 Run 的 errors 必须一致')
  assert.equal(b.i, a.i, 'Step 与 Run 停机时的 i 必须一致')
  return { ret: a.returns, rc: rcRun, errors: a.errors, steps }
}

describe('VM：算术与类型规则', () => {
  const cases = [
    ['let a = 1; let b = 2; return a + b;', 3n],
    ['return 7 / 2;', 3.5], // 除不尽 -> Float
    ['return 6 / 3;', 2n], // 整除保持整数
    ['return 7 idiv 2;', 3n], // 向零取整
    ['return -7 idiv 2;', -3n],
    ['return 7 % 2;', 1n],
    ['return -7 % 2;', -1n], // 余数符号跟被除数
    ['return 2 ^ 10;', 1024n],
    ['return 2 ^ -1;', 0.5], // 负指数 -> Float
    ['return 1.5 + 2;', 3.5],
    ['return "ab" + "cd";', 'abcd'],
    ['return "ab" * 3;', 'ababab'],
    ['return 3 * "ab";', 'ababab'], // 整数在左也要成立
    ['return 1 + 2 * 3;', 7n], // 优先级
    ['return 2 ^ 3 ^ 2;', 512n], // ^ 右结合
    ['let x = 1; x = 5; return x;', 5n],
    ['let a = 1; { let a = 2; } return a;', 1n], // 块作用域
    ['if 1 { return 1; } else { return 2; }', 1n],
    ['let i = 0; while i < 3 { i = i + 1; } return i;', 3n],
    ['let i = 0; while 1 { i = i + 1; if i == 2 { break; } } return i;', 2n],
    ['let i = 0; let n = 0; while i < 5 { i = i + 1; if i == 2 { continue; } n = n + 1; } return n;', 4n],
    ['return 1 == 1.0;', 1n], // 整数与浮点可跨类型比较相等
    ['return "a" == "a";', 1n],
    ['return null == null;', 1n],
    ['return !0;', 1n],
    ['return !null;', 1n],
    ['return -5;', -5n],
    ['return 9223372036854775807 + 1;', -9223372036854775808n], // 64 位回绕
    ['return true;', 1n], // C++ 没有 Bool 值类型
    ['return false;', 0n],
    ['return 1 < 2;', 1n],
    ['return 2 <= 2;', 1n],
    ['return 1 and 2;', 1n], // 短路运算符的结果是 Integer 1/0
    ['return 0 or 0;', 0n],
  ]

  for (const [src, want] of cases) {
    test(src, () => {
      const { ret, rc } = runBoth(src)
      assert.equal(rc, Result.Success)
      assert.deepEqual(ret, [want])
    })
  }

  test('BinArr 连接与重复', () => {
    const { ret } = runBoth("return 'x 41' + 'x 42';")
    assert.deepEqual(Array.from(ret[0]), [0x41, 0x42])
    const r2 = runBoth("return 'x 41' * 2;")
    assert.deepEqual(Array.from(r2.ret[0]), [0x41, 0x41])
  })

  test('字符串 / 字节串取下标', () => {
    assert.deepEqual(runBoth('return "ab"[1];').ret, [98n]) // 码元，不是子串
    assert.deepEqual(runBoth("return 'x 41 42'[0];").ret, [0x41n])
  })
})

describe('VM：宿主接口（argc / args / 宿主函数）', () => {
  test('argc 与 args[i]', () => {
    const { ret } = run('return argc + args[0];', new FloatArgs([2.5]))
    assert.deepEqual(ret, [3.5]) // argc(1) + args[0](2.5)
  })

  test('宿主函数：exports 槽位里放函数', () => {
    const src = 'fmt:println("hi", 7); return 1;'
    const p = compile(src)
    const s = new State()
    s.Reset(new Api(), p, new NoArgs())
    const called = []
    s.variables[p.exports.get('fmt:println')] = (args) => {
      called.push(args)
      return null
    }
    assert.equal(s.Run(), Result.Success)
    assert.deepEqual(called, [['hi', 7n]])
    assert.deepEqual(s.returns, [1n])
  })

  test('Call 到非函数 -> 报错', () => {
    const src = 'f(1);'
    const p = compile(src)
    const s = new State()
    s.Reset(new Api(), p, new NoArgs())
    assert.equal(s.Run(), Result.Error)
    assert.deepEqual(msgs(s.errors), ['"Call" can only call a function. '])
  })

  test('没有 args 却用 argc -> no args. ', () => {
    const p = compile('return argc;')
    const s = new State()
    s.Reset(new Api(), p, null)
    assert.equal(s.Run(), Result.Error)
    assert.deepEqual(msgs(s.errors), ['no args. '])
  })

  test('宿主实参表自己报错 -> 立刻停在那条指令', () => {
    const p = compile('return args[9];')
    const s = new State()
    s.Reset(new Api(), p, new FloatArgs([1.0]))
    assert.equal(s.Run(), Result.Error)
    assert.deepEqual(msgs(s.errors), ['index out of range. '])
  })
})

describe('VM：运行期错误', () => {
  // 下标不写死（它取决于产物里指令的位置），只比消息
  const cases = [
    ['return 1 / 0;', '"Div" division by zero. '],
    ['return 1 % 0;', '"Mod" division by zero. '],
    ['return 1 idiv 0;', '"IDiv" division by zero. '],
    ['return 1.0 / 0;', null], // 有浮点就走 IEEE，得 inf，不报错
    ['return null + 1;', '"Add" cannot operate on null. '],
    ['return null * 1;', '"Mul" cannot operate on null. '],
    ['return "a" - "b";', '"Sub" can only operate on integer or float. '],
    ['return "a" < "b";', 'only on integer or float can be compared. '],
    ['return "ab" * -1;', '"Mul" cannot repeat a sequence by a negative number. '],
    ['return "ab"[5];', 'index out of range. '],
    ["return 'x 41'[5];", 'index out of range. '],
  ]

  for (const [src, want] of cases) {
    test(src, () => {
      const { rc, errors, ret } = run(src)
      if (want === null) {
        assert.equal(rc, Result.Success)
        assert.equal(ret[0], Infinity)
        return
      }
      assert.equal(rc, Result.Error)
      assert.deepEqual(msgs(errors), [want])
    })
  }

  test('错误串带指令下标："<i>: msg"', () => {
    // `return 1 / 0;` 的产物是 PushInt(0) PushInt(1) Div Return(1) —— Div 在 [4]
    // （下标本身是指令的位置，操作数各占一格）。
    const { errors } = run('return 1 / 0;')
    assert.equal(errors.length, 1)
    assert.match(errors[0], /^4: "Div" division by zero\. $/)
  })

  test('出错后 Step 不再重复执行同一条指令', () => {
    const p = compile('return 1 / 0;')
    const s = new State()
    s.Reset(new Api(), p, new NoArgs())
    assert.equal(s.Run(), Result.Error)
    const n = s.errors.length
    assert.equal(s.Step(), Result.Error)
    assert.equal(s.errors.length, n) // 不会把同一条错指令再跑一遍
  })
})

describe('VM：State 的装配与自检', () => {
  test('Reset 开好变量槽位（不用自己 resize）', () => {
    const p = compile('let a = 1; let b = 2; return a;')
    const s = new State()
    s.Reset(new Api(), p, new NoArgs())
    assert.equal(s.variables.length, p.variableNum)
    assert.equal(s.variables.length, 2)
  })

  test('Identifier 只由 PushId 产生，Assign 靠它取槽位', () => {
    // `a = 1` 的左端是裸标识符 -> 编译器压 PushId（槽位引用）
    const p = compile('let a = 0; a = 1;')
    assert.ok(p.opcodes.includes(9), 'opcodes 里应有 PushId(9)')
  })

  test('空程序：Run 成功、returns 为空', () => {
    const { rc, ret } = run('')
    assert.equal(rc, Result.Success)
    assert.deepEqual(ret, [])
  })

  test('多次 return：returns 取最上面那次', () => {
    const { ret } = run('if 1 { return 1; } return 2;')
    assert.deepEqual(ret, [1n])
  })
})
